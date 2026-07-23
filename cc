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

# ── cc's own flags ───────────────────────────────────────────
# Consumed here so they never reach claude. --unlock-shared drops the read-only mounts over
# ~/.claude-shared, which is how you deliberately install a skill/plugin for EVERY project
# rather than just this one (see "Shared config surface" in CLAUDE.md).
UNLOCK_SHARED="${CC_UNLOCK_SHARED:-0}"
if [ "${1:-}" = "--unlock-shared" ]; then
    UNLOCK_SHARED=1
    shift
fi

# cc-portable.sh first: it owns all OS branching (CC_OS, the lock/hash/notify
# shims, preflight) and cc-lib.sh's helpers build on it. shellcheck source=cc-portable.sh
. "$SCRIPT_DIR/cc-portable.sh" || {
    echo "❌ cc: cannot load $SCRIPT_DIR/cc-portable.sh — the install is incomplete." >&2
    exit 1
}
# shellcheck source=cc-lib.sh
. "$SCRIPT_DIR/cc-lib.sh" || {
    echo "❌ cc: cannot load $SCRIPT_DIR/cc-lib.sh — the install is incomplete." >&2
    exit 1
}

preflight_platform          # darwin: engine/perl/bind-mount checks; linux: no-op
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
PROJ_HASH="$(hash8 "$PWD")"
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

# Host-only state for the single-container FUSE mode and the macOS clipboard
# bridge. Kept OUT of $SESSION_DIR (which is bind-mounted rw into the container)
# for the same reason as the locks: a sandboxed Claude must not be able to edit
# the patterns the redaction layer is validated against, nor the bridge's spool.
# The per-container file paths are derived below, next to FUSE_ROOT, so they pick
# up SCRATCH_SUFFIX (an ephemeral session must not share the real one's state).
STATE_DIR="$CLAUDE_SANDBOX/.state"

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
validate_shared_settings

if [ "$UNLOCK_SHARED" = 1 ]; then
    echo "⚠️  --unlock-shared: ~/.claude-shared is WRITABLE this session. Anything written" >&2
    echo "   there auto-runs in EVERY project's next session." >&2
else
    echo "🔒 shared config: read-only (installs land per-project; cc --unlock-shared to share)" >&2
fi

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
    lock_fd -w 60 -s 200 || die "timed out waiting for the project lock ($LOCK_FILE)."
fi

# Every launch, not just the first: the seed covers only a brand-new session dir.
pin_global_config "$SESSION_DIR/.claude.json"

sync_ccignore_gitignore

# ── Container lifecycle ──────────────────────────────────────
# The container outlives any single terminal, so everything it depends on (the sidecar,
# its scratch dirs) must be addressable by *any* cc process, not just its creator —
# hence paths derived from the project hash rather than mktemp.
FUSE_CNAME="${CNAME}-fuse"
FUSE_ROOT="/tmp/cc-fuse.${PROJ_HASH}${SCRATCH_SUFFIX}"
WL_CNAME="${CNAME}-wl"
WL_ROOT="/tmp/cc-wl.${PROJ_HASH}${SCRATCH_SUFFIX}"
# Single-container FUSE + clipboard bridge state (see STATE_DIR above). SCRATCH_SUFFIX is
# final by here, so an ephemeral session gets its own files and can't disturb the real one.
PATTERNS_STATE="$STATE_DIR/${SLUG}${SCRATCH_SUFFIX}.patterns"
CLIP_STATE="$STATE_DIR/${SLUG}${SCRATCH_SUFFIX}.clip"
FUSE_FAILED=0
# The redaction interface (see cc-lib.sh) fills these: sidecar mode sets a mount
# SRC/OPTS for $PWD; single mode leaves SRC empty (the entrypoint mounts the view
# in-container) and appends its own `docker run` flags to REDACTION_ARGS.
PROJECT_MOUNT_SRC="$PWD"
PROJECT_MOUNT_OPTS=""
REDACTION_ARGS=()

container_running() { [ -n "$(docker ps -q -f "name=^${CNAME}$" 2>/dev/null)" ]; }
sidecar_running()   { [ -n "$(docker ps -q -f "name=^${FUSE_CNAME}$" 2>/dev/null)" ]; }

# Was the running container created with --unlock-shared? Read it off the mounts, which are
# the ground truth — no state file to go stale. CLAUDE.md is the probe because it is the one
# entry guaranteed to exist (sync_shared_claude_md writes it every launch); skills/ or
# plugins/ may legitimately be absent, which would read as "unlocked".
running_unlocked() {
    ! docker inspect -f '{{range .Mounts}}{{.Destination}}{{"\n"}}{{end}}' "$CNAME" 2>/dev/null |
        grep -qx '/home/hostuser/.claude-shared/CLAUDE.md'
}

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

    # Redaction teardown is mode-specific (sidecar: unmount + rm the FUSE container +
    # rm its scratch root, in that order; single: the mount died with the container,
    # so just drop the host state file). See teardown_redaction in cc-lib.sh.
    teardown_redaction

    # Clipboard mediation + its host-side notification follower. Plain dirs, so none of
    # the unmount care in the sidecar teardown applies. Both are no-ops in the mode that
    # didn't start them.
    stop_wayland_guard
    stop_clipboard_bridge

    # The resolv.conf watcher is an in-container process (a detached `docker exec`), so it is
    # killed when the container is removed — nothing to tear down here.
}

start_container() {
    # Redaction: sidecar (Linux) sets PROJECT_MOUNT_SRC to the redacting mount for
    # $PWD; single (macOS / CC_SINGLE_CONTAINER=1) leaves it empty and pushes its own
    # flags onto REDACTION_ARGS — the entrypoint mounts the view in-container.
    prepare_redaction
    # Clipboard: a mediated Wayland proxy on Linux, a pbpaste bridge on macOS. Both
    # must precede the mounts below (they bind the proxy socket / spool dir).
    if is_macos; then
        start_clipboard_bridge
    else
        start_wayland_guard
    fi

    # --init: PID 1 is `sleep infinity`, which would never reap the zombies left behind by
    # exec'd sessions. Docker's init does.
    ARGS=(
        -d --init --rm
        --name "$CNAME"

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

    )

    # Project at the same absolute path as on the host, so Claude's path-keyed project
    # configs resolve. Sidecar mode points $PWD at the redacting mount (rslave propagates
    # its sub-mounts in); single mode adds NO bind for $PWD — the in-container entrypoint
    # mounts the redacted view there itself — and supplies its own flags via REDACTION_ARGS.
    if [ -n "$PROJECT_MOUNT_SRC" ]; then
        ARGS+=(-v "$PROJECT_MOUNT_SRC:$PWD$PROJECT_MOUNT_OPTS")
    fi
    # `if`, not `[ … ] && ARGS+=`: the codebase's convention for array appends under set -e.
    if [ "${#REDACTION_ARGS[@]}" -gt 0 ]; then
        ARGS+=("${REDACTION_ARGS[@]}")
    fi

    # Clipboard mounts: the mediated Wayland socket on Linux (reads pass, writes refused —
    # the raw socket would be host code execution at your next terminal paste), or the
    # pbpaste bridge spool on macOS. Both no-op if their sidecar/bridge didn't come up.
    if is_macos; then
        add_clipboard_bridge_args
    else
        add_wayland_args
    fi

    # Follow the host's live DNS: mount systemd-resolved's live resolv.conf dir + the watcher
    # (see add_resolv_sync_args in cc-lib.sh). Linux only — on macOS the engine VM already
    # tracks the host resolver, so there is nothing to sync.
    is_macos || add_resolv_sync_args

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

    # Read-only: executed on the *host* later, so a container that could write it would
    # have host code execution (git hooks at the next commit). Belt-and-braces only — it
    # covers just this repo's top-level .git, and only if it exists at launch; the FUSE
    # guard is what actually covers nested repos, submodules and mid-session repos.
    # Sidecar mode only: in single mode $PWD is the in-container FUSE view, so binding the
    # host .git/hooks over it would shadow the view (and the guard already covers it).
    if [ "$CC_FUSE_MODE" = sidecar ] && [ -d "$PWD/.git/hooks" ]; then
        ARGS+=(-v "$PWD/.git/hooks:$PWD/.git/hooks:ro")
    fi

    # Everything here auto-loads in EVERY project's next session, so a write from one
    # sandboxed repo is a cross-project pivot (audit H6). Nested read-only binds over the
    # shared mount, because ~/.claude-shared itself must stay writable: an OAuth refresh
    # rewrites .credentials.json. settings.json is deliberately absent too — it stays
    # writable for /config, and validate_shared_settings vets it host-side each launch.
    #
    # Nothing is lost by locking these: the entrypoint gives each project its own
    # skills/agents/commands/plugins dir, so in-session creation and installs still work,
    # they just land per-project. --unlock-shared is how you promote one to all projects.
    if [ "$UNLOCK_SHARED" = 0 ]; then
        # `if`, not `[ … ] && ARGS+=`: a false test on the final iteration would make the
        # whole loop exit 1, which under `set -e` kills cc before the container starts.
        for _entry in CLAUDE.md hooks plugins skills agents commands; do
            if [ -e "$CLAUDE_SHARED/$_entry" ]; then
                ARGS+=(-v "$CLAUDE_SHARED/$_entry:/home/hostuser/.claude-shared/$_entry:ro")
            fi
        done
    fi

    # The container just idles; the real work runs in `docker exec` sessions, so it
    # survives any one terminal closing.
    docker run "${ARGS[@]}" "$IMAGE_NAME" sleep infinity >/dev/null \
        || die "failed to start the project container."
}

# ── Bring the container up, or attach to the running one ─────
# The boot lock serialises this section: two terminals launched at the same instant must
# not both try to `docker run` the same container name.
exec 201>"$BOOT_LOCK"
lock_fd -x 201
if container_running; then
    # Redaction is fixed at container creation: the rules are read once, and the
    # container outlives any one terminal. A second terminal must never silently run
    # under stale — or absent — rules, so verify_redaction_attach refuses to attach if
    # the redaction layer is missing or the .ccignore it enforces has since changed.
    # Both modes (sidecar/single) are checked through the same interface.
    verify_redaction_attach
    # The read-only mounts over ~/.claude-shared are fixed at container creation, and the
    # container outlives any one terminal — so a second terminal must never silently get the
    # other mode. Same hazard, same shape of refusal, as the stale-.ccignore check above.
    if [ "$(running_unlocked && echo 1 || echo 0)" != "$UNLOCK_SHARED" ]; then
        if [ "$UNLOCK_SHARED" = 1 ]; then
            die "this project's container is running with the shared config LOCKED, and" \
                "the mounts are fixed at creation. Close all cc sessions for this project," \
                "then run:" \
                "    cc --unlock-shared"
        fi
        # Also the shape of a container created before the shared-config lock existed:
        # it has no read-only mounts either, and must not be attached to as if it had.
        die "this project's container has ~/.claude-shared WRITABLE — it was started with" \
            "--unlock-shared, or it predates the shared-config lock. Refusing to attach" \
            "without the flag: the session would look protected and would not be." \
            "Close all cc sessions for this project and relaunch, or attach with:" \
            "    cc --unlock-shared"
    fi
    wait_for_container_ready   # in case its creator died mid-startup
    echo "🔗 cc: attaching to this project's running container ($CNAME)." >&2
else
    teardown_container    # clear anything a crashed session left behind
    start_container
    wait_for_container_ready
    # One resolv.conf watcher for the container's lifetime (see cc-lib.sh). Linux only:
    # on macOS the engine VM already tracks the host resolver, so there is nothing to
    # sync — one info line, and deliberately no desktop notification.
    if is_macos; then
        echo "ℹ️  DNS: handled by the Docker engine VM — follows the host resolver." >&2
    else
        start_resolv_sync
    fi
fi
lock_fd -u 201
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
        if lock_fd -n -x 202; then
            teardown_container
            lock_fd -u 202
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

# Single-container FUSE mode: the container is created with SYS_ADMIN (needed to mount),
# and `docker exec` gives EVERY session the container's full cap set — it does NOT inherit
# PID 1's reduced bounding set. So the drop must happen per session, here: enter as root
# (no --user) and `setpriv` off SYS_ADMIN/SETPCAP (needs CAP_SETPCAP effective, which root
# has) before `gosu` drops to the agent uid. Sidecar mode's container never had SYS_ADMIN,
# so it keeps the plain --user entry. USERFLAG is expanded with the set -u / bash-3.2-safe
# `[@]+` guard because it is empty in single mode.
INCMD=(/usr/local/bin/docker-entrypoint.sh "${CMD[@]}")
if [ "$CC_FUSE_MODE" = single ]; then
    INCMD=(setpriv --bounding-set -sys_admin,-setpcap gosu "$(id -u):$(id -g)" "${INCMD[@]}")
    USERFLAG=()
else
    USERFLAG=(--user "$(id -u):$(id -g)")
fi

# CC_SESSION_TAG marks every process in this terminal's session: claude, its tools and
# its subagents all inherit it across fork/exec, so the sleep guard can scope its /proc
# sample to this session alone. It is set on the *exec*, not the container, so it is
# per-terminal and works against a container created before this existed.
docker exec -it \
    ${USERFLAG[@]+"${USERFLAG[@]}"} \
    --workdir "$PWD" \
    -e COLUMNS="$(tput cols 2>/dev/null || echo 120)" \
    -e LINES="$(tput lines 2>/dev/null || echo 40)" \
    -e TERM="${TERM:-xterm-256color}" \
    -e CC_SESSION_TAG="$SESSION_TAG" \
    "$CNAME" "${INCMD[@]}"
