"""The credential broker. Spans the trust boundary, so every module names its side.

The agent container never holds a real credential: it gets a base-URL env var pointing here,
a structurally-valid PLACEHOLDER token, and a synthetic credential file shadowing the real
one. The broker terminates the agent's plain HTTP, strips the placeholder, injects the REAL
credential and re-originates TLS to one hardcoded upstream per route — so there is no MITM
and no CA in the agent's trust store. A compromised agent can *use* the upstream but never
read the token.

── THE SECRET IS STATIC. THE BROKER NEVER WRITES IT. ─────────────────────────
One long-lived static token from `kib broker login`, mounted READ-ONLY: no refresh loop, no
expiry tracking, no write path to any credential, and never `.credentials.json`. Anthropic
subscription refresh tokens are SINGLE-USE and ROTATE, so any refresher here invalidates the
token family for the host CLI and every other holder — a permanent logout, upstream and not
fixable in code. (docs/design-notes/credential-broker.md)

Layout:
    credential.py  guest — the read-only token view and placeholder minting
    registry.py    both  — the provider/route table and user-defined provider merging
    proxy.py       guest — the reverse proxy and its serve loop
    helpers.py     host  — secret detection and provider synthesis, used by kib.host.mcp
    cli.py         both  — serve / host-config / list-providers / probe / …
"""
