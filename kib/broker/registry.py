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
import sys
import urllib.parse
from typing import Any

from kib.broker.credential import FAR_FUTURE_MS

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

# ── User-defined providers: broker ANY MCP, no code change ───────────────────
# Any MCP is brokered by dropping a partial provider dict in ~/.keep-it-in-your-box/providers.d/
# — written by `kib mcp add`, synthesized by `kib mcp adopt`, or copied from examples/providers/.
# merge_user_providers() folds them onto PROVIDERS so list/host-config/serve/match treat a user
# route exactly like a built-in; _finalize fills the rest. The LLM built-ins are NOT overridable,
# so a poisoned file cannot redirect the Claude token's upstream.
#
# Two delivery modes cover every MCP:
#   reverse_proxy_mcp — REMOTE, with a STATIC auth header to a fixed upstream. Brokered like an
#     LLM: .claude.json gets `url: http://kib-broker:<port><mcp_path>` and NO header.
#   hosted_mcp — LOCAL / client-signed (e.g. a service-account JSON), so it CANNOT be
#     header-brokered. The MCP server runs in its own sidecar holding the credential file.
_REQUIRED = {
    "reverse_proxy_mcp": ("upstream_origin", "listen_port", "inject_header", "inject_template"),
    "hosted_mcp": ("host_run", "mcp_port"),
}

#: Delivery modes the broker sidecar itself serves (the rest run in their own sidecar).
SIDECAR_SERVED = ("base_url_env", "reverse_proxy_mcp")


def _finalize_provider(pid: str, p: dict[str, Any]) -> dict[str, Any]:
    """Fill fields a user file may omit so the rest of the package treats it as built-in."""
    p.setdefault("credential_kind", "paste_token")
    p.setdefault("token_basename", f"{pid}-token")
    p.setdefault("mcp_server_name", pid)
    p.setdefault("mcp_path", "")
    p.setdefault("mcp_transport", "http")
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
    return p


def merge_user_providers() -> None:
    """Fold `$KIB_PROVIDERS_DIR/*.json` onto the built-in table. Idempotent."""
    d = os.environ.get("KIB_PROVIDERS_DIR")
    if not d or not os.path.isdir(d):
        return
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".json"):
            continue
        try:
            with open(os.path.join(d, fn)) as fh:
                p = json.load(fh)
        except (OSError, ValueError) as e:
            sys.stderr.write(f"kib-broker: skipping bad provider def {fn} ({type(e).__name__})\n")
            continue
        pid = p.get("id") or fn[:-5]
        if pid in PROVIDERS:  # never override a built-in preset
            sys.stderr.write(f"kib-broker: ignoring user def {fn} — '{pid}' is a built-in\n")
            continue
        need = _REQUIRED.get(p.get("delivery"))
        if not need or not all(p.get(k) not in (None, "", []) for k in need):
            sys.stderr.write(f"kib-broker: skipping incomplete provider def {fn}\n")
            continue
        PROVIDERS[pid] = _finalize_provider(pid, p)


def next_free_port() -> int:
    """The next free listen port for a NEW user route.

    At or above 8100, clear of the built-in LLM band (8080–8082), so user MCP routes never
    collide with a built-in. Read after merge_user_providers() so it also counts ports
    already claimed by existing user defs.
    """
    used = [
        v
        for p in PROVIDERS.values()
        for v in (p.get("listen_port"), p.get("mcp_port"))
        if isinstance(v, int)
    ]
    return max(used + [8099]) + 1


def provider_id_of(provider: dict[str, Any]) -> str:
    """Reverse-lookup an id from a row object (the proxy holds the row, not the id)."""
    for pid, p in PROVIDERS.items():
        if p is provider:
            return pid
    return "?"


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
