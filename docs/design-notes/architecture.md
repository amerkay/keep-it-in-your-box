# Architecture and file map

Part of the Keep It in Your Box design notes (`docs/design-notes/`). See `CLAUDE.md` for the rules
that reference this.

## The tree IS the trust boundary

A file's directory says which side of the boundary it is on, which is the point of the layout:

| Dir | Runs where | Rule |
|---|---|---|
| `bin/kib` | host | verb dispatch and the sensitive-dir guard, nothing else |
| `host/` | host, as you | one file per subsystem; each header names the globals it reads/writes |
| `guest/` | inside a container | baked entrypoints, 3-line shims, policy files — assume hostile input |
| `kib/` | both | the one importable package: `shared/` · `host/` · `guest/` · `broker/` |
| `tools/`, `tests/`, `docs/`, `examples/` | host | build, suites, notes, worked provider examples |

`kib/shared/` may not import `kib.host` or `kib.guest`: it is the layer both sides share, and that
back-edge would drag host-only code into the container. Bash reaches Python exactly one way —
`kib_py <module> <args…>` — with parameters in **argv**, never in the environment.

## Component and file map

- **`bin/kib`** — Host-side launcher, ~200 lines: peel the `claude` alias token, the sensitive-dir guard, verb dispatch, and the hand-off. **Verbs win over programs** — `kib bash` is an error, `kib exec bash` is the pass-through.
- **`host/_load.sh`** — The one loader, in a fixed order: `core.sh` first (it defines `die`/`warn`), then `portable.sh` (all OS branching), then the subsystems — `image`, `config`, `redaction`, `gitguard`, `broker`, `mcp`, `desktop`, `net`, `lifecycle`.
- **`host/core.sh`** — `die`/`warn`/`notify`, the `$KIB_STATE_ROOT` paths, `kib_py`, and the single `wait_until` the four hand-rolled poll loops collapsed into.
- **`host/portable.sh`** — The **only** file allowed OS branching. Sourced by `bin/kib`, `tools/build-image.sh`, `host/sleep-guard.sh`. Provides `lock_fd`, `hash8`, `detach_pgrp`, `notify_desktop`, `preflight_platform`, `read_kib_config`, and sets `KIB_OS`/`is_macos`.
- **`kib/shared/`** — Imported by both sides: `rules.py` (the ONE `.kibignore` parser, matcher and gitignore emitter), `dangerous.py` (the ONE git-INI and settings-JSON key table), `jsonio.py`, `cli.py` (the exit-code convention), `log.py`.
- **`kib/host/`** — `config_scope.py`, `settings_scan.py`, `pins.py`, `gitaudit.py`, `mcp.py`.
- **`kib/broker/`** — Credential broker: `registry` (the provider table) · `proxy` (guest) · `credential` (guest) · `helpers` (host) · `cli`. See [credential-broker.md](credential-broker.md).
- **`guest/bin/resolv-sync.sh`** — POSIX-sh DNS watcher inside the main container. See [clipboard-and-dns.md](clipboard-and-dns.md#dns-sync).
- **`kib/guest/wayland_guard.py`** — Filtering Wayland proxy sidecar. See [clipboard-and-dns.md](clipboard-and-dns.md#clipboard).
- **`kib/guest/fuse.py`** — FUSE redacting passthrough, mounted in-container. See [redaction-config-guard.md](redaction-config-guard.md#redaction-kibignore-fuse-the-audit-gate).
- **`host/gitguard.sh` + `kib/host/gitaudit.py`** — The host-side audit gate, run at cold start (refuses), at teardown (reports + alerts) and via `kib audit`. It replaced a hook kib used to write into every project's `.git/hooks`. See [redaction-config-guard.md](redaction-config-guard.md#redaction-kibignore-fuse-the-audit-gate).
- **`guest/bin/{fuse,wayland-guard,broker}`** — Three-line baked shims. Each puts `/usr/local/lib` on `sys.path` for that exec only and runs a module out of the bind-mounted `kib/` package — so a sidecar edit needs a relaunch, not a rebuild, while `PYTHONPATH` never becomes an image-wide ENV that would leak into every process the agent runs.
- **`guest/policy/global.kibignore`** — Host-executed-config guard rules, shipped in-repo, mounted `:ro` into the container for the FUSE server. See [redaction-config-guard.md](redaction-config-guard.md#host-executed-config-guard).
- **`host/sleep-guard.sh`** — Host-side per-terminal sleep-inhibit daemon. See [sleep-guard.md](sleep-guard.md).
- **`guest/entrypoint/docker-entrypoint.sh`** — **Baked into the image (`COPY`)** — editing it needs a rebuild, not a relaunch. Creates a user matching host UID/GID, fixes ownership, builds the shared-asset symlink farm (CLAUDE.md excluded — kib assembles it directly), sets up clipboard access, `exec gosu` drops privileges. Re-entered by every `docker exec` session (takes its "already the target user" branch).
- **`guest/entrypoint/entrypoint-fuse.sh`** — Baked; mounts the redacted view in-container and drops `SYS_ADMIN`. See [redaction-config-guard.md](redaction-config-guard.md#redaction-kibignore-fuse-the-audit-gate).
- **`kib/host/config_scope.py`** — Host-side JSON/JSONL surgery for the canonical-`~/.claude` seam: `scope-in-json`/`merge-out-json` (this project's `.claude.json` subtree), `seed-history`/`merge-history`, `classify` (drift canary manifest). Unit-tested by `tests/host/test_config_scope.py`. See [container-lifecycle.md](container-lifecycle.md#session-isolation--canonical-claude-assembled-per-launch).
- **`guest/policy/shared-CLAUDE.md`** — Sandbox policy, assembled by kib into a marker-delimited block atop the in-box `CLAUDE.md` (= policy + the user's canonical `~/.claude/CLAUDE.md`). Loads in-box only; canonical stays pure user memory.
- **`tools/build-image.sh`** — Background image rebuild; `flock` on `build.lock`, runs under `setsid` so `kill -TERM -PGID` cancels the tree; desktop notification on completion. Run by hand it streams BuildKit's progress UI and exits non-zero on failure; kib's launch path passes **`--background`** (and redirects to `/dev/null`) to get the quiet, `build.log`-only behaviour. That flag is load-bearing, not decoration: `setsid` drops the controlling terminal but leaves fd 1 pointing at the user's terminal, so a plain `[ -t 1 ]` test reads as interactive and the build draws its progress UI over the running Claude session while `build.log` stays empty. Regression-guarded in `tests/check/regressions.sh`.
- **`Dockerfile`** — Debian trixie, Node (NodeSource, `NODE_MAJOR` arg), Python 3, Claude Code via official installer (`CLAUDE_VERSION` arg; installed version recorded in `/etc/claude-code-version`). Build args are `NODE_MAJOR` and `CLAUDE_VERSION` only — there is no `CUSTOM_PACKAGES`/`CACHE_BUST` (edit the apt line directly to add packages). SVG→GIF toolchain (`rsvg-convert`, `cairosvg`, Pillow, `ffmpeg` for the GIF assembly): prefer **`rsvg-convert`** (Pango resolves CSS font-family *lists*; cairosvg's toy font API treats the list as one literal name and falls back to proportional sans). Headless Chrome is not a usable rasterizer (hangs on GCM registration retries). `supergateway` pre-installed for hosted MCPs. Default CMD: `claude --dangerously-skip-permissions`.
- **`tests/`** — `lib.sh` (one harness for both bash suites), `check.sh` (a thin runner over `check/*.sh`: syntax · portability · wiring · mcp · regressions · shims · pytest), the pytest suites mirroring `kib/` (`shared/`, `host/`, `guest/`, `broker/`), and `security-test.sh` (run **inside** a sandbox; `--list`, `-k <section>`, `--no-clipboard`). Each security check re-attempts a real attack **and** the legitimate operation the guard must not break. Non-destructive. Fixtures in `tests/.state/sectest/` are reused, not recreated (the guard refuses to unlink a `.git/config`, so fresh-fixtures-per-run would pile up undeletable dirs; clear from the host).
- Docker's default seccomp + AppArmor; no custom overrides.

## Build & run

```bash
# No setup step — kib keeps ~/.claude canonical and assembles each session per launch.
kib build                    # rebuild the image (streams when run by hand)
# Never a bare `docker build`: CLAUDE_VERSION stays the literal string `latest`, Docker keys
# its cache on that string rather than on what it resolves to, so the install layer is reused
# forever — the image keeps an old Claude and kib re-prompts for the same upgrade every launch.
# tools/build-image.sh resolves the number first. To pin one deliberately:
docker build --build-arg CLAUDE_VERSION=2.1.71 -t keep-it-in-your-box .
/path/to/bin/kib                 # launch claude   |  kib exec bash  # shell
KIB_FORCE_NEW_SESSION=1 /path/to/bin/kib                        # clean-slate session
```

**Aliases:** `kib='/path/to/bin/kib'` (the tool: `kib exec <anything>` runs it in the box) and
`cc='/path/to/bin/kib claude'` — which makes "swap `claude`→`cc`" a lossless rule for any
vendor-supplied line (`claude mcp add …`, `claude --resume`), and is what makes the `mcp add`
interception fire on the `cc mcp add …` a user naturally types. Project mounted at the **same absolute path** as on the
host so path-keyed configs resolve. Each launch compares `/etc/claude-code-version` against the
latest release and offers a background rebuild.
