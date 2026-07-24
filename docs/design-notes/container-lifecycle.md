# Container lifecycle

Part of the Keep It in Your Box design notes (`docs/design-notes/`). See `CLAUDE.md` for the rules
that reference this.

## Session isolation (per-project config dirs)

Claude Code runs a background-agent daemon arbitrated by `daemon.lock` in its config dir. One shared `~/.claude` across containers broke two ways: separate PID namespaces made the lock's pid/procStart liveness fields meaningless, so daemons displaced each other in a loop; and every container could read every project's transcripts.

Fix — the two independent path resolvers in the binary:

| Env var | Resolves | `cc` points it at |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | everything (daemon, sessions, projects, `.claude.json`, settings, plugins) | `~/.claude-sandbox/<slug>/` (per-project) |
| `CLAUDE_SECURESTORAGE_CONFIG_DIR` | only `.credentials.json` | `~/.claude-shared/` (all projects) |

`<slug>` = `$PWD` with non-alphanumerics → `-` (Claude's own scheme). Shareable assets (`settings.json`, `CLAUDE.md`, `plugins/`, `skills/`, `agents/`, `commands/`, `hooks/`, `keybindings.json`) live in `~/.claude-shared/` and are **symlinked** into `$CLAUDE_CONFIG_DIR` by the entrypoint. Claude rewrites `settings.json` atomically (temp+rename replaces the symlink with a real file) — the entrypoint folds that edit back into the shared copy before relinking. `~/.claude`/`~/.claude.json` no longer exist; `cc` refuses to launch without `~/.claude-shared/.migrated`.

## One container per project

Two terminals on the **same** project must work. Claude's own `[concurrentSessions]` registry and daemon arbitration assume all sessions share a PID namespace and `/tmp` — true on the host, false across containers (each reads the other's pid against its own `/proc`, concludes it's dead, displaces it forever; the daemon's `/tmp/cc-daemon-<uid>/` socket is container-local too). So:

- **One long-lived container per project** (`cc-<basename>-<hash>`), PID 1 = `sleep infinity` under `--init`. Every terminal attaches via `docker exec`, re-entering the entrypoint. Claude sees one PID namespace, one `/tmp`, one daemon, N sessions — its own arbitration handles the rest.
- **Readiness = a process whose argv is *exactly* `sleep infinity`** — only exists after the entrypoint `exec`s. Exactness is load-bearing: mid-setup argv is `/bin/sh …/docker-entrypoint.sh sleep infinity` and PID 1 carries the string forever, so a substring match calls a half-set-up container ready.
- **Lifecycle refcounted with `flock`** on `~/.claude-sandbox/.locks/<slug>.lock`: each terminal holds a **shared** lock (fd 200); `<slug>.boot.lock` (fd 201, exclusive) serialises check-and-create; on exit each tries the lock exclusively — only the last one out succeeds and tears down. Locks live outside the container-mounted session dir on purpose (a sandboxed Claude could delete them from inside).
- **Lock files are never unlinked** — tested in place with `flock -n`. Deleting a lock file whose inode another process holds lets the next process lock a fresh inode: two "exclusive" holders.
- **Every backgrounded host process must close fds 200/201** (`200>&- 201>&-`). A child inheriting fd 200 that outlives its `cc` keeps the shared lock held; last-one-out can never lock exclusively, teardown never runs, containers strand. Shipped once without it (the Wayland notifier): stranded every closed project's containers, and the symptom looks nothing like a locking bug. `docker exec -d` children are exempt.
- `cc` traps **SIGHUP and SIGTERM** and exits through the normal path — bash treats both as fatal *without* running the EXIT trap, so closing a terminal window would otherwise skip teardown.
- `CC_FORCE_NEW_SESSION=1` = clean slate: own container, own ephemeral config dir (own daemon), own `/tmp/cc-{fuse,mask}.<hash>.eph.<pid>` scratch dirs — sharing the project's would tear down the real container's live FUSE mount on its startup-clean and its exit.
- **Unmount the FUSE view before killing the sidecar.** Killing the server first leaves the mount returning `ENOTCONN`, so `mountpoint -q` says "not a mountpoint" for a directory that still is one — the unmount is skipped and orphaned every exit. `cc` reads `/proc/self/mounts` directly (`fuse_mounted()`), never `mountpoint(1)`, and **refuses to `rm -rf` a still-mounted path** (the view is a passthrough — deleting it deletes the real files through it).
- **Stale-rules refusal:** redaction is fixed at container creation, so `cc` refuses to attach if `.ccignore` changed since the container started, or if the running container has no sidecar. Same pattern for the `--unlock-shared` mode mismatch.
