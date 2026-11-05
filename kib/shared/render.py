"""What a redacted file reads as: its key names, every value replaced, or a flat stub.

Shared because both sides render: the FUSE view in the box, and the host when a VM's synced copy
must hold the keys but never the values (host/vm.sh). PyYAML is image-side only (CONVENTIONS.md):
a host without it stubs YAML, which is the safe direction.
"""

from __future__ import annotations

import json
import re
from typing import Any

try:
    import yaml

    # libyaml if the build has it (Debian's python3-yaml does), ~30x the pure-python scanner.
    try:
        from yaml import CSafeDumper as SafeDumper
        from yaml import CSafeLoader as SafeLoader
    except ImportError:  # pragma: no cover — a PyYAML built without the extension
        from yaml import SafeDumper, SafeLoader
except ImportError:  # pragma: no cover — stock macOS python3
    yaml = None

STUB = (
    b"# REDACTED BY .kibignore \xe2\x80\x94 hidden from this Claude Code Docker sandbox"
    b" by user policy.\n"
    b"# Intentional, not an error. All access paths return this stub; writes return EPERM.\n"
    b"# Ask the user directly if you need the contents \xe2\x80\x94 don't try to work around it.\n"
)

# ── format-aware redaction ───────────────────────────────────────
# A redacted file whose *shape* is known reads as its key names with every value replaced.
# The whole-file stub hid which settings even exist, so the agent's next move was to ask the
# user, who pasted the value into the transcript — the stub caused the leak it prevented.
#
# THE RULE: never pass a byte of the file through. Output is synthesised from parsed tokens
# (key names only); anything a parser cannot vouch for falls back to STUB, so a comment, a
# continuation or a value containing '#' or '=' cannot leak by construction.
#
# Accepted residual: a file where the *key* is the secret. Documented in etc-CLAUDE.md.
REDACTED_VALUE = "<redacted>"
RENDER_MAX = 64 * 1024  # config and credential files; bigger is not one of these shapes
DOTENV_KEY = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=")
#: The cheapest necessary condition for "parses as a YAML mapping": one `key:` line. A scan is
#: microseconds where the parser is milliseconds, and YAML is the last renderer tried — so
#: without this every redacted file that ends up STUBBED (a .pem, a key, a lockfile) pays a full
#: parse of up to RENDER_MAX first, on every cache miss.
YAML_MAPPING = re.compile(r"^\s*[^\s#][^:\n]*:(?:\s|$)", re.MULTILINE)


def _scrub(node: Any) -> Any:
    """A JSON tree with every scalar leaf replaced. Keys and structure survive, values don't."""
    if isinstance(node, dict):
        return {k: _scrub(v) for k, v in node.items()}
    if isinstance(node, list):
        return [_scrub(v) for v in node]
    return REDACTED_VALUE


def _render_json(text: str) -> bytes | None:
    # RecursionError alongside ValueError: `[`×30000 is 60 KB of *valid* JSON that overflows
    # the decoder, and _scrub recurses too. Uncaught it would surface as an unexplained read
    # failure rather than the stub — the class of bug the pread note below is about.
    try:
        return (json.dumps(_scrub(json.loads(text)), indent=2) + "\n").encode()
    except (ValueError, RecursionError):
        return None


def _render_dotenv(text: str) -> bytes | None:
    """`KEY=<redacted>` per assignment, or None for anything that is not wholly dotenv.

    Every line must be blank, a comment or an assignment — skipping the ones it cannot parse
    would let this claim any prose file holding a single `A=1`, and render it as if that were
    the whole content. A multi-line quoted value bails for a sharper reason: its own interior
    lines match the key pattern, so fragments of the secret would print as if they were names.
    """
    keys: list[str] = []
    for line in text.splitlines():
        m = DOTENV_KEY.match(line)
        if not m:
            if line.strip() and not line.lstrip().startswith("#"):
                return None
            continue
        value = line[m.end() :].lstrip()
        quote = value[:1]
        if quote in ('"', "'"):
            tail = value[1:].rstrip()
            if not tail.endswith(quote) or tail.endswith("\\" + quote):
                return None
        keys.append(m.group(1))
    return "".join(f"{k}={REDACTED_VALUE}\n" for k in keys).encode() if keys else None


def _render_yaml(text: str) -> bytes | None:
    """`key: <redacted>` per mapping entry, or None for anything that is not a mapping.

    An ALIAS anywhere bails, and it is found on the event stream — the one representation that
    reports aliases without expanding them. The loader does expand them, and a billion-laughs
    file fits into RENDER_MAX many times over: it would exhaust the sidecar, which is
    container-global and takes the project view down for every session, instead of stubbing one
    file. Nothing has to READ the file for that — `getattr` renders it to report a size, so `ls`
    is enough. A regex over the text was tried first and is not good enough: it missed flow
    style (`a: [&x [...]]`, where the sigil follows `[` rather than whitespace) and a measured
    212-byte file built 1.5 MB.

    A document that is not a mapping bails too: YAML reads almost any text as one big scalar,
    which would render as a bare `<redacted>` — the flat stub, with a parse in front of it.
    """
    # Both cheap bails come first, and `":" in text` before the regex is not a micro-optimisation:
    # a redacted file that is NEITHER dotenv nor YAML (a .pem, a key, a lockfile) reaches here
    # having matched nothing, and a whole-file regex scan of one costs ~0.6 ms against ~0.001 ms.
    if yaml is None or ":" not in text or not YAML_MAPPING.search(text):
        return None
    try:
        # An alias is always spelled `*anchor`, so no `*` in the file means there is no alias to
        # find and the event scan (~4 ms on a 52 KiB file) can be skipped outright. Exact, not a
        # heuristic — unlike the regex over sigil CONTEXT that this replaced.
        if "*" in text and any(
            isinstance(e, yaml.AliasEvent) for e in yaml.parse(text, SafeLoader)
        ):
            return None
        docs = list(yaml.load_all(text, Loader=SafeLoader))
        if not docs or not all(isinstance(d, dict) for d in docs):
            return None
        # Annotated because PyYAML is untyped here (pyproject's ignore_missing_imports), so the
        # dump is Any and would widen this function's return.
        dumped: str = yaml.dump_all(
            [_scrub(d) for d in docs], Dumper=SafeDumper, default_flow_style=False
        )
    except (yaml.YAMLError, RecursionError, MemoryError):
        # The scrub and the dump are INSIDE this: a recursive alias survives the loader and
        # blows the stack on the way out, and an uncaught one leaves the caller an EFAULT it
        # cannot explain rather than the stub. Same class as _render_json's RecursionError.
        return None
    return dumped.encode()


#: Tried in order until one vouches for the WHOLE file; the name is not consulted at all. It
#: used to be (`*.json`, `.env`, `.env.*`), which stubbed every secrets file a project spells
#: its own way — `env_vars/env_prod`, `sls_config/env-dev.yml` — and the stub is what makes the
#: agent ask the user for a value. Order is load-bearing: dotenv leads because `A=1` also parses
#: as a YAML scalar, and JSON precedes YAML (its superset) for the tighter output.
RENDERERS = (_render_dotenv, _render_json, _render_yaml)


def render(real: str) -> bytes:
    """What a redacted file serves on read. STUB on any doubt — unknown shape, parse failure,
    unreadable, undecodable, or too large to be one of these shapes."""
    # Bounded read rather than a size check then a read: one syscall fewer, and no window in
    # which the file grows past the cap between the two. utf-8-SIG so a BOM (any editor on
    # Windows) does not cost a whole file its keys: every renderer vouches for the text
    # entirely, so one unparseable first line is now the difference between keys and the stub.
    try:
        with open(real, encoding="utf-8-sig", errors="strict") as fh:
            text = fh.read(RENDER_MAX + 1)
    except (OSError, UnicodeDecodeError):
        return STUB
    if len(text) > RENDER_MAX:
        return STUB
    for renderer in RENDERERS:
        out = renderer(text)
        if out is not None:
            return out
    return STUB
