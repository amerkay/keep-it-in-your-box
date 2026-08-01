"""Both sides — the provider/route table. The single source of truth for every route.

One row per route, with a FIXED upstream that is never chosen by the agent (a forward
proxy would be an egress bypass). The host reads the host-facing fields through
`kib broker host-config <id>`, so the bash side never duplicates this table.

`token_basename` names the HOST file (under `~/.keep-it-in-your-box/`) holding the route's
credential — a long-lived secret for `paste_token`, an OAuth config for `oauth`. It is mounted
READ-ONLY into the broker and nowhere else, and the broker never writes it.
"""

from __future__ import annotations

import json
import os
import urllib.parse
from typing import Any

from kib.broker.credential import FAR_FUTURE_MS
from kib.broker.helpers import validate_route_id, validate_token_basename

#: The ONE port every user route shares, dispatched by a `/mcp/<id>` path prefix. A per-route
#: port knob is what took a launch down (two defs, one port, an unguarded bind), and no amount
#: of auto-assignment fixes a number the user can still edit. Clear of the LLM band (8080),
#: which keeps its dedicated listener.
MCP_PORT = 8100
MCP_PREFIX = "/mcp"

PROVIDERS: dict[str, dict[str, Any]] = {
    "claude": {
        "delivery": "base_url_env",
        "credential_kind": "paste_token",  # a token the user pastes (vs a file path)
        "agent_base_url_env": "ANTHROPIC_BASE_URL",
        # The agent's auth env var, set to a PLACEHOLDER. CLAUDE_CODE_OAUTH_TOKEN takes
        # precedence over .credentials.json, so the agent authenticates through the broker
        # even though the shadowed credential file is also synthetic.
        "agent_token_env": "CLAUDE_CODE_OAUTH_TOKEN",
        "token_prefix": "sk-ant-oat01-",
        "listen_port": 8080,
        "upstream_origin": "https://api.anthropic.com",
        "token_basename": "claude-token",
        # header to inject upstream, and what to strip from the agent's request first.
        "inject_header": "Authorization",
        "inject_template": "Bearer {secret}",
        "strip_incoming": ["authorization", "x-api-key"],
        # Path prefixes the box may reach with the real token attached. The origin was always
        # pinned, so this is not about SSRF — it is about what the box can DO with an
        # authenticated request it never sees the credential for. `/v1/` is the whole inference
        # surface Claude Code uses; `/api/oauth/profile` is the read-only account lookup it
        # makes at startup. Everything else on the account-management surface — key minting,
        # organization writes — 404s here. (audit MAC-L2 / R3)
        "allow_paths": ["/v1/", "/api/oauth/profile"],
        # Synthetic placeholder shadowing the real credential file in the container. Built
        # from this template — the broker NEVER reads the user's real .credentials.json.
        "placeholder_container_path": "/home/hostuser/.claude-shared/.credentials.json",
        "placeholder_template": {
            "claudeAiOauth": {
                "accessToken": None,  # filled with a fake at mint time
                "refreshToken": None,
                "expiresAt": FAR_FUTURE_MS,
                "refreshTokenExpiresAt": FAR_FUTURE_MS,
                "scopes": ["user:inference", "user:profile"],
                "subscriptionType": "max",
            }
        },
        "placeholder_fake_pointers": [
            "/claudeAiOauth/accessToken",
            "/claudeAiOauth/refreshToken",
        ],
        # Host-side probe: the smallest request that proves the token is accepted.
        "probe": {
            "path": "/v1/messages",
            "headers": {
                "anthropic-version": "2023-06-01",
                "anthropic-beta": "oauth-2025-04-20",
                "content-type": "application/json",
            },
            "body": {
                "model": "claude-haiku-4-5-20251001",
                "max_tokens": 1,
                "system": [
                    {
                        "type": "text",
                        "text": "You are Claude Code, Anthropic's official CLI for Claude.",
                    }
                ],
                "messages": [{"role": "user", "content": "hi"}],
            },
        },
    },
    # ── Nothing else is built in ─────────────────────────────────────────────────
    # Only the LLM Claude Code natively speaks is hardcoded. Every other service —
    # DataForSEO, Google Search Console, or one we have never heard of — is USER-DEFINED,
    # added without touching this file. Two worked examples ship in examples/providers/.
}

#: The ids a user def may never take, snapshotted before any merge folds user rows in.
BUILTIN_IDS = tuple(PROVIDERS)

# ── User-defined providers: broker ANY service, no code change ───────────────
# A service is brokered by dropping a partial provider dict in ~/.keep-it-in-your-box/
# providers.d/ — written by `kib broker add`, synthesized by `kib mcp adopt`, or copied from
# examples/providers/. merge_user_providers() folds them onto PROVIDERS so
# list/host-config/serve/match treat a user route exactly like the built-in; _finalize fills the
# rest. The LLM built-in is NOT overridable, so a poisoned file cannot redirect the Claude token.
#
# Every user route is a reverse proxy to a fixed upstream — `delivery` is ours to set, never
# theirs to declare. What varies is where the injected secret COMES FROM (`credential_kind`):
#   paste_token — a static credential the user pasted, injected verbatim.
#   oauth       — an OAuth 2.0 config file the broker exchanges for a short-lived access token
#                 (kib/broker/oauth.py). The config never leaves the sidecar.
#
# `upstream_origin` is the only field a def MUST carry; everything else has a default.

#: The credential sources a def may name. Anything else is a typo worth naming on sight —
#: unrecognised, it would silently fall through to "inject the file's bytes as a header".
CREDENTIAL_KINDS = ("paste_token", "oauth")

#: Keys that are no longer part of the schema, and what to do instead. A def carrying one is
#: REFUSED — not migrated, and never quietly ignored. Ignoring `mcp_path` is the worst case
#: available: the def still loads, the route still comes up, and it answers at the wrong URL,
#: which reads as a broken service rather than a stale file. The same reasoning retired the
#: per-route port knob. Named on sight, because a def written against the old shape is exactly
#: what someone pastes from an old note.
_REMOVED = {
    "mcp_path": 'renamed — use "path"',
    "mcp_transport": 'renamed — use "transport"',
    "delivery": "removed — every user route is a proxy route and the registry sets this",
    "listen_port": "removed — every route shares one listener, told apart by name",
    "mcp_port": "removed — every route shares one listener, told apart by name",
    "host_run": "removed — a local MCP server is no longer brokered; use an oauth route",
    "credential_env": "removed with the hosted-MCP sidecar",
    "extra_env": "removed with the hosted-MCP sidecar",
}

#: One human-readable line per rejected/ignored def, refilled by every merge_user_providers().
#: Never contains file CONTENT — a def sits next to credentials and may hold a pasted one.
DEF_PROBLEMS: list[str] = []


def _finalize_provider(pid: str, p: dict[str, Any]) -> dict[str, Any]:
    """Fill fields a user file may omit so the rest of the package treats it as built-in."""
    # Ours, unconditionally: a user def that names a delivery cannot promote itself to the
    # LLM row's shape (env var + shadowed credential file).
    p["delivery"] = "reverse_proxy"
    kind = p.setdefault("credential_kind", "paste_token")
    # An OAuth config is a JSON document, not a pasted line — name the file for what it holds.
    p.setdefault("token_basename", f"{pid}.json" if kind == "oauth" else f"{pid}-token")
    p.setdefault("scopes", [])
    p.setdefault("path", "")
    p.setdefault("transport", "http")
    # NO default server name: registering is opt-in. Defaulting it to the route id put every
    # REST-only route into .claude.json as an MCP server that Claude Code then shows as failed.
    p.setdefault("mcp_server_name", "")
    # No allowlist = every path on the pinned upstream. The LLM row sets one because its
    # credential is the user's real account token and the path set Claude Code needs is known;
    # a user route's endpoints are not, and guessing them wrong breaks the route silently.
    p.setdefault("allow_paths", [])
    p.setdefault("placeholder_container_path", "")
    p.setdefault("placeholder_template", None)
    p.setdefault("placeholder_fake_pointers", [])
    p.setdefault("probe", None)
    p.setdefault("inject_header", "Authorization")
    p.setdefault("inject_template", "Bearer {secret}")
    p.setdefault("strip_incoming", [p["inject_header"].lower()])
    return p


def _validate(fn: str, pid: str, p: dict[str, Any]) -> list[str]:
    """Every reason this def cannot become a route. Empty means it is usable."""
    bad = validate_route_id(pid, BUILTIN_IDS)
    if bad:
        return [bad]
    if p.get("id") and p["id"] != fn[:-5]:
        return [f"its \"id\" is '{p['id']}' but the file is named {fn} — they must match"]
    # Only fields a def actually CARRIES are checked — the rest are filled by _finalize, which
    # runs after this. setdefault cannot repair an explicit empty value, so catch it here.
    problems = [
        f'"{k}" must be a non-empty string'
        for k in ("inject_header", "inject_template")
        if k in p and not (isinstance(p[k], str) and p[k])
    ]
    problems += [f'"{k}" is {why}' for k, why in _REMOVED.items() if k in p]
    tmpl = p.get("inject_template")
    if isinstance(tmpl, str) and tmpl and "{secret}" not in tmpl:
        # Without the placeholder the credential is silently dropped and every request goes
        # out unauthenticated — a 401 that looks like a bad credential, not a bad def.
        problems.append('"inject_template" must contain {secret}')
    if "token_basename" in p:
        bad_name = validate_token_basename(str(p["token_basename"]))
        if bad_name:
            problems.append(bad_name)
    kind = p.get("credential_kind", "paste_token")
    if kind not in CREDENTIAL_KINDS:
        problems.append(f'"credential_kind" is {kind!r} — expected one of {CREDENTIAL_KINDS}')
    if not isinstance(p.get("scopes", []), list):
        problems.append('"scopes" must be a list of strings')
    # The path belongs in "path": the relay joins origin + forwarded path, so a path on the
    # origin would silently vanish rather than fail.
    origin = urllib.parse.urlsplit(str(p.get("upstream_origin", "")))
    if origin.scheme not in ("http", "https") or not origin.hostname:
        problems.append('"upstream_origin" must be an http(s) origin, e.g. https://api.x.com')
    elif origin.path:
        problems.append(f'"upstream_origin" carries the path {origin.path!r} — put it in "path"')
    return problems


def merge_user_providers() -> None:
    """Fold `$KIB_PROVIDERS_DIR/*.json` onto the built-in table. Idempotent."""
    DEF_PROBLEMS.clear()
    d = os.environ.get("KIB_PROVIDERS_DIR")
    if not d or not os.path.isdir(d):
        return
    for fn in sorted(os.listdir(d)):
        path = os.path.join(d, fn)
        if not os.path.isfile(path):
            continue
        if not fn.endswith(".json"):
            # Silence here is what made the original incident unreadable: the file existed,
            # was never loaded, and nothing anywhere said so.
            DEF_PROBLEMS.append(f"{fn}: only *.json files are read — rename it to {fn}.json")
            continue
        try:
            with open(path) as fh:
                p = json.load(fh)
        except (OSError, ValueError) as e:
            DEF_PROBLEMS.append(f"{fn}: unreadable or not valid JSON ({type(e).__name__})")
            continue
        if not isinstance(p, dict):
            DEF_PROBLEMS.append(f"{fn}: the top level must be a JSON object")
            continue
        pid = p.get("id") or fn[:-5]
        problems = _validate(fn, str(pid), p)
        if problems:
            DEF_PROBLEMS.extend(f"{fn}: {why}" for why in problems)
            continue
        PROVIDERS[str(pid)] = _finalize_provider(str(pid), p)


def route_path(pid: str, p: dict[str, Any]) -> str:
    """The URL path the AGENT requests for a proxy route ('' for the LLM row).

    Every proxy route is multiplexed behind `/mcp/<id>`. One definition so `inject`,
    `host-config` and `kib broker status` cannot print three different URLs.
    """
    if p.get("delivery") != "reverse_proxy":
        return ""
    return f"{MCP_PREFIX}/{pid}{p.get('path') or ''}"


def agent_url(pid: str, p: dict[str, Any], host: str) -> str:
    """The full `http://<host>:8100/…` URL the agent gets for a proxy route."""
    return f"http://{host}:{MCP_PORT}{route_path(pid, p)}"


def match_upstream_route(url: str) -> tuple[str, str, str] | None:
    """`(id, token_basename, auth_scheme)` for an EXISTING proxy route.

    Matches on `url`'s host (always a user-defined route — only the LLM row is built in), so
    `kib mcp adopt` can reuse a route the user already added instead of synthesizing a
    duplicate. `auth_scheme` is the literal prefix the inject template puts before the
    secret (Basic / Bearer / empty), so the caller can strip it off the inline header to
    recover the raw stored secret.
    """
    host = (urllib.parse.urlsplit(url).hostname or "").lower()
    if not host:
        return None
    for pid, p in PROVIDERS.items():
        if p.get("delivery") != "reverse_proxy":
            continue
        up = (urllib.parse.urlsplit(p["upstream_origin"]).hostname or "").lower()
        if up and up == host:
            scheme = p.get("inject_template", "{secret}").replace("{secret}", "").strip()
            return pid, p.get("token_basename", ""), scheme
    return None
