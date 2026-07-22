#!/usr/bin/env bash
set -euo pipefail

# Host-side launcher. Brings up this project's container (or attaches to the running
# one) and runs the session inside it via `docker exec`. The subsystems it drives —
# image build/update, .ccignore redaction, gitignore/pre-commit sync — live in cc-lib.sh.

# ── Guard: forbid launching from sensitive host directories ──
# Exactly $HOME, ~/Desktop, ~/Documents, ~/Downloads; subdirectories are fine. Runs
# before any trap or `tput reset`, so the error stays on screen after exit.
_pwd="$(realpath "$PWD" 2>/dev/null || echo "$PWD")"
_home="$(realpath "$HOME" 2>/dev/null || echo "$HOME")"
_blocked=""
if [ "$_pwd" = "$_home" ]; then
    _blocked="\$HOME"
else
    for _dir in Desktop Documents Downloads; do
        [ "$_pwd" = "$_home/$_dir" ] && { _blocked="~/$_dir"; break; }
    done
fi
if [ -n "$_blocked" ]; then
    echo "" >&2
    echo "❌ cc refuses to launch from $_blocked ($PWD)." >&2
    echo "   These directories are on the permanent forbidden list:" >&2
    echo "     \$HOME, ~/Desktop, ~/Documents, ~/Downloads" >&2
    echo "   (subdirectories are allowed — cd into one and retry.)" >&2
    echo "" >&2
    exit 1
fi
unset _pwd _home _blocked _dir

IMAGE_NAME="claude-code-sandbox"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=cc-lib.sh
. "$SCRIPT_DIR/cc-lib.sh" || {
    echo "❌ cc: cannot load $SCRIPT_DIR/cc-lib.sh — the install is incomplete." >&2
    exit 1
}

build_image_if_missing
check_for_updates

# ── Identity: ONE container per project ──────────────────────
# Claude supports several concurrent sessions in one config dir (a [concurrentSessions]
# pid registry; the daemon arbitrates via daemon.lock). Both mechanisms assume the
# sessions share a PID namespace and a /tmp — true for two terminals on the host, false
# for two containers. So cc keeps one *long-lived* container per project and attaches
# every terminal to it with `docker exec`; Claude then sees what it sees on the host and
# its own arbitration does the work.
#
# The name must therefore be stable per project. Hash $PWD so two projects with the same
# basename don't collide.
PROJ_HASH="$(printf '%s' "$PWD" | sha256sum | cut -c1-8)"
CNAME="cc-$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-40)-$PROJ_HASH"

# ── Per-project Claude session isolation ─────────────────────
# CLAUDE_CONFIG_DIR gets a per-project dir (daemon, sessions, jobs, history, transcripts,
# .claude.json); CLAUDE_SECURESTORAGE_CONFIG_DIR keeps pointing at one shared dir, so
# every project still shares a single login token. Mounting one ~/.claude into every
# container instead made concurrent sessions fight over daemon.lock — and let every
# container read every other project's transcripts.
CLAUDE_SHARED="$HOME/.claude-shared"
CLAUDE_SANDBOX="$HOME/.claude-sandbox"
SLUG="$(printf '%s' "$PWD" | sed 's/[^a-zA-Z0-9]/-/g')"
SESSION_DIR="$CLAUDE_SANDBOX/$SLUG"
EPHEMERAL=0

# The locks arbitrating the container's lifetime live OUTSIDE $SESSION_DIR, because that
# dir is bind-mounted rw into the container: a sandboxed Claude could delete the lock
# file from inside, and unlinking a lock whose inode another cc holds flocked lets the
# next one lock a *fresh* inode — two "last terminals out", both tearing down the
# container under a live session. Keep them host-only.
LOCK_DIR="$CLAUDE_SANDBOX/.locks"
LOCK_FILE="$LOCK_DIR/$SLUG.lock"
BOOT_LOCK="$LOCK_DIR/$SLUG.boot.lock"

# Suffix for this session's scratch dirs. Empty for the project's shared container; set
# for an ephemeral one so it can never touch the real one's (see CC_FORCE_NEW_SESSION).
SCRATCH_SUFFIX=""

if [ ! -f "$CLAUDE_SHARED/.migrated" ]; then
    die "per-project session isolation isn't set up yet." \
        "Run the one-time migration (it splits ~/.claude into a shared dir" \
        "and one dir per project):" \
        "  $SCRIPT_DIR/migrate-sessions.sh            # dry run — shows every change" \
        "  $SCRIPT_DIR/migrate-sessions.sh --apply    # commit"
fi

mkdir -p "$LOCK_DIR" && chmod 700 "$LOCK_DIR"

# A legacy ~/.claude means the migration was undone, or a host `claude` recreated one.
# It is no longer mounted, so it can't leak — but it will silently diverge, so say so.
if [ -d "$HOME/.claude/projects" ] || [ -f "$HOME/.claude/.credentials.json" ]; then
    warn "a legacy ~/.claude exists but is NOT used by the sandbox any more." \
         "Remove it so it can't drift: rm -rf ~/.claude ~/.claude.json"
fi

sync_shared_claude_md

if [ "${CC_FORCE_NEW_SESSION:-0}" = "1" ]; then
    # Clean slate: its own container AND its own config dir, so it has its own daemon and
    # cannot collide with the project's real one. Throwaway — discarded on exit. Not
    # needed just to open a second terminal (that attaches to the shared container).
    SESSION_DIR="$CLAUDE_SANDBOX/$SLUG.ephemeral.$$"
    CNAME="$CNAME-eph-$$"
    EPHEMERAL=1
    # Its own scratch dirs too. Sharing the project's would mean this session's startup
    # ("clear anything a crashed session left behind") and its exit both tear down the
    # real container's live FUSE mount, unmasking .ccignore'd files under a live session.
    SCRATCH_SUFFIX=".eph.$$"
    mkdir -p "$SESSION_DIR" && chmod 700 "$SESSION_DIR"
    cp "$CLAUDE_SHARED/claude-json.seed" "$SESSION_DIR/.claude.json" 2>/dev/null || true
    # Reap it even if we bail out below (e.g. the sidecar fails): the real cleanup() trap
    # isn't installed until just before the container starts.
    trap 'rm -rf "$SESSION_DIR"' EXIT
    echo "⚠️  CC_FORCE_NEW_SESSION=1 — ephemeral session; no history, discarded on exit." >&2
else
    if [ ! -d "$SESSION_DIR" ]; then
        mkdir -p "$SESSION_DIR" && chmod 700 "$SESSION_DIR"
        cp "$CLAUDE_SHARED/claude-json.seed" "$SESSION_DIR/.claude.json" 2>/dev/null || true
        echo "🆕 cc: first run here — new session dir $SESSION_DIR" >&2
    fi
    # SHARED lock, held for this terminal's lifetime: a reference count on the project's
    # container, not a mutex — any number of terminals hold it at once. It blocks only
    # while a departing session holds the lock *exclusively* to tear the container down,
    # so we can never attach to a dying container. Never unlinked (see build.lock).
    exec 200>"$LOCK_FILE"
    flock -w 60 -s 200 || die "timed out waiting for the project lock ($LOCK_FILE)."
fi

sync_ccignore_gitignore

# ── Container lifecycle ──────────────────────────────────────
# The container outlives any single terminal, so everything it depends on (the sidecar,
# its scratch dirs) must be addressable by *any* cc process, not just its creator —
# hence paths derived from the project hash rather than mktemp.
FUSE_CNAME="${CNAME}-fuse"
FUSE_ROOT="/tmp/cc-fuse.${PROJ_HASH}${SCRATCH_SUFFIX}"
FUSE_FAILED=0
PROJECT_MOUNT_SRC="$PWD"
PROJECT_MOUNT_OPTS=""

container_running() { [ -n "$(docker ps -q -f "name=^${CNAME}$" 2>/dev/null)" ]; }
sidecar_running()   { [ -n "$(docker ps -q -f "name=^${FUSE_CNAME}$" 2>/dev/null)" ]; }

# `docker run -d` returns as soon as PID 1 exists, but the entrypoint still has real work
# to do as root — useradd, the shared-asset symlink farm, chown of the session dir —
# before it execs `gosu … sleep infinity`. An immediate `docker exec` would land mid-setup:
# no home dir yet, no symlinks, a chown walking the tree under us.
#
# Readiness is therefore a process whose command line is *exactly* `sleep infinity`, which
# only exists once the entrypoint has exec'd. The exactness is load-bearing: while the
# entrypoint is still working its own argv is `/bin/sh …/docker-entrypoint.sh sleep
# infinity`, and PID 1 (docker-init) carries `… -- …docker-entrypoint.sh sleep infinity`
# forever — a substring match would call a half-set-up container ready.
container_ready() {
    local args
    args="$(docker top "$CNAME" -o args 2>/dev/null)" \
        || args="$(docker top "$CNAME" 2>/dev/null |
                   awk 'NR>1 { $1=$2=$3=$4=$5=$6=$7=""; sub(/^ +/,""); print }')"
    printf '%s\n' "$args" | grep -qx 'sleep infinity'
}

wait_for_container_ready() {
    local _
    for _ in $(seq 1 120); do                       # ≤60s; a cold entrypoint is ~1s
        container_ready && return 0
        if ! container_running; then
            echo "❌ cc: the project container exited during startup. Logs:" >&2
            docker logs "$CNAME" 2>&1 | tail -20 | sed 's/^/   /' >&2 || true
            teardown_container
            exit 1
        fi
        sleep 0.5
    done
    # Leave nothing half-started behind: a running-but-never-ready container would make
    # every later cc attach to it and hit this same timeout.
    echo "❌ cc: the project container never finished starting up (60s)." >&2
    docker logs "$CNAME" 2>&1 | tail -20 | sed 's/^/   /' >&2 || true
    teardown_container
    exit 1
}

teardown_container() {
    docker stop -t 5 "$CNAME" >/dev/null 2>&1 || true   # started with --rm; stop removes it

    # Unmount BEFORE removing the sidecar. The other order kills the FUSE server first,
    # leaving a mounted-but-ENOTCONN mount that `mountpoint -q` reports as "not a
    # mountpoint" — so the unmount is skipped, the mount is orphaned on *every* exit, and
    # the next launch of this project dies on the rm below.
    if ! unmount_fuse "$FUSE_ROOT/mnt"; then
        die "a .ccignore redaction mount is still mounted at" \
            "  $FUSE_ROOT/mnt" \
            "and could not be unmounted. Refusing to delete it: that path is a" \
            "passthrough view of your project, so removing it while mounted would" \
            "delete the real files. Clear it by hand, then relaunch:" \
            "  fusermount3 -u '$FUSE_ROOT/mnt' || sudo umount -l '$FUSE_ROOT/mnt'"
    fi
    docker rm -f "$FUSE_CNAME" >/dev/null 2>&1 || true

    # The resolv.conf watcher is an in-container process (a detached `docker exec`), so it is
    # killed when the container is removed — nothing to tear down here.

    # `|| true`: never let a failed cleanup kill cc under `set -e` — least of all from the
    # EXIT trap, where it would also overwrite the session's exit code.
    rm -rf "$FUSE_ROOT" 2>/dev/null || true
}

start_container() {
    start_fuse_sidecar

    # --init: PID 1 is `sleep infinity`, which would never reap the zombies left behind by
    # exec'd sessions. Docker's init does.
    ARGS=(
        -d --init --rm
        --name "$CNAME"

        # Project at the same absolute path as on the host, so Claude's path-keyed project
        # configs resolve. With FUSE active the source is the redacting mount instead, and
        # rslave propagates its sub-mounts into the container.
        -v "$PROJECT_MOUNT_SRC:$PWD$PROJECT_MOUNT_OPTS"

        # This project's private state: daemon, sessions, jobs, transcripts, history,
        # .claude.json. No other project's container mounts it.
        -v "$SESSION_DIR:/home/hostuser/.claude-session"

        # Shared by every project: login token, settings, plugins, skills, CLAUDE.md.
        # Writable — an OAuth refresh has to rewrite .credentials.json.
        -v "$CLAUDE_SHARED:/home/hostuser/.claude-shared"

        # The split that makes the above work: config (and .claude.json) resolve to the
        # per-project dir, credentials to the shared one.
        -e CLAUDE_CONFIG_DIR=/home/hostuser/.claude-session
        -e CLAUDE_SECURESTORAGE_CONFIG_DIR=/home/hostuser/.claude-shared

        # Host UID/GID/HOME for runtime user creation. `docker exec` inherits these from
        # the container config, so attached sessions get them too.
        -e HOST_UID="$(id -u)"
        -e HOST_GID="$(id -g)"
        -e HOST_HOME="$HOME"
        -e HOST_PWD="$PWD"

        # Drop everything; add back only what the entrypoint needs for user setup + gosu.
        --cap-drop=ALL
        --cap-add=SETUID
        --cap-add=SETGID
        --cap-add=CHOWN
        --cap-add=DAC_OVERRIDE
        --cap-add=FOWNER

        # The image still ships setuid binaries (su, mount, passwd, fusermount3), and the
        # entrypoint drops to the host uid via gosu. no-new-privileges makes a setuid exec
        # unable to regain privileges afterwards. Defence in depth: the session's caps are
        # already empty, so this closes the escalation route rather than a live hole.
        --security-opt no-new-privileges

        # Bridge network + Claude's own domain allowlist. --add-host so a dev server on
        # the host stays reachable.
        --add-host=host.docker.internal:host-gateway

        -e DISABLE_TELEMETRY=1
        -e DISABLE_ERROR_REPORTING=1

        # Wayland socket, for image pasting from the host clipboard.
        -e XDG_RUNTIME_DIR="/run/user/$(id -u)"
        -e WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
        -v "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY:-wayland-0}:/run/user/$(id -u)/${WAYLAND_DISPLAY:-wayland-0}"
    )

    # Follow the host's live DNS: mount systemd-resolved's live resolv.conf dir + the watcher
    # (see add_resolv_sync_args in cc-lib.sh). No-op if the host has no systemd-resolved, in
    # which case the container keeps Docker's default resolv.conf (frozen), as before.
    add_resolv_sync_args

    local git_name git_email
    git_name="$(git config --global user.name 2>/dev/null || true)"
    git_email="$(git config --global user.email 2>/dev/null || true)"
    if [ -n "$git_name" ]; then
        ARGS+=(
            -e GIT_AUTHOR_NAME="$git_name"
            -e GIT_COMMITTER_NAME="$git_name"
            -e GIT_AUTHOR_EMAIL="$git_email"
            -e GIT_COMMITTER_EMAIL="$git_email"
        )
    fi

    # Read-only: both are executed on the *host* later, so a container that could write
    # them would have host code execution (git hooks at the next commit; Claude hooks in
    # a future session). The .git/hooks mount is belt-and-braces only — it covers just
    # this repo's top-level .git, and only if it exists at launch. The FUSE guard is what
    # actually covers nested repos, submodules, and repos created mid-session.
    [ -d "$PWD/.git/hooks" ] && ARGS+=(-v "$PWD/.git/hooks:$PWD/.git/hooks:ro")
    [ -d "$CLAUDE_SHARED/hooks" ] && ARGS+=(-v "$CLAUDE_SHARED/hooks:/home/hostuser/.claude-shared/hooks:ro")

    # The container just idles; the real work runs in `docker exec` sessions, so it
    # survives any one terminal closing.
    docker run "${ARGS[@]}" "$IMAGE_NAME" sleep infinity >/dev/null \
        || die "failed to start the project container."
}

# ── Bring the container up, or attach to the running one ─────
# The boot lock serialises this section: two terminals launched at the same instant must
# not both try to `docker run` the same container name.
exec 201>"$BOOT_LOCK"
flock -x 201
if container_running; then
    # Redaction is fixed at container creation: the sidecar reads the rules once. A second
    # terminal must never silently run under stale — or absent — rules. The sidecar is now
    # unconditional, so its absence is always an error, whether or not .ccignore exists:
    # without it there is no host-config guard either.
    if ! sidecar_running; then
        die "this project's container was started without the redaction sidecar, so" \
            "neither .ccignore nor the host-config guard is being enforced in it." \
            "Refusing to attach — close all cc sessions for this project and relaunch." \
            "(A container created by an older cc will always land here.)"
    fi
    # Only the project's .ccignore can go stale; global.ccignore is mounted read-only
    # from $SCRIPT_DIR, so the sidecar and this process read the very same file.
    if ! cmp -s "${PWD}/.ccignore" "$FUSE_ROOT/patterns" 2>/dev/null \
       && ! { [ ! -f "$PWD/.ccignore" ] && [ ! -s "$FUSE_ROOT/patterns" ]; }; then
        die ".ccignore changed since this project's container started." \
            "The running redaction layer still enforces the OLD rules. Refusing to" \
            "attach — close all cc sessions for this project and relaunch."
    fi
    wait_for_container_ready   # in case its creator died mid-startup
    echo "🔗 cc: attaching to this project's running container ($CNAME)." >&2
else
    teardown_container    # clear anything a crashed session left behind
    start_container
    wait_for_container_ready
    start_resolv_sync     # one watcher for the container's lifetime; see cc-lib.sh
fi
flock -u 201
exec 201>&-

# ── Sleep guard (inhibits sleep while Claude is producing output) ──
# The container is shared by every terminal on the project, so the guard must be told
# which processes are *ours*: we stamp this terminal's session with a unique marker in
# its environment (below), and the guard samples only pids carrying it. Without this,
# one working session makes every terminal's guard inhibit.
SESSION_TAG="cc-$$-$(date +%s)"

# 200>&- / 201>&-: it must not inherit our lock fds. A guard outliving cc would keep
# holding the project's shared lock and stop the container from ever being torn down.
"$SCRIPT_DIR/sleep-guard.sh" "$CNAME" "$SESSION_TAG" 200>&- 201>&- &
SLEEP_GUARD_PID=$!

cleanup() {
    kill "$SLEEP_GUARD_PID" 2>/dev/null || true

    if [ "$EPHEMERAL" = 1 ]; then
        teardown_container
        [ -n "$SESSION_DIR" ] && rm -rf "$SESSION_DIR"
    else
        # Are we the last terminal out? Drop our shared lock, then try to take the lock
        # exclusively — which can only succeed if no other cc still holds it. While we
        # hold it, a starting cc blocks on its `flock -s`, so it cannot attach to a
        # container we are about to stop.
        exec 200>&-
        exec 202>"$LOCK_FILE"
        if flock -n -x 202; then
            teardown_container
            flock -u 202
        fi
        exec 202>&-
    fi

    # `|| true`: tput exits 10 when stdout isn't a tty, and the EXIT trap's last status
    # becomes the shell's — that would mask the session's real exit code.
    if [ "$FUSE_FAILED" != 1 ]; then
        tput reset 2>/dev/null || true
    fi
}
trap cleanup EXIT
# Closing the terminal window sends SIGHUP; `kill` sends SIGTERM. Bash treats both as
# fatal and dies *without* running the EXIT trap — orphaning the sleep-guard (still
# holding a sleep inhibitor) and, if this was the last terminal, stranding the container
# for good. Exit through the normal path instead, so cleanup runs.
trap 'exit 129' HUP
trap 'exit 143' TERM

# ── Run this terminal's session inside the project container ──
# Re-entering through the entrypoint (rather than calling claude directly) reuses its
# "already the target user" branch, which sets HOME and PATH correctly.
if [ $# -eq 0 ]; then
    CMD=(claude --dangerously-skip-permissions)
elif [[ "$1" == -* ]]; then
    CMD=(claude --dangerously-skip-permissions "$@")
else
    CMD=("$@")
fi

# Clean screen for Claude's TUI. `|| true` because tput exits 10 with no tty — under
# `set -e` that would kill a redirected run (`cc claude -p '…' > out.txt`) before the
# session ever started.
tput reset 2>/dev/null || true

# CC_SESSION_TAG marks every process in this terminal's session: claude, its tools and
# its subagents all inherit it across fork/exec, so the sleep guard can scope its /proc
# sample to this session alone. It is set on the *exec*, not the container, so it is
# per-terminal and works against a container created before this existed.
docker exec -it \
    --user "$(id -u):$(id -g)" \
    --workdir "$PWD" \
    -e COLUMNS="$(tput cols 2>/dev/null || echo 120)" \
    -e LINES="$(tput lines 2>/dev/null || echo 40)" \
    -e TERM="${TERM:-xterm-256color}" \
    -e CC_SESSION_TAG="$SESSION_TAG" \
    "$CNAME" /usr/local/bin/docker-entrypoint.sh "${CMD[@]}"
