"""Both sides — the provider/route table. The single source of truth for every route.

One row per route, with a FIXED upstream that is never chosen by the agent (a forward
proxy would be an egress bypass). The host reads the host-facing fields through
`kib broker host-config <id>`, so the bash side never duplicates this table.

`token_basename` names the HOST file (under `~/.keep-it-in-your-box/`) holding a static,
long-lived credential. It is mounted READ-ONLY into the broker and nowhere else.
"""

from __future__ import annotations

import json
import os
import urllib.parse
from typing import Any

from kib.broker.credential import FAR_FUTURE_MS
from kib.broker.helpers import validate_route_id

#: The ONE port every user MCP route shares, dispatched by a `/mcp/<id>` path prefix. A
#: per-route port knob is what took a launch down (two defs, one port, an unguarded bind), and
#: no amount of auto-assignment fixes a number the user can still edit. Clear of the LLM band
#: (8080–8082), which keeps its dedicated listeners. Each hosted_mcp sidecar reuses the number
#: inside its OWN netns, so there is nothing to collide with.
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
    # ── ready-but-unstarted (enable by dropping a host token file; no code change) ──
    # Same contract: a STATIC key. For Codex/Gemini that means an api-key, not the
    # ChatGPT/Google OAuth credential — those rotate exactly like Anthropic's.
    "codex": {
        "delivery": "base_url_env",
        "credential_kind": "paste_token",
        "agent_base_url_env": "OPENAI_BASE_URL",
        "agent_token_env": "OPENAI_API_KEY",
        "token_prefix": "sk-",
        "listen_port": 8081,
        "upstream_origin": "https://api.openai.com",
        "token_basename": "openai-token",
        "inject_header": "Authorization",
        "inject_template": "Bearer {secret}",
        "strip_incoming": ["authorization"],
        "allow_paths": ["/v1/"],
        "placeholder_container_path": "",
        "placeholder_template": None,
        "placeholder_fake_pointers": [],
        "probe": {"path": "/v1/models", "method": "GET", "headers": {}, "body": None},
    },
    "gemini": {
        "delivery": "base_url_env",
        "credential_kind": "paste_token",
        "agent_base_url_env": "GOOGLE_GEMINI_BASE_URL",
        "agent_token_env": "GEMINI_API_KEY",
        "token_prefix": "",
        "listen_port": 8082,
        "upstream_origin": "https://generativelanguage.googleapis.com",
        "token_basename": "gemini-token",
        "inject_header": "x-goog-api-key",
        "inject_template": "{secret}",
        "strip_incoming": ["authorization", "x-goog-api-key"],
        "allow_paths": ["/v1beta/", "/v1/"],
        "placeholder_container_path": "",
        "placeholder_template": None,
        "placeholder_fake_pointers": [],
        "probe": {"path": "/v1beta/models", "method": "GET", "headers": {}, "body": None},
    },
    # ── No MCP routes are built in ───────────────────────────────────────────────
    # Only the LLMs Claude Code natively speaks (above) are hardcoded. Every MCP —
    # DataForSEO, mcp-gsc, or a service we have never heard of — is USER-DEFINED, added
    # without touching this file. Two worked examples ship in examples/providers/.
}

#: The ids a user def may never take, snapshotted before any merge folds user rows in.
BUILTIN_IDS = tuple(PROVIDERS)

# ── User-defined providers: broker ANY MCP, no code change ───────────────────
# Any MCP is brokered by dropping a partial provider dict in ~/.keep-it-in-your-box/providers.d/
# — written by `kib mcp add`, synthesized by `kib mcp adopt`, or copied from examples/providers/.
# merge_user_providers() folds them onto PROVIDERS so list/host-config/serve/match treat a user
# route exactly like a built-in; _finalize fills the rest. The LLM built-ins are NOT overridable,
# so a poisoned file cannot redirect the Claude token's upstream.
#
# Two delivery modes cover every MCP:
#   reverse_proxy_mcp — REMOTE, with a STATIC auth header to a fixed upstream. Brokered like an
#     LLM: .claude.json gets `url: http://kib-broker:8100/mcp/<id><mcp_path>` and NO header.
#   hosted_mcp — LOCAL / client-signed (e.g. a service-account JSON), so it CANNOT be
#     header-brokered. The MCP server runs in its own sidecar holding the credential file.
_REQUIRED = {
    "reverse_proxy_mcp": ("upstream_origin", "inject_header", "inject_template"),
    "hosted_mcp": ("host_run",),
}

#: Keys a def must NOT carry. Each was a per-route port a user could hand-pick; two defs with
#: the same number took a whole launch down. Named on sight rather than ignored, because a def
#: written against the old shape is exactly the thing someone will paste from an old note.
_OBSOLETE = {
    "listen_port": "user MCP routes no longer have their own port",
    "mcp_port": "the hosted-MCP port is fixed",
}

#: One human-readable line per rejected/ignored def, refilled by every merge_user_providers().
#: Never contains file CONTENT — a def sits next to credentials and may hold a pasted one.
DEF_PROBLEMS: list[str] = []


def _finalize_provider(pid: str, p: dict[str, Any]) -> dict[str, Any]:
    """Fill fields a user file may omit so the rest of the package treats it as built-in."""
    p.setdefault("credential_kind", "paste_token")
    p.setdefault("token_basename", f"{pid}-token")
    p.setdefault("mcp_server_name", pid)
    p.setdefault("mcp_path", "")
    p.setdefault("mcp_transport", "http")
    # No allowlist = every path on the pinned upstream. The built-in LLM rows set one because
    # their credential is the user's real account token and the path set Claude Code needs is
    # known; a user MCP's endpoints are not, and guessing them wrong breaks the route silently.
    p.setdefault("allow_paths", [])
    p.setdefault("placeholder_container_path", "")
    p.setdefault("placeholder_template", None)
    p.setdefault("placeholder_fake_pointers", [])
    p.setdefault("probe", None)
    if p.get("delivery") == "reverse_proxy_mcp":
        p.setdefault("inject_header", "Authorization")
        p.setdefault("inject_template", "Bearer {secret}")
        p.setdefault("strip_incoming", [p["inject_header"].lower()])
    elif p.get("delivery") == "hosted_mcp":
        p.setdefault("extra_env", {})
        # Its own sidecar, its own netns: the shared number cannot collide with anything.
        p["mcp_port"] = MCP_PORT
    return p


def _validate(fn: str, pid: str, p: dict[str, Any]) -> list[str]:
    """Every reason this def cannot become a route. Empty means it is usable."""
    bad = validate_route_id(pid, BUILTIN_IDS)
    if bad:
        return [bad]
    if p.get("id") and p["id"] != fn[:-5]:
        return [f"its \"id\" is '{p['id']}' but the file is named {fn} — they must match"]
    delivery = p.get("delivery")
    need = _REQUIRED.get(delivery) if isinstance(delivery, str) else None
    if need is None:
        return [
            f'"delivery" is {delivery!r} — expected "reverse_proxy_mcp" (a remote MCP behind a '
            'static auth header) or "hosted_mcp" (a local server in its own sidecar)'
        ]
    problems = [f'"{k}" is missing' for k in need if p.get(k) in (None, "", [])]
    problems += [f'"{k}" is obsolete — {why}' for k, why in _OBSOLETE.items() if k in p]
    if delivery == "reverse_proxy_mcp":
        # The path belongs in mcp_path: the relay joins origin + forwarded path, so a path
        # here would silently vanish rather than fail.
        origin = urllib.parse.urlsplit(str(p.get("upstream_origin", "")))
        if origin.scheme not in ("http", "https") or not origin.hostname:
            problems.append('"upstream_origin" must be an http(s) origin, e.g. https://mcp.x.com')
        elif origin.path:
            problems.append(
                f'"upstream_origin" carries the path {origin.path!r} — put it in "mcp_path"'
            )
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
    """The URL path the AGENT requests for an MCP route ('' for a non-MCP row).

    reverse_proxy_mcp rows are multiplexed behind `/mcp/<id>`; a hosted_mcp row has a whole
    sidecar to itself and keeps its bare `mcp_path`. One definition so `inject`, `host-config`
    and `kib broker status` cannot print three different URLs.
    """
    tail = p.get("mcp_path") or ""
    delivery = p.get("delivery")
    if delivery == "reverse_proxy_mcp":
        return f"{MCP_PREFIX}/{pid}{tail}"
    return tail if delivery == "hosted_mcp" else ""


def agent_url(pid: str, p: dict[str, Any], host: str) -> str:
    """The full `http://<host>:8100/…` URL the agent's .claude.json gets for an MCP route."""
    return f"http://{host}:{MCP_PORT}{route_path(pid, p)}"


def match_upstream_route(url: str) -> tuple[str, str, str] | None:
    """`(id, token_basename, auth_scheme)` for an EXISTING reverse_proxy_mcp route.

    Matches on `url`'s host (always a user-defined route — no MCP is built in), so
    `kib mcp adopt` can reuse a route the user already added instead of synthesizing a
    duplicate. `auth_scheme` is the literal prefix the inject template puts before the
    secret (Basic / Bearer / empty), so the caller can strip it off the inline header to
    recover the raw stored secret.
    """
    host = (urllib.parse.urlsplit(url).hostname or "").lower()
    if not host:
        return None
    for pid, p in PROVIDERS.items():
        if p.get("delivery") != "reverse_proxy_mcp":
            continue
        up = (urllib.parse.urlsplit(p["upstream_origin"]).hostname or "").lower()
        if up and up == host:
            scheme = p.get("inject_template", "{secret}").replace("{secret}", "").strip()
            return pid, p.get("token_basename", ""), scheme
    return None
