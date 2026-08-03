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
- **`host/_load.sh`** — The one loader, in a fixed order: `core.sh` first (it defines `die`/`warn`), then `portable.sh` (all OS branching), then the subsystems — `image`, `config`, `redaction`, `gitguard`, `broker`, `mcp`, `desktop`, `net`, `node`, `lifecycle`.
- **`host/core.sh`** — `die`/`warn`/`notify`, the `$KIB_STATE_ROOT` paths, `kib_py`, and the single `wait_until` the four hand-rolled poll loops collapsed into.
- **`host/portable.sh`** — The **only** file allowed OS branching. Sourced by `bin/kib`, `tools/build-image.sh`, `host/sleep-guard.sh`. Provides `lock_fd`, `hash8`, `detach_pgrp`, `notify_desktop`, `preflight_platform`, `read_kib_config`, and sets `KIB_OS`/`is_macos`.
- **`kib/shared/`** — Imported by both sides: `rules.py` (the ONE `.kibignore` parser and matcher), `dangerous.py` (the ONE git-INI and settings-JSON key table), `jsonio.py`, `cli.py` (the exit-code convention), `log.py`.
- **`kib/host/`** — `config_scope.py`, `settings_scan.py`, `pins.py`, `gitaudit.py`, `mcp.py`.
- **`kib/broker/`** — Credential broker: `registry` (the provider table) · `proxy` (guest) · `credential` (guest) · `helpers` (host) · `cli`. See [credential-broker.md](credential-broker.md).
- **`guest/bin/resolv-sync.sh`** — POSIX-sh DNS watcher inside the main container. See [clipboard-and-dns.md](clipboard-and-dns.md#dns-sync).
- **`kib/guest/wayland_guard.py`** — Filtering Wayland proxy sidecar. See [clipboard-and-dns.md](clipboard-and-dns.md#clipboard).
- **`kib/guest/fuse.py`** — FUSE redacting passthrough, served by a sidecar container and propagated into the agent's over `$PWD`. See [redaction-config-guard.md](redaction-config-guard.md#redaction-kibignore-fuse-the-audit-gate).
- **`host/gitguard.sh` + `kib/host/gitaudit.py`** — The host-side audit gate, run at cold start (refuses), at teardown (reports + alerts) and via `kib audit`. It replaced a hook kib used to write into every project's `.git/hooks`. See [redaction-config-guard.md](redaction-config-guard.md#redaction-kibignore-fuse-the-audit-gate).
- **`guest/bin/{fuse,wayland-guard,broker}`** — Three-line baked shims. Each puts `/usr/local/lib` on `sys.path` for that exec only and runs a module out of the bind-mounted `kib/` package — so a sidecar edit needs a relaunch, not a rebuild, while `PYTHONPATH` never becomes an image-wide ENV that would leak into every process the agent runs.
- **`guest/policy/global.kibignore`** — Host-executed-config guard rules, shipped in-repo, mounted `:ro` into the container for the FUSE server. See [redaction-config-guard.md](redaction-config-guard.md#host-executed-config-guard).
- **`host/node.sh` + `guest/bin/node-fetch.sh`** — the user-level Node cache behind `kib --node-version=NN[,NN…]`. `ensure_node_cached` fetches each named version once per MACHINE into `$XDG_CACHE_HOME/keep-it-in-your-box/node` and every container mounts it `:ro` at `/opt/nvm-versions`, unconditionally — a bind is a live view, so a version cached later appears in containers that already exist, which is what keeps `--node-version` a per-terminal exec setting with no attach-refusal. Populating runs in a **sterile container** (no project mount, no credentials, no broker network, `--cap-drop ALL`): the last step installs pnpm, i.e. runs registry JS, which kib does not do on the host, and doing the whole job in-container also makes `uname -m` the arch that will really run the binary. The box is never a writer — a shared store it could write is executable content one project hands another. The choice is **sticky per project** — `node_versions_resolve` records `<project path>=<versions>` in `~/.keep-it-in-your-box/node-versions`, beside the host config and deliberately outside anything a container mounts: a box-writable file naming the next session's interpreter would let a session pick its own. The flag always wins and re-pins; `=system` goes back to `NODE_MAJOR`. The download is checked against the release's `SHASUMS256.txt` and renamed in atomically; `include/` (~60 MB of v8/openssl headers — node-gyp fetches its own) and docs are pruned and `bin/node` stripped, taking a line from ~184 MB to ~120 MB.
- **`host/sleep-guard.sh`** — Host-side per-terminal sleep-inhibit daemon. See [sleep-guard.md](sleep-guard.md).
- **`guest/entrypoint/docker-entrypoint.sh`** — **Baked into the image (`COPY`)** — editing it needs a rebuild, not a relaunch. Creates a user matching host UID/GID, fixes ownership, seeds `$HOME/.nvm` from `/opt/nvm` (`ensure_user_nvm`, from both branches — `useradd -m` cannot do it via `/etc/skel` because docker has already created `$HOME` as a mountpoint parent), resolves `$KIB_NODE_VERSION` into `KIB_PREPEND_PATH` (`resolve_node_version`/`apply_node_version`, in the already-the-user branch only: that is where every session lands, and an unresolvable version in the root branch would abort container *creation* rather than one terminal), builds the shared-asset symlink farm (CLAUDE.md excluded — kib assembles it directly), sets up clipboard access, `exec gosu` drops privileges. Re-entered by every `docker exec` session (takes its "already the target user" branch).
- **`kib/host/config_scope.py`** — Host-side JSON/JSONL surgery for the canonical-`~/.claude` seam: `scope-in-json`/`merge-out-json` (this project's `.claude.json` subtree), `seed-history`/`merge-history`, `classify` (drift canary manifest). Unit-tested by `tests/host/test_config_scope.py`. See [container-lifecycle.md](container-lifecycle.md#session-isolation--canonical-claude-assembled-per-launch).
- **`guest/policy/etc-CLAUDE.md`** — Sandbox policy, bound `:ro` over `/etc/claude-code/CLAUDE.md`, Claude's managed-policy path. Loads in every in-box session ahead of user and project memory, cannot be dropped by `claudeMdExcludes`, and is not writable by the session. Bound rather than baked, so an edit lands on the next container, not a rebuild; the image only pre-creates the directory. Loads in-box only — canonical `~/.claude/CLAUDE.md` stays pure user memory.
- **`tools/build-image.sh`** — Background image rebuild; `flock` on `build.lock`, runs under `setsid` so `kill -TERM -PGID` cancels the tree; desktop notification on completion. Run by hand it streams BuildKit's progress UI and exits non-zero on failure; kib's launch path passes **`--background`** (and redirects to `/dev/null`) to get the quiet, `build.log`-only behaviour. That flag is load-bearing, not decoration: `setsid` drops the controlling terminal but leaves fd 1 pointing at the user's terminal, so a plain `[ -t 1 ]` test reads as interactive and the build draws its progress UI over the running Claude session while `build.log` stays empty. Regression-guarded in `tests/check/regressions.sh`.
- **`Dockerfile`** — Debian trixie, Node (NodeSource, `NODE_MAJOR` arg), Python 3, Claude Code via official installer (`CLAUDE_VERSION` arg; installed version recorded in `/etc/claude-code-version`). Build args are `NODE_MAJOR` and `CLAUDE_VERSION` only — there is no `CUSTOM_PACKAGES`/`CACHE_BUST` (edit the apt line directly to add packages). SVG→GIF toolchain (`rsvg-convert`, `cairosvg`, Pillow, `ffmpeg` for the GIF assembly): prefer **`rsvg-convert`** (Pango resolves CSS font-family *lists*; cairosvg's toy font API treats the list as one literal name and falls back to proportional sans). Headless Chrome is not a usable rasterizer (hangs on GCM registration retries). `python3-cryptography` is for the broker's OAuth service-account grant only (`kib/broker/oauth.py`, lazily imported). JS toolchain: `npm`/`yarn`/`pnpm`/`ts-node`/`tsx` global, plus `nvm` (pinned `NVM_VERSION`) — cloned to `/opt/nvm` and sourced from ONE file, `/etc/kib-nvm.sh`, with **three readers**: `/etc/bash.bashrc` (interactive terminals), `ENV BASH_ENV` (a non-interactive `bash -c`), and a `~/.bashrc` the entrypoint seeds. Only the last reaches **Claude's own tool calls**, which replay a snapshot captured from `~/.bashrc` rather than reading any rc file — with no `~/.bashrc` in the image at all (docker's pre-created `$HOME` means `/etc/skel` never runs), the snapshot captured nothing and `nvm` was missing from every tool call while `node`/`npm` worked fine off PATH. `BASH_ENV` alone does not cover it: measured live, it was present in the tool shell's environment and still unprocessed, while an identically-spawned bash honoured it. The init is a **lazy wrapper**, not a full source — `nvm.sh` defines 118 functions and Claude Code serialises every captured function into that snapshot as a base64 `eval` replayed on every Bash call (anthropics/claude-code#31437: ~8 s at 199). `nvm use N` is then per-shell as always; the session-wide lever is `--node-version`, which is sticky per project. A PATH shim farm for this was built and thrown away. **No Node line is baked**: `/opt/nvm-versions` is created empty as the mountpoint for the user-level cache (`host/node.sh`). Baking four LTS lines was tried and removed — it cost ~1.0 GB of image for versions most projects never ask for, and two stores cannot be merged anyway (nvm enumerates with `find … -type d`, which skips symlinks, so only a single parent-directory symlink works). Python side: `uv`/`uvx` from Astral's installer. Default CMD: `claude --dangerously-skip-permissions`.
- **`tests/`** — `lib.sh` (one harness for both bash suites), `check.sh` (a thin runner over `check/*.sh`: syntax · portability · wiring · mcp · clipboard · assets · regressions · shims · pytest), the pytest suites mirroring `kib/` (`shared/`, `host/`, `guest/`, `broker/`), and `security-test.sh` (run **inside** a sandbox; `--list`, `-k <section>`, `--no-clipboard`). Each security check re-attempts a real attack **and** the legitimate operation the guard must not break. Non-destructive. Fixtures in `tests/.state/sectest/` are reused, not recreated (the guard refuses to unlink a `.git/config`, so fresh-fixtures-per-run would pile up undeletable dirs; clear from the host).
- Docker's default seccomp + AppArmor on the agent's container; no custom overrides. Only the FUSE sidecar runs `apparmor=unconfined`, because `docker-default` contains `deny mount,`.

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
