"""Host — "what is a secret", provider synthesis, and the two atomic stores.

`kib mcp add`, `kib mcp adopt`, the front-line `mcp add` interceptor and the after-the-fact
inline-secret warner all need to agree on what a credential looks like. Defined once here,
not per-consumer: split apart, they drift — one flagging `AUTH`-named env keys the other
misses, or brokering `headers[0]` blindly.

All pure, all stateless, and none of them prints a secret.
"""

from __future__ import annotations

import os
import re
import urllib.parse
from collections.abc import Sequence
from typing import Any

from kib.shared.jsonio import write_atomic

AUTH_HEADER_NAMES = frozenset(("authorization", "x-api-key", "api-key", "x-goog-api-key"))
_SECRET_KEY_RE = re.compile(r"(TOKEN|KEY|SECRET|PASSWORD|PASSWD|AUTH|CREDENTIAL)", re.I)
_AUTH_SCHEME_RE = re.compile(r"(sk-|Bearer |Basic )")  # a credential-scheme prefix
_B64_VAL_RE = re.compile(r"[A-Za-z0-9+/]{16,}={0,2}$")
_HEX_VAL_RE = re.compile(r"[0-9a-fA-F]{24,}$")

#: A route id is three things at once: a filename stem, a URL path segment on the shared MCP
#: listener, and a `list-providers` field bash word-splits on. This is the narrowest spelling
#: all three accept, so one validator covers the writer and the reader.
_ROUTE_ID_RE = re.compile(r"[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?$")

#: A credential filename. Deliberately excludes `/` and a leading `.`, so neither a traversal
#: nor a dotfile can be named. See validate_token_basename for why that matters.
_TOKEN_BASENAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*$")


def validate_route_id(name: str, builtins: Sequence[str]) -> str | None:
    """The reason `name` is unusable as a route id, or None if it is fine."""
    if not name:
        return "the name is empty"
    if len(name) > 64:
        return "the name is longer than 64 characters"
    if name in builtins:
        return f"'{name}' is a built-in LLM route and cannot be redefined"
    if not _ROUTE_ID_RE.match(name):
        return (
            f"'{name}' is not a usable route name — use lowercase letters, digits, '.', '_' "
            "and '-' only, starting and ending with a letter or digit"
        )
    return None


def validate_token_basename(name: str) -> str | None:
    """The reason `name` is unusable as a credential FILENAME, or None if it is fine.

    This is a bare filename under `$KIB_DIR`, never a path. host/broker.sh interpolates it
    straight into `-v "$KIB_DIR/$basename:/run/broker/token/<id>:ro"`, so a `..` segment mounts
    an arbitrary host file into the broker and the relay then injects its bytes as the route's
    auth header — a pasted def would exfiltrate it to the def's own upstream. An empty value is
    just as bad: `$KIB_DIR/` is a directory, `[ -s ]` is true for it, and the whole credential
    store gets bound. Also keeps `list-providers` word-splittable, as its docstring promises.
    """
    if not name:
        return '"token_basename" is empty'
    if not _TOKEN_BASENAME_RE.match(name):
        return (
            f'"token_basename" is {name!r} — it must be a bare filename (letters, digits, '
            "'.', '_' and '-', starting with a letter or digit), never a path"
        )
    return None


def key_is_secret(k: str) -> bool:
    """A header/env NAME that names a credential (Authorization, *_TOKEN, API_KEY, …)."""
    return bool(_SECRET_KEY_RE.search(k or ""))


def value_has_auth_scheme(v: str) -> bool:
    """A VALUE that begins with a credential scheme (Bearer/Basic/sk-)."""
    return bool(_AUTH_SCHEME_RE.match(v or ""))


def value_is_secret(v: str) -> bool:
    """A VALUE shaped like a credential: a scheme prefix, or a long base64/hex blob.

    For ENV values, where a bare token is common. NOT used for header values — a 16-char
    MIME type like 'application/json' is valid base64, so header auth keys off the
    scheme/name (see `is_auth_header`) to avoid that false positive.
    """
    v = v or ""
    return bool(value_has_auth_scheme(v) or _B64_VAL_RE.fullmatch(v) or _HEX_VAL_RE.fullmatch(v))


def env_is_secret(kv: str) -> bool:
    """True if a `KEY=VALUE` env pair carries a credential — by KEY name or VALUE shape."""
    k, _, v = kv.partition("=")
    return key_is_secret(k) or value_is_secret(v)


def is_auth_header(name: str, value: str) -> bool:
    """True if an HTTP header carries auth — a known auth NAME, or a scheme-prefixed VALUE.

    Deliberately NOT the bare base64/hex heuristic: a common header value like
    'application/json' is valid base64 and must not read as a credential.
    """
    return (name or "").lower() in AUTH_HEADER_NAMES or value_has_auth_scheme(value)


def find_auth_header(headers: Sequence[Any]) -> tuple[str | None, str | None]:
    """Pick the credential-bearing header from `['Name: value', …]` or `[(name, value), …]`.

    Prefer a recognised auth NAME, else a scheme-prefixed VALUE — so the auth header need
    NOT be first (the old `headers[0]` assumption brokered the wrong header). Returns
    `(name, value)` or `(None, None)`.
    """
    pairs: list[tuple[str, str]] = []
    for h in headers:
        if isinstance(h, (list, tuple)):
            n, v = h[0], h[1]
        else:
            n, _, v = h.partition(":")
        pairs.append((n.strip(), v.strip()))
    for n, v in pairs:  # 1st preference: a recognised auth header name
        if v and (n or "").lower() in AUTH_HEADER_NAMES:
            return n, v
    for n, v in pairs:  # 2nd: a value carrying an explicit auth scheme
        if v and value_has_auth_scheme(v):
            return n, v
    return None, None


def scheme_of(header_value: str) -> str:
    """The auth-scheme prefix (Bearer/Basic/'') a header value carries."""
    for s in ("Bearer", "Basic"):
        if header_value.startswith(s + " "):
            return s
    return ""


def recover_secret(header_value: str, scheme: str) -> str:
    """The raw secret with its scheme prefix (if any) stripped."""
    v = header_value
    if scheme and v.startswith(scheme + " "):
        v = v[len(scheme) + 1 :]
    return v.strip()


def synthesize_reverse_proxy(
    name: str, url: str, header_name: str, scheme: str, transport: str = "http"
) -> dict[str, Any]:
    """Build a proxy provider def (NO secret in it) from an inline MCP entry.

    The one place this dict shape is defined for adopt/add/intercept. Raises ValueError on
    a non-http(s) url. No `delivery` — the registry sets that. No port: every route shares the
    one listener and is reached by its `/mcp/<id>` prefix.

    `mcp_server_name` IS set here, unlike the registry default: everything that reaches this
    function is describing a real MCP server, so it earns its `.claude.json` entry.
    """
    u = urllib.parse.urlsplit(url)
    if u.scheme not in ("http", "https") or not u.hostname:
        raise ValueError(f"cannot parse an http(s) upstream from url {url!r}")
    return {
        "id": name,
        "credential_kind": "paste_token",
        "upstream_origin": f"{u.scheme}://{u.netloc}",
        "path": u.path or "",
        "transport": transport if transport in ("http", "sse") else "http",
        "inject_header": header_name or "Authorization",
        "inject_template": (scheme + " {secret}") if scheme else "{secret}",
        "token_basename": f"{name}-token",
        "mcp_server_name": name,
    }


def write_provider_def(provdir: str, name: str, prov: dict[str, Any]) -> str:
    """Atomically write a provider def to `<provdir>/<name>.json` under a mode-700 dir."""
    os.makedirs(provdir, exist_ok=True)
    os.chmod(provdir, 0o700)
    path = os.path.join(provdir, name + ".json")
    write_atomic(path, prov, mode=0o600)
    return path


def store_secret(kib_dir: str, basename: str, secret: str) -> str:
    """Atomically write a secret to `<kib_dir>/<basename>`, mode 600.

    Never briefly world-readable: the umask covers the window between creation and chmod.
    """
    os.makedirs(kib_dir, exist_ok=True)
    os.chmod(kib_dir, 0o700)
    dest = os.path.join(kib_dir, basename)
    old = os.umask(0o077)
    try:
        tmp = dest + f".tmp.{os.getpid()}"
        with open(tmp, "w") as fh:
            fh.write(secret + "\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, dest)
    finally:
        os.umask(old)
    return dest
