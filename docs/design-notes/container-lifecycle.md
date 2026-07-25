# Container lifecycle

Part of the Keep It in Your Box design notes (`docs/design-notes/`). See `CLAUDE.md` for the rules
that reference this.

## Session isolation — canonical `~/.claude`, assembled per launch

Claude Code runs a background-agent daemon arbitrated by `daemon.lock` in its config dir. One shared `~/.claude` across containers broke two ways: separate PID namespaces made the lock's pid/procStart liveness fields meaningless, so daemons displaced each other in a loop; and every container could read every project's transcripts.

An earlier fix split `~/.claude` destructively into a shared dir + a per-project one. That cost the thing a solo user cares about most: afterwards there is no `~/.claude`, so a plain host `claude` has no login and no `--resume` continuity. **Now** `~/.claude` and `~/.claude.json` stay **canonical and stock-untouched**, and per-project isolation comes from *assembling* each container's config from them per launch. Same two path resolvers in the binary, but pointed at per-launch scratch under `$CC_STATE_ROOT` (`${XDG_STATE_HOME:-~/.local/state}/keep-it-in-your-box`):

| Env var | Resolves | `cc` points it at |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | everything (daemon, sessions, projects, `.claude.json`, history, CLAUDE.md) | `$CC_STATE_ROOT/<slug>/session` (assembled) |
| `CLAUDE_SECURESTORAGE_CONFIG_DIR` | `.credentials.json` + shared assets | `$CC_STATE_ROOT/<slug>/shared` (assembled) |

`<slug>` = `$PWD` with non-alphanumerics → `-` (Claude's own scheme). **Assembly (`assemble_session_dir`, cold-start only — never while a container is attached to these bind-mounted files):**

- **`.claude.json`** — `claude-config-scope.py scope-in-json` writes globals + only *this* project's `projects[path]` entry. On exit, `merge-out-json` writes only that subtree back to canonical (globals/other projects byte-untouched; fail-closed on parse error).
- **`history.jsonl`** — `seed-history` filters to this project's lines in; `merge-history` appends new lines back out (append-only, so a concurrent host `claude` append can't be lost).
- **`CLAUDE.md`** — `assemble_sandbox_claude_md` writes `policy block + the user's canonical ~/.claude/CLAUDE.md` straight into the session dir. Canonical stays pure user memory (a host `claude` never sees the policy). *Not* farmed by the entrypoint any more.
- **`projects/<slug>`** — a nested rw bind of `~/.claude/projects/<slug>`, so transcripts + `--resume` are shared host⇄box.
- **Shared assets** — `settings.json`/`keybindings.json` are **copied** into the shared-assembly dir, never bound from canonical (`stage_shared_settings`), and folded back on exit only after the copy passes `_settings_bad_keys` (`merge_out_shared_settings`); `plugins/ skills/ agents/ commands/ hooks/` nest-bound **ro** (the cross-project / host-exec guard — `--unlock-shared` makes them rw so an install lands in canonical for every project + the host claude). A lock-witness file bound ro **only when locked** lets `running_unlocked` read the lock state off the mounts even for a user with no assets to probe.
- **Everything else** (daemon, sessions, file-history, caches, and *anything cc doesn't recognise* — `classify`'s drift canary logs it) stays container-private in the session base. **Fail-closed:** an unknown store can't leak and can't touch canonical.

**`$HOST_HOME/.claude` → the session dir (entrypoint).** Claude's plugin state stores *absolute host* paths — `installed_plugins.json`'s `installPath`, `known_marketplaces.json`'s `installLocation`, both `/home/<you>/.claude/plugins/…` — and both files are farmed from the **read-only** shared mount, so Claude cannot rewrite them to container paths. The pre-existing whole-home symlink doesn't help: it is guarded on `[ ! -e "$HOST_HOME" ]`, and the project bind mount *creates* `$HOST_HOME` (`/home/kay` for `/home/kay/myrepo`), so it never fires in practice. Result without the link: every host-installed plugin dangles — `enabledPlugins: true` in `settings.json`, marketplace cloned and present, yet nothing in `/mcp`, because the plugin's recorded path doesn't exist. The marketplace layer *self-heals* (its JSON is a real writable file, so Claude re-clones) which makes the failure look partial and confusing; the plugin-cache layer cannot. One symlink makes all of it resolve back through the farmed tree. Skipped when `$HOST_HOME` is itself our symlink — there `/.claude` would be the stock config dir Claude looks for by default.

Merge-out runs on the **last terminal out**, after the container is stopped (files quiescent), under a `flock` on `~/.claude.json.lock`. `ensure_claude_home` skeletons a missing `~/.claude` so the binds don't fail on a fresh install.

## One container per project

Two terminals on the **same** project must work. Claude's own `[concurrentSessions]` registry and daemon arbitration assume all sessions share a PID namespace and `/tmp` — true on the host, false across containers (each reads the other's pid against its own `/proc`, concludes it's dead, displaces it forever; the daemon's `/tmp/cc-daemon-<uid>/` socket is container-local too). So:

- **One long-lived container per project** (`cc-<basename>-<hash>`), PID 1 = `sleep infinity` under `--init`. Every terminal attaches via `docker exec`, re-entering the entrypoint. Claude sees one PID namespace, one `/tmp`, one daemon, N sessions — its own arbitration handles the rest.
- **Readiness = a process whose argv is *exactly* `sleep infinity`** — only exists after the entrypoint `exec`s. Exactness is load-bearing: mid-setup argv is `/bin/sh …/docker-entrypoint.sh sleep infinity` and PID 1 carries the string forever, so a substring match calls a half-set-up container ready.
- **Lifecycle refcounted with `flock`** on `$CC_STATE_ROOT/.locks/<slug>.lock`: each terminal holds a **shared** lock (fd 200); `<slug>.boot.lock` (fd 201, exclusive) serialises check-and-create; on exit each tries the lock exclusively — only the last one out succeeds and tears down (then merges out, under fd 203). Locks live outside the container-mounted session dir on purpose (a sandboxed Claude could delete them from inside).
- **Lock files are never unlinked** — tested in place with `flock -n`. Deleting a lock file whose inode another process holds lets the next process lock a fresh inode: two "exclusive" holders.
- **Every backgrounded host process must close fds 200/201** (`200>&- 201>&-`). A child inheriting fd 200 that outlives its `cc` keeps the shared lock held; last-one-out can never lock exclusively, teardown never runs, containers strand. Shipped once without it (the Wayland notifier): stranded every closed project's containers, and the symptom looks nothing like a locking bug. `docker exec -d` children are exempt.
- `cc` traps **SIGHUP and SIGTERM** and exits through the normal path — bash treats both as fatal *without* running the EXIT trap, so closing a terminal window would otherwise skip teardown.
- `CC_FORCE_NEW_SESSION=1` = clean slate: own container, own ephemeral config dirs under `$CC_STATE_ROOT/<slug>.ephemeral.<pid>/` (own daemon, **merge-out disabled** — discarded on exit), own `/tmp/cc-{fuse,mask}.<hash>.eph.<pid>` scratch dirs — sharing the project's would tear down the real container's live FUSE mount on its startup-clean and its exit.
- **Unmount the FUSE view before killing the sidecar.** Killing the server first leaves the mount returning `ENOTCONN`, so `mountpoint -q` says "not a mountpoint" for a directory that still is one — the unmount is skipped and orphaned every exit. `cc` reads `/proc/self/mounts` directly (`fuse_mounted()`), never `mountpoint(1)`, and **refuses to `rm -rf` a still-mounted path** (the view is a passthrough — deleting it deletes the real files through it).
- **Stale-rules refusal:** redaction is fixed at container creation, so `cc` refuses to attach if `.ccignore` changed since the container started, or if the running container has no sidecar. Same pattern for the `--unlock-shared` mode mismatch.
