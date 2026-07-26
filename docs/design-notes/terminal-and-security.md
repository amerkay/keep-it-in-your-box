# Terminal & UI quirks, and security posture

Part of the Keep It in Your Box design notes (`docs/design-notes/`). See `CLAUDE.md` for the rules
that reference this.

## Terminal & UI quirks

- **No `tput reset`** — removed on purpose (wiped short-command output and scrollback, fought Claude's TUI); regression-guarded in `check.sh`. Surviving `tput cols`/`lines` need `|| true` (tput exits 10 with no tty under `set -e`); `read` likewise.
- **`leftArrowOpensAgents: false` — do not re-enable, and do not re-investigate the ←-key data loss; the sandbox is exonerated.** It's a *global-config* key (`.claude.json`, not `settings.json` — there it's silently inert); `.claude.json` is per-project here, so `pin_global_config` re-asserts it every launch (a seed file only lands on first run; the pin writes only when missing/wrong because a live session rewrites the file wholesale). From a *foreground* session `←` means "background this session": with a turn in flight the binary checkpoints, aborts the in-flight Workflow's and every subagent's AbortController, and respawns via `--resume --fork-session`. Workflows run in-process in a Node `vm`, so nothing survives; the carry-over gate is a tree-wide AND on `isBackgrounded`, and `Task` subagents are built `isBackgrounded:false` — a workflow with live agents is structurally non-carryable. Each press also mints a duplicate ~250-byte session in `--resume` — one per press, not corruption. Do **not** reach for `CLAUDE_CODE_DISABLE_AGENT_VIEW=1` (its reject path is `process.exit(1)`; costs every background session). The view stays reachable: `claude agents`, `/background`, `--bg`. A lost run resumes with `Workflow({scriptPath, resumeFromRunId})`.
- **Expected `daemon.log` noise — benign, do not investigate again:** `bg adopt: adopted=0 respawned=0 dead=N` (previous supervisor's workers; new PID namespace, all rostered pids really are dead; runs once at start, on no live code path); `idle 5s with no clients — exiting` (timer only arms at zero leases *and* zero handles — can't fire under running work); `bg settled … (killed)` naming a `(spare)` (spare-pool churn).

## Security posture

Hardened against escape: seccomp, `--cap-drop=ALL` (SETUID/SETGID/CHOWN/DAC_OVERRIDE/FOWNER added back for the entrypoint; `SYS_ADMIN`+`SETPCAP` too, dropped from the bounding set before the agent runs), `no-new-privileges`, PID isolation, no Docker socket, no host block devices, no writable `/proc/sys`. AppArmor is `unconfined` — the in-container FUSE mount requires it, and the emptied bounding set is what confines the agent instead. Read-only binds for host-executable paths (the canonical `~/.claude` assets `plugins/ skills/ agents/ commands/ hooks/`; `.git/hooks` is the FUSE guard's, since a bind there would shadow the view) — not sufficient alone; see [redaction-config-guard.md](redaction-config-guard.md#host-executed-config-guard) and `validate_shared_settings`. Cross-project isolation: `~/.claude` stays canonical and is never mounted whole; a container gets only *this* project's assembled slice (its `projects/<slug>` transcripts, filtered `history.jsonl`, and a `.claude.json` scoped to globals + this project's entry incl. `mcpServers`; `githubRepoPaths` scoped) — merged back out on exit.

**Accepted risks:** open egress + the shared OAuth token (audit H3/H4) — the token can't be made unreadable (Claude needs it) and a default-deny allowlist conflicts with building untrusted repos; **rotate the token if an untrusted session has run** (the [broker](credential-broker.md), when on, removes the token from the sandbox entirely). Wayland socket mounted but proxied. `host.docker.internal` routable. Project dir writable by design. DNS sync mounts `/run/systemd/resolve` `:ro` with Varlink sockets shadowed by `/dev/null`. **`chrome-devtools-mcp`'s browser runs with Chrome's own inner sandbox off** — see below.

## Chrome: why `--no-sandbox`, and why only for that one MCP

Chrome's Linux sandbox needs an unprivileged user namespace; under `--cap-drop=ALL` + the default
seccomp profile `unshare -U` returns EPERM, so an unwrapped launch dies (`Target.setDiscoverTargets:
Target closed`). Restoring it would mean loosening the container's seccomp to permit namespace
creation — which hands *the agent* a userns primitive, strictly worse for this box's threat model.
So the inner sandbox is traded away; Docker stays the boundary.

**Keep the scope narrow.** The fix is an `npx` shim written by `guest/entrypoint/docker-entrypoint.sh` that adds the
flags only when `chrome-devtools-mcp` is the package being run, so the plugin's stock, unmodified
manifest (`{"command":"npx","args":["chrome-devtools-mcp@…"]}`) works with no per-project MCP
config. It appends nothing the caller already passed, so `--headless=false` / a custom
`--executable-path` still win. **Do not "generalise" this into `--no-sandbox` wrapper scripts over
`google-chrome`/`google-chrome-stable` in the Dockerfile** — that was tried, is redundant with the
shim (verified: the shim alone makes the stock plugin launch a page), needs a full image rebuild,
and silently disarms every *other* Chrome caller too. `/dev/shm` is 64 MB here, but
chrome-devtools-mcp's vendored puppeteer already passes `--disable-dev-shm-usage`.
