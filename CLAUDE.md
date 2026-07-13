# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Docker-based sandbox for running Claude Code in an isolated container. The `cc` script builds and runs a Docker container that mirrors the host user's UID/GID, mounts the current project directory, and forwards Claude's auth/config.

## Working on this repo (read first)

Claude works on `claude-docker` **from inside the sandbox this repo builds**. So:

- **No `docker` binary, no Docker socket.** You cannot build the image, run `cc`, or test a container end to end. Hand those commands to the user — `! <cmd>` runs one host-side from their prompt.
- **`~/.claude-shared/` and `$CLAUDE_CONFIG_DIR` are LIVE host state**, bind-mounted in. Never aim destructive or migration logic at them to "try it". Build a fake `$HOME` under the scratchpad and test against that: `migrate-sessions.sh` keys everything off `$HOME`, and `CC_MIGRATE_TEST=1` disables its safety checks for exactly this purpose.
- **Edits to `cc` / `cc-lib.sh` / `docker-entrypoint.sh` take effect on the user's *next* launch**, never this session. `bash -n` every script you touch before finishing — a syntax error leaves the user unable to start the sandbox at all.

## Architecture

- **`cc`** — Host-side launcher. Owns the launch flow: the sensitive-dir guard, project identity, the lifecycle locks, container create/attach/teardown, and the `docker exec` that runs the session. Run from any project directory; args pass through as the command.
- **`cc-lib.sh`** — Sourced by `cc`, not standalone. The self-contained subsystems: image build + update check, the shared-CLAUDE.md sync, the `.ccignore` → `.gitignore` + pre-commit sync, and both `.ccignore` redaction backends. Shares `cc`'s shell, so it also shares its `set -euo pipefail` and globals.
- **`build-bg.sh`** — Background image rebuild. `flock` on `build.lock` prevents concurrent builds; runs under `setsid` so `kill -TERM -PGID` cancels the whole tree. Desktop notification on completion.
- **`Dockerfile`** — Debian bookworm, Node.js 20, Python 3, dev tools, Claude Code via the official installer. `CUSTOM_PACKAGES` adds apt packages; `CACHE_BUST` forces a reinstall. Installed version is recorded in `/etc/claude-code-version`.
- **`docker-entrypoint.sh`** — Creates a user matching the host UID/GID, fixes ownership of the mounted config dirs, builds the shared-asset symlink farm (below), sets up Wayland clipboard access, then `exec gosu` to drop privileges. Re-entered by every `docker exec` session, which takes its "already the target user" branch.
- **`migrate-sessions.sh`** — One-time host script splitting a legacy `~/.claude` into `~/.claude-shared/` + `~/.claude-sandbox/<slug>/`, then deleting `~/.claude` and `~/.claude.json`. Dry-run by default; `--apply` commits; `--force` redoes it. On `--apply` it refuses to run while any `cc-*` container or host `claude` process is alive, since a torn copy would be deleted out from under it.
- **`shared-CLAUDE.md`** — Sandbox policy (secrets hard-stop, `.ccignore`, sandbox limits) injected into every session. `cc` syncs it into a marker-delimited block at the top of `~/.claude-shared/CLAUDE.md`; anything the user writes below the block survives.
- **`ccignore-fuse.py`** — FUSE redacting passthrough, run in a sidecar container (`--cap-add=SYS_ADMIN --device /dev/fuse`, as the host uid) that mounts a redacted view of the project at `/tmp/cc-fuse.*/mnt`; the main container mounts *that* at `$PWD` with `:rslave`. Matched paths read as a stub and refuse writes (EACCES) — including files created **after** launch, which the bind-mount fallback cannot cover. Matching is gitignore-consistent, honouring `!` negations (last match wins). Needs `/tmp` to be a shared mount; if it isn't, `cc` falls back to launch-time masking. If the sidecar fails to *mount*, `cc` aborts rather than silently downgrading to the leaky fallback.
- **`ccignore-precommit.py`** — Host-side git `pre-commit` hook, installed/refreshed into `$PWD/.git/hooks/pre-commit` (a pre-existing non-managed hook is left alone; detected via its `MARKER: ccignore-precommit` line). Aborts any commit whose staged paths match `.ccignore`, keeping sensitive files out of history and diffs on the host. Catches already-tracked files, which `.gitignore` cannot. Bypassable with `--no-verify`.
- **`.ccignore` → `.gitignore` sync** — Mirrors `.ccignore` into a managed block in `.gitignore` (bare names → match-anywhere, `/`-rules → root-anchored; unsafe leading-`/` and `..` rules skipped). Idempotent; preserves the rest of the file. Blocks untracked sensitive files from being staged; the pre-commit hook is the backstop. Skipped with a note when `cc` is launched from a subdir of the repo.
- **`sleep-guard.sh`** — Host-side daemon started by `cc`. Every 3s it sums `wchar` (bytes written) across `/proc/<pid>/io` for every process in the container, inhibiting sleep (`systemd-inhibit`) while that total grows and releasing after 30s of quiet. It **cannot** use `docker logs`: PID 1 is `sleep infinity` and each session runs under `docker exec`, whose output goes to that terminal's TTY, never the container log stream. The sampling `docker exec` runs as the *host uid* deliberately — `/proc/<pid>/io` is gated by `ptrace_may_access`, which root-without-`CAP_SYS_PTRACE` fails against a uid-1000 process, while a same-uid reader passes. Tunables: `SLEEP_GUARD_GRACE`, `SLEEP_GUARD_MIN_BYTES` (per-poll bytes counting as "active", filtering ~24B idle TUI repaints), `SLEEP_GUARD_DEBUG=1`.
- Uses Docker's default seccomp profile and AppArmor confinement (no custom overrides).

## Session isolation (per-project config dirs)

Claude Code runs a **background-agent daemon** — a singleton arbitrated by `daemon.lock` in its config dir, owning background sessions, background subagents, workflows and the `claude agents` view. `cc` used to bind-mount one host `~/.claude` read-write into *every* container, which broke two ways:

1. Two concurrent `cc` sessions fought over one `daemon.lock`. Containers have separate PID namespaces, so the lock's `pid`/`procStart` liveness fields are meaningless across them — each daemon read the other's pid against its own `/proc` and displaced it, in a loop (`daemon.log`: `lockfile now held by pid=… — displaced, yielding`).
2. Every container could read every other project's transcripts, prompt history and paste cache.

The fix uses the two independent path resolvers in the Claude binary:

| Env var | Resolves | `cc` points it at |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | everything: `daemon.lock`, `daemon/`, `sessions/`, `jobs/`, `projects/`, `file-history/`, `history.jsonl`, `.claude.json`, `settings.json`, `plugins/` | `~/.claude-sandbox/<slug>/` (this project only) |
| `CLAUDE_SECURESTORAGE_CONFIG_DIR` | **only** `.credentials.json` | `~/.claude-shared/` (all projects) |

So state is private per project while one login token serves every session. `<slug>` is `$PWD` with non-alphanumerics → `-`, the same scheme Claude uses for `~/.claude/projects/`.

Assets that *should* be shared (`settings.json`, `keybindings.json`, `CLAUDE.md`, `plugins/`, `skills/`, `agents/`, `commands/`, `hooks/`) live in `~/.claude-shared/` and are **symlinked** into `$CLAUDE_CONFIG_DIR` by `docker-entrypoint.sh` on every launch, since Claude only looks for them under the config dir. Claude rewrites `settings.json` atomically (temp file + rename), replacing the symlink with a real file — the entrypoint folds that edit back into the shared copy before relinking, so an in-session settings change isn't lost.

`~/.claude` and `~/.claude.json` no longer exist after migration; `cc` refuses to launch until `~/.claude-shared/.migrated` is present.

## One container per project (same-project concurrency)

Per-project config dirs fix *cross*-project collisions. They do nothing for two terminals on the **same** project — and that has to work.

Claude already supports it: the binary has a `[concurrentSessions]` pid registry, and the daemon arbitrates via `daemon.lock`, storing `pid` + `procStart` read from `/proc/<pid>/stat`. Both mechanisms assume all sessions **share a PID namespace and a `/tmp`** — true for two terminals on the host, false for two containers. Two containers can therefore *never* share a config dir: each reads the other's pid against its own `/proc`, concludes the daemon is dead, and displaces it — forever. The daemon's control socket (`/tmp/cc-daemon-<uid>/`) is container-local too, so adoption can't work either.

So `cc` stops handing Claude an environment it can't cope with. Instead of one container per terminal:

- **One long-lived container per project**, named `cc-<basename>-<hash of $PWD>`, started detached with `sleep infinity` as PID 1 (`--init`, so exec'd sessions' zombies get reaped).
- **Every terminal attaches with `docker exec`**, re-entering `docker-entrypoint.sh` and inheriting `CLAUDE_CONFIG_DIR` etc. from the container's env.
- Claude therefore sees exactly what it sees on the host: one PID namespace, one `/tmp`, one config dir, one daemon, N sessions. Its own arbitration does the rest — shared `/resume`, prompt history and background jobs across terminals, for free.

**Startup is not instant.** `docker run -d` returns as soon as PID 1 exists, but the entrypoint still has to `useradd`, build the symlink farm and chown the session dir. `cc` therefore waits for the container to be *ready*, and readiness means **a process whose command line is exactly `sleep infinity`** — which only exists once the entrypoint has `exec`'d. The exactness is load-bearing: while the entrypoint is still working its argv is `/bin/sh …/docker-entrypoint.sh sleep infinity`, and PID 1 (`docker-init`) carries `… -- …docker-entrypoint.sh sleep infinity` forever, so a substring match would call a half-set-up container ready.

**Container lifecycle** is reference-counted with `flock` on `~/.claude-sandbox/.locks/<slug>.lock`:

- each terminal takes a **shared** lock (fd 200) for its lifetime — a refcount, not a mutex;
- a `<slug>.boot.lock` **exclusive** lock serialises the check-and-create, so two terminals started at the same instant don't both `docker run` the same name;
- on exit a terminal drops its shared lock and tries to take the lock **exclusively**, which can only succeed if nobody else holds it — so exactly one terminal (the last one out) stops the container. While it holds that lock a starting `cc` blocks on its `flock -s`, so nobody can attach to a container being torn down.
- The locks live in `~/.claude-sandbox/.locks/`, **not** in `$SESSION_DIR` — that dir is bind-mounted rw into the container, so a sandboxed Claude could delete the lock file and break the never-unlink invariant (below) from the inside.
- `cc` traps **SIGHUP and SIGTERM** and exits through the normal path. Bash treats both as fatal and dies *without* running the `EXIT` trap — so closing the terminal window would otherwise skip the last-one-out teardown, stranding the container and orphaning a `sleep-guard.sh` that still holds a sleep inhibitor.

`CC_FORCE_NEW_SESSION=1` is no longer needed for a second terminal. It now means "clean slate": its own container *and* its own ephemeral config dir (hence its own daemon — no collision), discarded on exit. It also gets its **own** `/tmp/cc-{fuse,mask}.<hash>.eph.<pid>` scratch dirs: sharing the project's would mean its startup ("clear anything a crashed session left behind") and its exit both tear down the *real* container's live FUSE mount, unmasking `.ccignore`'d files under a running session.

**Unmount the FUSE view before killing the sidecar.** Killing the server first leaves the mount in the kernel's mount table with every `stat()` on it returning `ENOTCONN` — so `mountpoint -q` reports "not a mountpoint" for a directory that still is one, the unmount is skipped, and the mount is orphaned on *every* exit. The next launch of that project then dies trying to `rm -rf` a live mountpoint. `cc` therefore reads `/proc/self/mounts` directly (`fuse_mounted()`), never `mountpoint(1)`, and unmounts before `docker rm`. It also **refuses to `rm -rf` a path that is still mounted**: `$FUSE_ROOT/mnt` is a passthrough view of the project, so deleting it while mounted would delete the real files through it.

**`.ccignore` caveat:** redaction is fixed at container creation — the sidecar reads the rules once, and the fallback bind-mount masks are baked into `docker run`. Since the container outlives a single terminal, `cc` **refuses to attach** if `.ccignore` changed since it started, or if it exists but the running container has no sidecar; attaching under stale rules would be a leak. Close all of the project's sessions and relaunch to apply a change. Where `/tmp` isn't a shared mount there is no sidecar at all, only launch-time masking, which can't be re-evaluated for a second terminal — `cc` allows one session at a time there, and says so.

## Key Design Decisions

- Project is mounted at the **same absolute path** as on the host, so Claude's path-keyed project configs resolve correctly.
- Claude's config is split: per-project `~/.claude-sandbox/<slug>/` + shared `~/.claude-shared/` (see above).
- All capabilities dropped (`--cap-drop=ALL`); default CMD is `claude --dangerously-skip-permissions`.
- **Auto-update check**: each launch compares the installed version (`/etc/claude-code-version`, falling back to `claude --version`) against the latest release, and offers a background rebuild while you keep using the current image.
- **Lock files are never unlinked.** `build.lock` and `~/.claude-sandbox/.locks/*` are tested in place with `flock -n`. Deleting a lock file whose inode another process holds `flock`ed lets the next process create a *fresh* inode and lock that instead — two "exclusive" holders at once. This is also why the lifecycle locks are kept out of the container-mounted session dir.
- **`tput` is guarded with `|| true`.** It exits 10 when stdout isn't a tty, and `cc` runs under `set -e` — unguarded, a redirected run (`cc claude -p '…' > out.txt`) dies before the session starts, and the copy in the `EXIT` trap overwrites the session's real exit code. `read` is guarded for the same reason.

## Security Posture

**Hardened against container escape:** seccomp (mode 2), AppArmor (`docker-default` enforce), `--cap-drop=ALL` (only SETUID/SETGID/CHOWN/DAC_OVERRIDE/FOWNER added back for the entrypoint), PID namespace isolation, no Docker socket, no host block devices, no writable `/proc/sys`.

**Read-only mounts for host-executable paths** — both would be host code execution if writable:
- `.git/hooks` — would run on the host at the next `git commit`
- `~/.claude-shared/hooks` — would run on the host in a future Claude session

**Cross-project isolation:** a container mounts only its own `~/.claude-sandbox/<slug>/`, so it cannot read another project's transcripts, prompt history, jobs or pasted content. `.claude.json` is pruned per project (globals + that project's entry, including its `mcpServers`); `githubRepoPaths` is scoped so other projects' paths don't leak either.

**Accepted risks (required for the workflow):**
- `~/.claude-shared` writable + network egress = the shared OAuth token is theoretically exfiltrable
- Wayland socket mounted = container can read/write the host clipboard
- `host.docker.internal` routable to the host network stack
- Project directory writable (by design)

## Build & Run

```bash
# One-time migration to per-project sessions (required before cc will launch)
./migrate-sessions.sh          # dry run — prints every copy/write/delete
./migrate-sessions.sh --apply  # commit; deletes ~/.claude and ~/.claude.json

# Build image (happens automatically on first run)
docker build -t claude-code-sandbox .

# Run from any project directory
/path/to/cc                    # default: launches claude
/path/to/cc bash               # override CMD to get a shell
/path/to/cc claude --resume    # pass args through
CC_FORCE_NEW_SESSION=1 /path/to/cc   # clean-slate throwaway session

# Rebuild with custom packages
docker build --build-arg CUSTOM_PACKAGES="golang ruby" -t claude-code-sandbox .

# Force reinstall a specific Claude Code version (Docker caches by version)
docker build --build-arg CLAUDE_VERSION=2.1.71 -t claude-code-sandbox .
```
