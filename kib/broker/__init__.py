"""The credential broker. Spans the trust boundary, so every module names its side.

The agent container never holds a real credential: it gets a base-URL env var pointing here,
a structurally-valid PLACEHOLDER token, and a synthetic credential file shadowing the real
one. The broker terminates the agent's plain HTTP, strips the placeholder, injects the REAL
credential and re-originates TLS to one hardcoded upstream per route — so there is no MITM
and no CA in the agent's trust store. A compromised agent can *use* the upstream but never
read the token.

── THE SECRET IS STATIC. THE BROKER NEVER WRITES IT. ─────────────────────────
Read this before adding a refresh loop back. An earlier version brokered the live
`.credentials.json` on a 30s timer and logged the account out, hard: Anthropic subscription
refresh tokens are SINGLE-USE and ROTATE, so the first refresher invalidates the family for
every other holder; a single-file bind mount cannot temp+rename (EBUSY), so the write
truncated in place; and `threading.Lock` serialises one process, while there is one broker
container per project. A known upstream failure mode (anthropics/claude-code #56339, #54443,
#60503), not something code can work around. So: one long-lived static token, mounted
READ-ONLY, no refresh loop, no expiry tracking, no write path to any credential.
`kib broker login` mints it. (docs/design-notes/credential-broker.md)

Layout:
    credential.py  guest — the read-only token view and placeholder minting
    registry.py    both  — the provider/route table and user-defined provider merging
    proxy.py       guest — the reverse proxy and its serve loop
    helpers.py     host  — secret detection and provider synthesis, used by kib.host.mcp
    cli.py         both  — serve / host-config / list-providers / probe / …
"""
