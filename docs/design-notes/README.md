# Design notes

The architecture, rationale, and dead ends behind **Keep It in Your Box**. `CLAUDE.md` (repo root)
holds the terse rules and points into these files by name — read the relevant one **before
changing a subsystem**; most "obvious simplifications" here are documented dead ends that cost real
debugging time.

| File | Covers |
|---|---|
| [architecture.md](architecture.md) | Component/file map, build & run, aliases |
| [container-lifecycle.md](container-lifecycle.md) | Per-project config dirs, one-container-per-project, locks |
| [redaction-config-guard.md](redaction-config-guard.md) | `.ccignore` FUSE + pre-commit, host-executed config guard, shared config surface |
| [credential-broker.md](credential-broker.md) | `cc-broker.py`, providers, delivery modes, MCP interception |
| [clipboard-and-dns.md](clipboard-and-dns.md) | Wayland clipboard proxy, live-DNS sync |
| [sleep-guard.md](sleep-guard.md) | Per-session sleep inhibition, proactive suspend |
| [macos.md](macos.md) | Plan H: single-container redaction, portability contract, pbpaste bridge |
| [terminal-and-security.md](terminal-and-security.md) | `tput`/left-arrow/daemon.log quirks, security posture, accepted risks |
