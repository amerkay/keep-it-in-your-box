# Architecture and file map

Part of the Keep It in Your Box design notes (`docs/design-notes/`). See `CLAUDE.md` for the rules
that reference this.

## Component and file map

- **`cc`** — Host-side launcher. Owns the launch flow: sensitive-dir guard, project identity, lifecycle locks, container create/attach/teardown, and the `docker exec` that runs the session. Args pass through as the command.
- **`cc-lib.sh`** — Sourced by `cc`, not standalone (shares its `set -euo pipefail` and globals). Self-contained subsystems: image build + update check, shared-CLAUDE.md sync, `.ccignore` → `.gitignore` + pre-commit sync, both redaction backends, live-DNS sync, and the broker wiring.
- **`cc-portable.sh`** — The **only** file allowed OS branching. Sourced by `cc`, `cc-lib.sh`, `build-bg.sh`, `sleep-guard.sh`. Provides `lock_fd`, `hash8`, `detach_pgrp`, `notify_desktop`, `preflight_platform`, `read_kib_config`, and sets `CC_OS`/`is_macos`/`CC_FUSE_MODE`.
- **`cc-broker.py`** — Host-side credential broker sidecar. See [credential-broker.md](credential-broker.md).
- **`resolv-sync.sh`** — POSIX-sh DNS watcher inside the main container. See [clipboard-and-dns.md](clipboard-and-dns.md#dns-sync).
- **`wayland-guard.py`** — Filtering Wayland proxy sidecar. See [clipboard-and-dns.md](clipboard-and-dns.md#clipboard).
- **`ccignore-fuse.py`** — FUSE redacting passthrough sidecar. See [redaction-config-guard.md](redaction-config-guard.md#redaction-ccignore-fuse-pre-commit).
- **`ccignore-precommit.py`** — Host-side git pre-commit hook. See [redaction-config-guard.md](redaction-config-guard.md#redaction-ccignore-fuse-pre-commit).
- **`global.ccignore`** — Host-executed-config guard rules, shipped in-repo, mounted `:ro` into the sidecar. See [redaction-config-guard.md](redaction-config-guard.md#host-executed-config-guard).
- **`sleep-guard.sh`** — Host-side per-terminal sleep-inhibit daemon. See [sleep-guard.md](sleep-guard.md).
- **`docker-entrypoint.sh`** — **Baked into the image (`COPY`)** — editing it needs a rebuild, not a relaunch. Creates a user matching host UID/GID, fixes ownership, builds the shared-asset symlink farm (CLAUDE.md excluded — cc assembles it directly), sets up clipboard access, `exec gosu` drops privileges. Re-entered by every `docker exec` session (takes its "already the target user" branch).
- **`entrypoint-fuse.sh`** — Baked; single-mode (macOS) in-container FUSE mount. See [macos.md](macos.md).
- **`claude-config-scope.py`** — Host-side JSON/JSONL surgery for the canonical-`~/.claude` seam: `scope-in-json`/`merge-out-json` (this project's `.claude.json` subtree), `seed-history`/`merge-history`, `classify` (drift canary manifest). Unit-tested by `tests/config-scope-test.py`. See [container-lifecycle.md](container-lifecycle.md#session-isolation--canonical-claude-assembled-per-launch).
- **`shared-CLAUDE.md`** — Sandbox policy, assembled by cc into a marker-delimited block atop the in-box `CLAUDE.md` (= policy + the user's canonical `~/.claude/CLAUDE.md`). Loads in-box only; canonical stays pure user memory.
- **`build-bg.sh`** — Background image rebuild; `flock` on `build.lock`, runs under `setsid` so `kill -TERM -PGID` cancels the tree; desktop notification on completion. Run by hand it streams BuildKit's progress UI and exits non-zero on failure; cc's launch path passes **`--background`** (and redirects to `/dev/null`) to get the quiet, `build.log`-only behaviour. That flag is load-bearing, not decoration: `setsid` drops the controlling terminal but leaves fd 1 pointing at the user's terminal, so a plain `[ -t 1 ]` test reads as interactive and the build draws its progress UI over the running Claude session while `build.log` stays empty. Regression-guarded in `check.sh`.
- **`Dockerfile`** — Debian trixie, Node (NodeSource, `NODE_MAJOR` arg), Python 3, Claude Code via official installer (`CLAUDE_VERSION` arg; installed version recorded in `/etc/claude-code-version`). Build args are `NODE_MAJOR` and `CLAUDE_VERSION` only — there is no `CUSTOM_PACKAGES`/`CACHE_BUST` (edit the apt line directly to add packages). SVG→GIF toolchain (`rsvg-convert`, `cairosvg`, Pillow, `ffmpeg` for the GIF assembly): prefer **`rsvg-convert`** (Pango resolves CSS font-family *lists*; cairosvg's toy font API treats the list as one literal name and falls back to proportional sans). Headless Chrome is not a usable rasterizer (hangs on GCM registration retries). `supergateway` pre-installed for hosted MCPs. Default CMD: `claude --dangerously-skip-permissions`.
- **`tests/`** — `check.sh` (host-side dev suite; `cd`s to repo root, run as `./tests/check.sh`), `broker-test.py` (pure-stdlib broker logic; also invoked by check.sh), `security-test.sh` (run **inside** a sandbox; `--list`, `-k <section>`, `--no-clipboard`). Each security check re-attempts a real attack **and** the legitimate operation the guard must not break. Non-destructive. Fixtures in `tests/.sectest/` are reused, not recreated (the guard refuses to unlink a `.git/config`, so fresh-fixtures-per-run would pile up undeletable dirs; clear from the host).
- Docker's default seccomp + AppArmor; no custom overrides.

## Build & run

```bash
# No setup step — cc keeps ~/.claude canonical and assembles each session per launch.
./build-bg.sh                    # rebuild the image (streams when run by hand)
# Never a bare `docker build`: CLAUDE_VERSION stays the literal string `latest`, Docker keys
# its cache on that string rather than on what it resolves to, so the install layer is reused
# forever — the image keeps an old Claude and cc re-prompts for the same upgrade every launch.
# build-bg.sh resolves the number first. To pin one deliberately:
docker build --build-arg CLAUDE_VERSION=2.1.71 -t keep-it-in-your-box .
/path/to/cc                      # launch claude   |  /path/to/cc bash  # shell
CC_FORCE_NEW_SESSION=1 /path/to/cc                             # clean-slate session
```

**Aliases:** `kib='/path/to/cc'` (bare launcher: `kib <anything>` runs it in the box) and
`cc='/path/to/cc claude'` — which makes "swap `claude`→`cc`" a lossless rule for any vendor-supplied
line (`claude mcp add …`, `claude --resume`), and is what makes the `mcp add` interception fire on
the `cc mcp add …` a user naturally types. Project mounted at the **same absolute path** as on the
host so path-keyed configs resolve. Each launch compares `/etc/claude-code-version` against the
latest release and offers a background rebuild.
