"""Both sides — the broker's command surface.

Two output contracts are parsed by bash and must not drift:

* `host-config <id>` emits `KEY='value'` lines, **shell-quoted**, so `eval` stays safe when
  a value contains spaces — unquoted, the shell would read `VAR=word cmd` and try to run `cmd`.
* `list-providers` emits exactly one line per route, `id|delivery|credential_kind|
  token_basename`, all fields `[a-z0-9._-]` so POSIX word-splitting is safe. Scopes and paths
  deliberately stay OUT of it: they contain `/` and `:` and would break that contract.

Verbs:
    serve --config <f>            run the proxy (PID 1 of the broker sidecar)
    host-config <id>              shell KEY=VALUE facts for the host (single source of truth)
    list-providers                the registry, one route per line
    check-providers               one line per unusable providers.d def (empty = all fine)
    check-name <id>               is this usable as a route name? prints the reason if not
    route-url <id> <broker-host>  the URL the agent gets for a proxy route
    oauth-state <id> <out-dir>    one line: an OAuth route's scopes and live mint state
    route-fingerprint             `id|route_path|upstream` per route, for the attach hash
    probe <credfile> <id>         is this credential accepted? 0 yes / 1 no / 2 unknown
"""

from __future__ import annotations

import http.client
import json
import os
import shlex
import ssl
import time
import urllib.parse

from kib.broker import helpers, oauth, proxy, registry
from kib.broker.credential import fake
from kib.shared import cli


def _emit(key: str, value: object) -> None:
    print(f"{key}={shlex.quote(str(value))}")


def host_config(pid: str) -> int:
    """Emit the host-facing facts for one provider, eval-safe.

    A fresh placeholder token is emitted here too, so the host gets everything it needs for
    the agent from ONE python spawn on the launch path. It is a `fake_value_` sentinel with
    the provider's prefix — safe to eval, and never a real credential.
    """
    p = registry.PROVIDERS.get(pid)
    if p is None:
        raise cli.AbortError(f"unknown provider: {pid}", cli.USAGE)
    _emit("KIB_BROKER_BASE_URL_ENV", p.get("agent_base_url_env", ""))
    _emit("KIB_BROKER_TOKEN_ENV", p.get("agent_token_env", ""))
    _emit("KIB_BROKER_PLACEHOLDER_TOKEN", fake(p.get("token_prefix", "")))
    _emit("KIB_BROKER_LISTEN_PORT", p.get("listen_port") or "")  # LLM rows only
    _emit("KIB_BROKER_PLACEHOLDER_CONTAINER_PATH", p.get("placeholder_container_path", ""))
    _emit("KIB_BROKER_TOKEN_BASENAME", p.get("token_basename", ""))
    _emit("KIB_BROKER_DELIVERY", p["delivery"])
    # The rest of the MCP wiring — server name, path, transport, the agent's URL — is not
    # emitted: `kib.host.mcp` builds the .claude.json entry in-process and reads the registry
    # itself. Bash only needs the port, to publish it.
    # The one shared proxy port; empty for the LLM row, reached by env var and not by URL.
    _emit("KIB_BROKER_MCP_PORT", registry.MCP_PORT if p["delivery"] != "base_url_env" else "")
    return cli.OK


def list_providers() -> int:
    """One line per route: `id|delivery|credential_kind|token_basename`."""
    for pid, p in registry.PROVIDERS.items():
        print(f"{pid}|{p['delivery']}|{p.get('credential_kind', '')}|{p.get('token_basename', '')}")
    return cli.OK


def check_providers() -> int:
    """One line per unusable def in providers.d. Silence means every def loaded.

    These diagnostics used to reach only the sidecar's stderr — a different container, whose
    log you have to know to go looking for. The host prints this before it starts anything.
    """
    for problem in registry.DEF_PROBLEMS:
        print(f"providers.d/{problem}")
    return cli.OK


def check_name(name: str) -> int:
    """Exit 0 if `name` is usable as a route id, else print the reason and exit REFUSED."""
    bad = helpers.validate_route_id(name, registry.BUILTIN_IDS)
    if bad:
        print(bad)
        return cli.REFUSED
    return cli.OK


def route_url(pid: str, broker_host: str) -> int:
    """The URL the agent gets for a proxy route. Empty (but OK) for the LLM row.

    `broker_host` is passed in, never held here: host/broker.sh owns that string — it is what
    `--network-alias` actually creates — and a second copy could only ever drift into printing
    a URL that resolves to nothing.
    """
    p = registry.PROVIDERS.get(pid)
    if p is None:
        raise cli.AbortError(f"unknown provider: {pid}", cli.USAGE)
    print(registry.agent_url(pid, p, broker_host) if registry.route_path(pid, p) else "")
    return cli.OK


def oauth_state(pid: str, state_dir: str) -> int:
    """One human line about an OAuth route: its scopes, and its live mint state if known.

    Scopes come from the registry and are always available. The live half comes from the file
    the broker writes into `$BROKER_OUT`, which only exists once a container has run — and
    `kib broker status` is host-GLOBAL, dispatched before project paths resolve, so it usually
    passes an empty dir. Degrading to scopes-only is the normal case, not an error.
    """
    p = registry.PROVIDERS.get(pid)
    if p is None or p.get("credential_kind") != "oauth":
        return cli.OK
    scopes = p.get("scopes") or []
    line = f"scopes: {', '.join(scopes) if scopes else '(none declared)'}"
    # Everything that reads the state file is inside the guard: it is a diagnostic, and a
    # truncated or hand-edited one must degrade to "scopes only", never crash a status run
    # whose caller redirects stderr and would show the user nothing at all.
    try:
        if not state_dir:
            raise OSError
        with open(os.path.join(state_dir, f"{pid}.oauth")) as fh:
            state = json.load(fh)
        if not isinstance(state, dict):
            raise ValueError
        outcome = str(state.get("last_mint", ""))
        if outcome and outcome != "ok":
            line += f" · last mint FAILED: {outcome}"
        else:
            left = int(state.get("expires_at") or 0) - int(time.time())
            grant = state.get("grant") or "?"
            valid = f"token valid {left // 60}m" if left > 0 else "token expired"
            line += f" · {grant} · {valid}"
    except (OSError, ValueError, TypeError):
        pass
    print(line)
    return cli.OK


def route_fingerprint() -> int:
    """`id|route_path|upstream` per route — what a container's broker wiring actually IS.

    Hashed into the attach guard: hashing ids alone let an edited def leave a running
    container serving the old upstream while `kib` happily attached a second terminal.
    """
    for pid, p in registry.PROVIDERS.items():
        print(f"{pid}|{registry.route_path(pid, p)}|{p.get('upstream_origin', '')}")
    return cli.OK


def serve(config_path: str) -> int:
    proxy.serve(config_path)
    return cli.OK


def _probe_oauth(token_path: str, p: dict[str, object]) -> int:
    """An OAuth config's probe is a real mint — the only test that proves it works.

    Except for a service account: RS256 needs `cryptography`, which lives in the image and
    not on a stock host, so the shape is checked here and the mint is left to first launch.
    """
    try:
        with open(token_path) as fh:
            cfg = json.load(fh)
    except (OSError, ValueError) as e:
        print(f"cannot read the credential file as JSON: {type(e).__name__}")
        return 2
    bad = oauth.validate_config(cfg)
    if bad:
        print(f"❌ {bad}")
        return 1
    if cfg.get("type") == "service_account":
        print(
            f"⚠️  service-account config for {cfg.get('client_email', '?')} looks complete. "
            "Signing needs the image, so it is verified at first launch — kib broker status."
        )
        return 2

    scopes = p.get("scopes") or []
    try:
        _, lifetime, rotated = oauth.mint(cfg, scopes if isinstance(scopes, list) else [])
    except oauth.OAuthError as e:
        if e.retryable:
            print(f"⚠️  inconclusive: {e}. The credential was not rejected — retry.")
            return 2
        print(f"❌ the token endpoint REJECTED this credential: {e}")
        return 1
    if rotated:
        print(
            "⚠️  this provider ROTATES its refresh token. The broker never writes a credential, "
            "so the rotated one is discarded and this route will stop working once the provider "
            "invalidates the stored one."
        )
    print(f"✅ minted an access token (valid {lifetime}s)")
    return 0


def probe(token_path: str, pid: str) -> int:
    """Exit 0 if the upstream ACCEPTS the credential, 1 if it rejects it, 2 if we cannot tell.

    Distinguishing 'rejected' from 'something else went wrong' is the whole point: a 401
    means re-login, while a 429/500/network error means try again later and says nothing
    about the token. Prints status and error *type* only — never the token, and never a
    response body, which can echo request content.
    """
    p = registry.PROVIDERS.get(pid)
    if p is None:
        raise cli.AbortError(f"unknown provider: {pid}", cli.USAGE)
    if p.get("credential_kind") == "oauth":
        return _probe_oauth(token_path, p)
    spec = p.get("probe")
    if not spec:
        print(f"no probe defined for {pid}")
        return 2
    try:
        with open(token_path) as fh:
            token = fh.read().strip()
    except OSError as e:
        print(f"cannot read the token file: {e.strerror}")
        return 2
    if not token:
        print("the token file is empty")
        return 1

    origin = urllib.parse.urlsplit(p["upstream_origin"])
    headers = dict(spec.get("headers", {}))
    headers[p["inject_header"]] = p["inject_template"].format(secret=token)
    body = json.dumps(spec["body"]).encode() if spec.get("body") is not None else None
    method = spec.get("method", "POST" if body else "GET")

    try:
        conn = http.client.HTTPSConnection(
            origin.hostname, origin.port or 443, context=ssl.create_default_context(), timeout=30
        )
        conn.request(method, spec["path"], body=body, headers=headers)
        resp = conn.getresponse()
        status = resp.status
        raw = resp.read(4096)
        conn.close()
    except Exception as e:  # noqa: BLE001
        print(f"could not reach {origin.hostname}: {type(e).__name__}")
        return 2

    kind = ""
    try:
        kind = (json.loads(raw).get("error") or {}).get("type", "")
    except Exception:  # noqa: BLE001
        pass
    detail = f", {kind}" if kind else ""

    if status == 200:
        print(f"✅ token accepted by {origin.hostname} (HTTP 200)")
        return 0
    if status in (401, 403):
        print(
            f"❌ token REJECTED by {origin.hostname} (HTTP {status}{detail})"
            " — mint a new one with: kib broker login"
        )
        return 1
    print(
        f"⚠️  inconclusive: {origin.hostname} answered HTTP {status}{detail}. The token was "
        "not rejected, so this is probably rate limiting or an upstream problem — retry."
    )
    return 2


TABLE: dict[str, tuple[cli.Command, int]] = {
    "serve": (serve, 1),
    "host-config": (host_config, 1),
    "list-providers": (list_providers, 0),
    "check-providers": (check_providers, 0),
    "check-name": (check_name, 1),
    "route-url": (route_url, 2),
    "oauth-state": (oauth_state, 2),
    "route-fingerprint": (route_fingerprint, 0),
    "probe": (probe, 2),
}


def main(argv: list[str]) -> int:
    # Fold ~/.keep-it-in-your-box/providers.d/*.json onto the LLM built-ins first, so every
    # verb — list, host-config, serve, match — sees the same table.
    registry.merge_user_providers()
    return cli.dispatch("kib broker", TABLE, argv)


if __name__ == "__main__":
    cli.run(main)
