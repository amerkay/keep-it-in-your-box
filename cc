#!/usr/bin/env bash
set -euo pipefail

# ── Guard: forbid launching from sensitive host directories ──
# Blocks $HOME, ~/Desktop, ~/Documents, ~/Downloads when they are the
# current directory exactly. Subdirectories are allowed. Runs before
# any trap or `tput reset` so the error stays on screen after exit.
_resolved_pwd="$(realpath "$PWD" 2>/dev/null || echo "$PWD")"
_resolved_home="$(realpath "$HOME" 2>/dev/null || echo "$HOME")"
_blocked=""
if [ "$_resolved_pwd" = "$_resolved_home" ]; then
    _blocked="\$HOME"
else
    for _dir in Desktop Documents Downloads; do
        if [ "$_resolved_pwd" = "$_resolved_home/$_dir" ]; then
            _blocked="~/$_dir"
            break
        fi
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
unset _resolved_pwd _resolved_home _blocked _dir

IMAGE_NAME="claude-code-sandbox"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_LOCK="$SCRIPT_DIR/build.lock"
BUILD_LOG="$SCRIPT_DIR/build.log"
BUILD_PID="$SCRIPT_DIR/build.pid"

# ── Build image if missing (blocking — can't proceed without it) ─
if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    echo "🔨 Building Claude Code image (first time, please wait)..." >&2
    LATEST_VERSION="$(curl -sf https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/latest 2>/dev/null | tr -d '[:space:]' || true)"
    docker build --build-arg CLAUDE_VERSION="${LATEST_VERSION:-latest}" -t "$IMAGE_NAME" "$SCRIPT_DIR"
fi

# ── Check for Claude Code updates ────────────────────────────
# Skip update check if a build is already in progress.
# Never unlink the lock file: build-bg.sh holds flock on that *inode*, so an
# `rm -f` here would let the next build create a fresh inode and lock that
# instead — two concurrent builds, both truncating build.log and racing on
# `docker tag`. Test the lock in place; flock creates the file if it's absent.
if flock -n "$BUILD_LOCK" true 2>/dev/null; then
    echo "🔍 Checking for Claude Code updates..." >&2
    INSTALLED_VERSION="$(docker run --rm --entrypoint="" "$IMAGE_NAME" cat /etc/claude-code-version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    # Fallback for old images without the version file
    if [ -z "$INSTALLED_VERSION" ]; then
        INSTALLED_VERSION="$(docker run --rm --entrypoint="" "$IMAGE_NAME" claude --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    fi
    LATEST_VERSION="$(curl -sf https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/latest 2>/dev/null | tr -d '[:space:]' || true)"
    echo "   Installed: ${INSTALLED_VERSION:-unknown}" >&2
    echo "   Latest:    ${LATEST_VERSION:-unknown}" >&2

    if [ -n "$LATEST_VERSION" ] && { [ -z "$INSTALLED_VERSION" ] || [ "$INSTALLED_VERSION" != "$LATEST_VERSION" ]; }; then
        echo "⬆️  Claude Code update available: $INSTALLED_VERSION → $LATEST_VERSION" >&2
        read -rp "Rebuild image in background? [y/N] " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            # Background build in new process group (setsid) so kill -PGID kills entire tree
            setsid "$SCRIPT_DIR/build-bg.sh" &
            echo $! > "$BUILD_PID"
            disown
            echo "🔨 Starting background rebuild... (log: $BUILD_LOG)" >&2
            echo "   To cancel: kill -TERM -$(cat "$BUILD_PID")" >&2
        fi
    else
        echo "   ✓ Up to date" >&2
    fi
else
    BUILD_RUNNING_PID="$(cat "$BUILD_PID" 2>/dev/null || true)"
    echo "🔨 Background image rebuild in progress... (log: $BUILD_LOG)" >&2
    [ -n "$BUILD_RUNNING_PID" ] && echo "   To cancel: kill -TERM -$BUILD_RUNNING_PID" >&2
fi

# ── Container identity: ONE container per project ────────────
# Claude supports several concurrent sessions in one config dir (it has a
# [concurrentSessions] pid registry, and the daemon arbitrates via daemon.lock).
# Both mechanisms assume the sessions share a PID namespace and a /tmp — true for
# two terminals on the host, false for two containers. So instead of one container
# per terminal, cc keeps one *long-lived* container per project and every terminal
# attaches to it with `docker exec`. Claude then sees exactly what it sees on the
# host, and its own arbitration does the work.
#
# The name must therefore be stable per project, not per invocation. Hash $PWD so
# that two projects with the same basename don't collide.
PROJ_HASH="$(printf '%s' "$PWD" | sha256sum | cut -c1-8)"
CNAME="cc-$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-40)-$PROJ_HASH"

# ── Per-project Claude session isolation ─────────────────────
# Claude's background-agent daemon is a singleton arbitrated by a lock file in
# its config dir. Mounting one ~/.claude into every container made two concurrent
# sessions fight over it — and (separate PID namespaces) each read the other's pid
# against its own /proc and displaced it. It also let every container read every
# other project's transcripts.
#
# So: CLAUDE_CONFIG_DIR gets a per-project dir (daemon, sessions, jobs, history,
# transcripts, .claude.json), while CLAUDE_SECURESTORAGE_CONFIG_DIR keeps pointing
# at one shared dir, so all projects still share a single login token.
CLAUDE_SHARED="$HOME/.claude-shared"
CLAUDE_SANDBOX="$HOME/.claude-sandbox"
SLUG="$(printf '%s' "$PWD" | sed 's/[^a-zA-Z0-9]/-/g')"
SESSION_DIR="$CLAUDE_SANDBOX/$SLUG"
EPHEMERAL=0

# The locks that arbitrate the container's lifetime live OUTSIDE $SESSION_DIR,
# because $SESSION_DIR is bind-mounted rw into the container: Claude could delete
# .cc.lock from inside, and unlinking a lock file whose inode another cc holds
# flocked lets the next one lock a fresh inode — two "last terminals out", both
# tearing the container down under a live session. Keep them host-only.
LOCK_DIR="$CLAUDE_SANDBOX/.locks"
LOCK_FILE="$LOCK_DIR/$SLUG.lock"
BOOT_LOCK="$LOCK_DIR/$SLUG.boot.lock"

# Suffix for this session's scratch dirs (FUSE/mask). Empty for the project's
# shared container; set for an ephemeral one so it can never touch the real one's.
SCRATCH_SUFFIX=""

if [ ! -f "$CLAUDE_SHARED/.migrated" ]; then
    echo "" >&2
    echo "❌ cc: per-project session isolation isn't set up yet." >&2
    echo "   Run the one-time migration (it splits ~/.claude into a shared dir" >&2
    echo "   and one dir per project):" >&2
    echo "     $SCRIPT_DIR/migrate-sessions.sh            # dry run — shows every change" >&2
    echo "     $SCRIPT_DIR/migrate-sessions.sh --apply    # commit" >&2
    echo "" >&2
    exit 1
fi

mkdir -p "$LOCK_DIR" && chmod 700 "$LOCK_DIR"

# A legacy ~/.claude means the migration was undone or a host `claude` recreated
# one. It is no longer mounted, so it can't leak — but it will silently diverge
# from the real config, so say so rather than let it rot.
if [ -d "$HOME/.claude/projects" ] || [ -f "$HOME/.claude/.credentials.json" ]; then
    echo "⚠️  cc: a legacy ~/.claude exists but is NOT used by the sandbox any more." >&2
    echo "   Remove it so it can't drift: rm -rf ~/.claude ~/.claude.json" >&2
fi

# Keep the shared sandbox policy current, in a marker-delimited block at the top of
# the shared CLAUDE.md. Anything the user (or Claude's `#` shortcut) writes below
# the block survives; the block itself always tracks shared-CLAUDE.md in this repo.
if [ -f "$SCRIPT_DIR/shared-CLAUDE.md" ]; then
    _md="$CLAUDE_SHARED/CLAUDE.md"
    _b="<!-- >>> cc sandbox policy (auto-synced by cc — do not edit this block) >>> -->"
    _e="<!-- <<< cc sandbox policy (auto-synced by cc) <<< -->"
    _rest=""
    [ -f "$_md" ] && _rest="$(awk -v b="$_b" -v e="$_e" '
        $0==b {skip=1; next} $0==e {skip=0; next} !skip {print}' "$_md")"
    {
        printf '%s\n' "$_b"
        cat "$SCRIPT_DIR/shared-CLAUDE.md"
        printf '%s\n' "$_e"
        # `if`, not `[ -n "$_rest" ] && printf ...`: an AND-list as the group's last
        # command makes the group exit 1 when _rest is empty (no user memory yet),
        # which silently skips the `&& mv` below and leaves a stray .cc.tmp.
        if [ -n "$_rest" ]; then
            printf '%s\n' "$_rest"
        fi
    } > "$_md.cc.tmp" && mv "$_md.cc.tmp" "$_md"
    unset _md _b _e _rest
fi

if [ "${CC_FORCE_NEW_SESSION:-0}" = "1" ]; then
    # Clean-slate session: its own container AND its own config dir, so it has its
    # own daemon and cannot collide with the project's real one. Throwaway — no
    # history, transcripts discarded on exit. Not needed just to open a second
    # terminal (that now attaches to the shared container); this is for starting
    # from scratch without touching the project's state.
    SESSION_DIR="$CLAUDE_SANDBOX/$SLUG.ephemeral.$$"
    CNAME="$CNAME-eph-$$"
    EPHEMERAL=1
    # Its own scratch dirs too. Without this it would share /tmp/cc-fuse.$PROJ_HASH
    # with the project's real container — and tear that container's live redaction
    # mount down on start ("clear anything a crashed session left behind") and again
    # on exit, unmasking .ccignore'd files under a running session.
    SCRATCH_SUFFIX=".eph.$$"
    mkdir -p "$SESSION_DIR" && chmod 700 "$SESSION_DIR"
    cp "$CLAUDE_SHARED/claude-json.seed" "$SESSION_DIR/.claude.json" 2>/dev/null || true
    # Reap it even if we bail out below (e.g. the FUSE sidecar fails) — the real
    # cleanup() trap isn't installed until just before the container starts.
    trap 'rm -rf "$SESSION_DIR"' EXIT
    echo "⚠️  CC_FORCE_NEW_SESSION=1 — ephemeral session; no history, discarded on exit." >&2
else
    if [ ! -d "$SESSION_DIR" ]; then
        mkdir -p "$SESSION_DIR" && chmod 700 "$SESSION_DIR"
        cp "$CLAUDE_SHARED/claude-json.seed" "$SESSION_DIR/.claude.json" 2>/dev/null || true
        echo "🆕 cc: first run here — new session dir $SESSION_DIR" >&2
    fi
    # SHARED lock, held for this terminal's lifetime. Any number of terminals may
    # hold it at once — it is a reference count on the project's container, not a
    # mutex. It blocks only while a departing session holds the lock *exclusively*
    # to tear the container down, so we can never attach to a dying container.
    # Never unlinked (see build.lock).
    exec 200>"$LOCK_FILE"
    if ! flock -w 60 -s 200; then
        echo "❌ cc: timed out waiting for the project lock ($LOCK_FILE)." >&2
        exit 1
    fi
fi

# ── Sync .ccignore → .gitignore + install host pre-commit guard ──
# .ccignore hides sensitive paths from the container, but nothing stops git
# from committing them on the host — leaking their real contents into history
# and diffs. Keep them out of git two ways: (1) mirror .ccignore into a managed
# block in .gitignore (blocks untracked files from being added), and (2) install
# a pre-commit hook (the real backstop — also catches already-tracked files).
# Anchored at the git toplevel; if cc is launched from a subdir, skip with a note.
if [ -f "$PWD/.ccignore" ]; then
    _git_top="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -z "$_git_top" ]; then
        : # not a git repo — nothing to sync
    elif [ "$(realpath "$_git_top" 2>/dev/null || echo "$_git_top")" != "$(realpath "$PWD" 2>/dev/null || echo "$PWD")" ]; then
        echo "ℹ️  .ccignore: launched from a subdir of the git repo; skipping" >&2
        echo "   .gitignore sync + pre-commit guard (they anchor at the repo root)." >&2
    else
        # (1) Translate .ccignore rules to gitignore syntax. Bare names match
        #     anywhere (same as gitignore); '/'-containing rules anchor at root.
        #     Skip leading-'/' and '..'-component rules (unsafe — fuse skips too).
        _cc_patterns=""
        while IFS= read -r _line || [ -n "$_line" ]; do
            _line="${_line%%#*}"
            _line="${_line#"${_line%%[![:space:]]*}"}" # ltrim
            _line="${_line%"${_line##*[![:space:]]}"}" # rtrim
            # Detach a leading '!' (negation) so the anchoring '/' we add below
            # goes *after* it (!/foo, not /!foo — the latter is a literal path
            # starting with '!' and negates nothing). Re-attached at the end.
            _neg=""
            case "$_line" in
                !*) _neg="!"; _line="${_line#!}" ;;
            esac
            _line="${_line%/}"
            [ -z "$_line" ] && continue
            case "$_line" in
                /*) continue ;;
            esac
            case "/$_line/" in
                */../*) continue ;;
            esac
            case "$_line" in
                */*) _cc_patterns+="$_neg/$_line"$'\n' ;;
                *) _cc_patterns+="$_neg$_line"$'\n' ;;
            esac
        done < "$PWD/.ccignore"

        _gi="$PWD/.gitignore"
        _begin="# >>> ccignore (auto-synced by cc — do not edit this block) >>>"
        _end="# <<< ccignore (auto-synced by cc) <<<"
        # Strip any prior managed block, preserving everything else.
        _rest=""
        [ -f "$_gi" ] && _rest="$(awk -v b="$_begin" -v e="$_end" '
            $0==b {skip=1; next} $0==e {skip=0; next} !skip {print}' "$_gi")"
        {
            [ -n "$_rest" ] && printf '%s\n' "$_rest"
            if [ -n "$_cc_patterns" ]; then
                printf '%s\n' "$_begin"
                printf '%s\n' "# Mirrors .ccignore so paths hidden from the sandbox are never committed."
                printf '%s' "$_cc_patterns"
                printf '%s\n' "$_end"
            fi
        } > "$_gi.cc.tmp" && mv "$_gi.cc.tmp" "$_gi"

        # (2) Install / refresh the pre-commit guard (host-side enforcement).
        _hooks="$PWD/.git/hooks"
        _hook="$_hooks/pre-commit"
        [ -d "$_hooks" ] || mkdir -p "$_hooks"
        if [ -e "$_hook" ] && ! grep -q "MARKER: ccignore-precommit" "$_hook" 2>/dev/null; then
            echo "⚠️  .ccignore: existing pre-commit hook at $_hook; not overwriting." >&2
            echo "   ccignored files may still be committable — merge the guard manually" >&2
            echo "   from $SCRIPT_DIR/ccignore-precommit.py" >&2
        elif ! cmp -s "$SCRIPT_DIR/ccignore-precommit.py" "$_hook" 2>/dev/null; then
            cp "$SCRIPT_DIR/ccignore-precommit.py" "$_hook" && chmod +x "$_hook"
        fi
        unset _cc_patterns _gi _begin _end _rest _hooks _hook _line
    fi
    unset _git_top
fi

# ── Container lifecycle ──────────────────────────────────────
# The container outlives any single terminal, so everything it depends on (the FUSE
# sidecar, its scratch dirs) must be addressable by *any* cc process, not just the
# one that created it. Hence paths derived from the project hash rather than mktemp.
FUSE_CNAME="${CNAME}-fuse"
FUSE_ROOT="/tmp/cc-fuse.${PROJ_HASH}${SCRATCH_SUFFIX}"
MASK_ROOT="/tmp/cc-mask.${PROJ_HASH}${SCRATCH_SUFFIX}"
FUSE_FAILED=0
PROJECT_MOUNT_SRC="$PWD"
PROJECT_MOUNT_OPTS=""

container_running() { [ -n "$(docker ps -q -f "name=^${CNAME}$" 2>/dev/null)" ]; }
sidecar_running()   { [ -n "$(docker ps -q -f "name=^${FUSE_CNAME}$" 2>/dev/null)" ]; }

# The entrypoint runs as root and does real work before the container is usable —
# useradd, the shared-asset symlink farm, chown of the session dir — then execs
# `gosu … sleep infinity`. `docker run -d` returns as soon as PID 1 exists, so an
# immediate `docker exec` can land mid-setup: no home directory yet, no symlinks,
# a chown walking the dir under us. Only once the entrypoint has exec'd is there a
# process whose command line is *exactly* `sleep infinity`, so that is the signal.
#
# It must be an exact, whole-line match: while the entrypoint is still working, its
# own command line is `/bin/sh /usr/local/bin/docker-entrypoint.sh sleep infinity`,
# and PID 1 (docker-init) keeps `… -- …docker-entrypoint.sh sleep infinity` forever.
# A substring grep would call a half-set-up container ready.
container_ready() {
    local args
    args="$(docker top "$CNAME" -o args 2>/dev/null)" \
        || args="$(docker top "$CNAME" 2>/dev/null |
                   awk 'NR>1 { $1=$2=$3=$4=$5=$6=$7=""; sub(/^ +/,""); print }')"
    printf '%s\n' "$args" | grep -qx 'sleep infinity'
}

wait_for_container_ready() {
    local _
    for _ in $(seq 1 120); do   # ≤60s; a cold entrypoint is ~1s
        if container_ready; then
            return 0
        fi
        if ! container_running; then
            echo "❌ cc: the project container exited during startup. Logs:" >&2
            docker logs "$CNAME" 2>&1 | tail -20 | sed 's/^/   /' >&2 || true
            teardown_container
            exit 1
        fi
        sleep 0.5
    done
    # Leave nothing half-started behind: a running-but-never-ready container would
    # make every later cc attach to it and hit this same timeout.
    echo "❌ cc: the project container never finished starting up (60s)." >&2
    docker logs "$CNAME" 2>&1 | tail -20 | sed 's/^/   /' >&2 || true
    teardown_container
    exit 1
}

# Is anything mounted at $1? Asks the kernel directly, via /proc/self/mounts.
# `mountpoint -q` is NOT usable here: once the sidecar dies, the mount is still in
# the mount table but every stat() on it returns ENOTCONN, so mountpoint reports
# "not a mountpoint" for a directory that very much still is one.
fuse_mounted() {
    awk -v p="$1" '$2 == p { found = 1 } END { exit !found }' /proc/self/mounts 2>/dev/null
}

unmount_fuse() {
    local m="$1"
    fuse_mounted "$m" || return 0
    fusermount3 -u "$m" 2>/dev/null \
        || fusermount -u "$m" 2>/dev/null \
        || umount -l "$m" 2>/dev/null || true    # lazy: last resort for a dead server
    ! fuse_mounted "$m"
}

teardown_container() {
    docker stop -t 5 "$CNAME" >/dev/null 2>&1 || true   # started with --rm; stop removes it

    # Unmount BEFORE killing the sidecar. The other order kills the FUSE server first,
    # which leaves a mounted-but-ENOTCONN mount that the old `mountpoint -q` guard
    # skipped — orphaning the mount on every exit and making the *next* launch of this
    # project die on the rm below.
    if ! unmount_fuse "$FUSE_ROOT/mnt"; then
        echo "❌ cc: a .ccignore redaction mount is still mounted at" >&2
        echo "     $FUSE_ROOT/mnt" >&2
        echo "   and could not be unmounted. Refusing to delete it: that path is a" >&2
        echo "   passthrough view of your project, so removing it while mounted would" >&2
        echo "   delete the real files. Clear it by hand, then relaunch:" >&2
        echo "     fusermount3 -u '$FUSE_ROOT/mnt' || sudo umount -l '$FUSE_ROOT/mnt'" >&2
        exit 1
    fi
    docker rm -f "$FUSE_CNAME" >/dev/null 2>&1 || true

    # `|| true`: never let a failed cleanup kill cc under `set -e` — least of all in
    # the EXIT trap, where it would also overwrite the session's exit code.
    rm -rf "$FUSE_ROOT" "$MASK_ROOT" 2>/dev/null || true
}

# ── .ccignore FUSE sidecar (masks matched paths at launch AND mid-session) ──
# Runs a FUSE redacting passthrough in a separate container and exposes it
# to the main container via shared-mount propagation. Host needs nothing
# beyond docker; main container keeps cap-drop=ALL — only the sidecar gets
# SYS_ADMIN + /dev/fuse, and its only code is ccignore-fuse.py over a
# read-only view of $PWD.
start_fuse_sidecar() {
    [ -f "$PWD/.ccignore" ] || return 0

    # Propagation of the scratch dir must be shared so the sidecar's FUSE
    # mount is visible to the main container through the host.
    local prop
    prop="$(findmnt -no PROPAGATION --target /tmp 2>/dev/null || true)"
    if [[ "$prop" != *shared* ]]; then
        echo "⚠️  .ccignore: /tmp is not a shared mount ($prop); falling back to" >&2
        echo "   launch-time-only masking. Files created mid-session will NOT be masked." >&2
        return 0
    fi

    # 755 on both: the sidecar runs as our uid, but the main container traverses
    # this path as root before dropping privileges. (-m with -p would only apply to
    # the deepest dir, so set them explicitly.)
    mkdir -p "$FUSE_ROOT/mnt"
    chmod 755 "$FUSE_ROOT" "$FUSE_ROOT/mnt"
    cp "$PWD/.ccignore" "$FUSE_ROOT/patterns"
    chmod 644 "$FUSE_ROOT/patterns"

    if ! docker run -d --name "$FUSE_CNAME" \
        --cap-drop=ALL --cap-add=SYS_ADMIN \
        --device /dev/fuse --security-opt apparmor=unconfined \
        --user "$(id -u):$(id -g)" --userns=host --entrypoint python3 \
        --network none \
        -v "$PWD:/src" \
        -v "$FUSE_ROOT:$FUSE_ROOT:rshared" \
        -v /etc/passwd:/etc/passwd:ro \
        -v /etc/group:/etc/group:ro \
        -v "$SCRIPT_DIR/ccignore-fuse.py:/usr/local/bin/ccignore-fuse.py:ro" \
        "$IMAGE_NAME" \
        /usr/local/bin/ccignore-fuse.py \
            --src /src --mnt "$FUSE_ROOT/mnt" \
            --patterns-file "$FUSE_ROOT/patterns" >/dev/null; then
        echo "❌ .ccignore: could not start FUSE sidecar. Aborting." >&2
        rm -rf "$FUSE_ROOT"
        FUSE_FAILED=1
        exit 1
    fi

    # Wait for mount to be live (≤5s).
    local _
    for _ in $(seq 1 100); do
        if fuse_mounted "$FUSE_ROOT/mnt"; then break; fi
        sleep 0.05
    done
    if ! fuse_mounted "$FUSE_ROOT/mnt"; then
        echo "❌ .ccignore: FUSE sidecar failed to mount; sidecar logs:" >&2
        docker logs "$FUSE_CNAME" 2>&1 | sed 's/^/   /' >&2 || true
        docker rm -f "$FUSE_CNAME" >/dev/null 2>&1 || true
        rm -rf "$FUSE_ROOT"
        echo "   Refusing to launch with leaky fallback masking. Aborting." >&2
        FUSE_FAILED=1
        exit 1
    fi

    PROJECT_MOUNT_SRC="$FUSE_ROOT/mnt"
    PROJECT_MOUNT_OPTS=":rslave"
    echo "🛡️  .ccignore: FUSE redacting mount active (sidecar: $FUSE_CNAME)" >&2
}

# ── Fallback: launch-time-only .ccignore masking via bind mounts ──
# Only used when the FUSE sidecar didn't activate (e.g. /tmp not shared).
# Same caveat as before: files created on host AFTER launch are NOT masked.
add_fallback_mask_args() {
    [ -f "$PWD/.ccignore" ] || return 0
    [ -z "$PROJECT_MOUNT_OPTS" ] || return 0   # FUSE is active; nothing to do

    mkdir -p "$MASK_ROOT/dir"
    local msg="# REDACTED: This path was redacted inside the Claude Code container by .ccignore. The real contents are available on the host machine."
    printf '%s\n' "$msg" > "$MASK_ROOT/dir/REDACTED.md"
    printf '%s\n' "$msg" > "$MASK_ROOT/file"

    local targets=() entry m found t p
    while IFS= read -r entry || [ -n "$entry" ]; do
        entry="${entry%%#*}"; entry="${entry%$'\r'}"; entry="${entry%/}"
        [ -z "$entry" ] && continue
        case "$entry" in /*|*..*) echo "⚠️  .ccignore: unsafe path '$entry'" >&2; continue;; esac
        if [[ "$entry" != */* ]]; then
            found=0
            while IFS= read -r -d '' m; do targets+=("$m"); found=1; done \
                < <(find "$PWD" -name .git -prune -o -name "$entry" -print0 2>/dev/null)
            [ "$found" = 0 ] && echo "⚠️  .ccignore: no matches for '$entry'" >&2
        elif [ -e "$PWD/$entry" ]; then
            targets+=("$PWD/$entry")
        else
            echo "⚠️  .ccignore: '$entry' does not exist" >&2
        fi
    done < "$PWD/.ccignore"

    # Sort shortest-first, then skip anything equal-to or nested-under an accepted path.
    local accepted=()
    if [ "${#targets[@]}" -gt 0 ]; then
        while IFS= read -r t; do
            for p in "${accepted[@]}"; do
                [[ "$t" == "$p" || "$t" == "$p"/* ]] && continue 2
            done
            accepted+=("$t")
            if [ -d "$t" ]; then
                ARGS+=(-v "$MASK_ROOT/dir:$t:ro")
            else
                ARGS+=(-v "$MASK_ROOT/file:$t:ro")
            fi
        done < <(printf '%s\n' "${targets[@]}" | awk '{print length,$0}' | sort -n -s | cut -d' ' -f2-)
        echo "🛡️  .ccignore: masking ${#accepted[@]} path(s)" >&2
    fi
}

start_container() {
    start_fuse_sidecar

    # --init: PID 1 is `sleep infinity`, which would never reap the zombies left by
    # exec'd sessions. Docker's init does.
    ARGS=(
        -d --init --rm
        --name "$CNAME"

        # Mount project at same path as host so Claude uses correct project config.
        # When FUSE is active, source is the redacting mount with rslave propagation.
        -v "$PROJECT_MOUNT_SRC:$PWD$PROJECT_MOUNT_OPTS"

        # This project's private state: daemon, sessions, jobs, transcripts,
        # history.jsonl, .claude.json. No other project's container mounts it.
        -v "$SESSION_DIR:/home/hostuser/.claude-session"

        # Shared by every project: login token, settings, plugins, skills, CLAUDE.md.
        # Writable — an OAuth refresh has to rewrite .credentials.json.
        -v "$CLAUDE_SHARED:/home/hostuser/.claude-shared"

        # The split that makes the above work: config (and .claude.json) resolve to the
        # per-project dir, credentials to the shared one.
        -e CLAUDE_CONFIG_DIR=/home/hostuser/.claude-session
        -e CLAUDE_SECURESTORAGE_CONFIG_DIR=/home/hostuser/.claude-shared

        # Pass host UID/GID and HOME for runtime user creation. docker exec inherits
        # these from the container config, so attached sessions get them too.
        -e HOST_UID="$(id -u)"
        -e HOST_GID="$(id -g)"
        -e HOST_HOME="$HOME"
        -e HOST_PWD="$PWD"

        # Drop all capabilities, add back only what entrypoint needs for user setup + gosu
        --cap-drop=ALL
        --cap-add=SETUID
        --cap-add=SETGID
        --cap-add=CHOWN
        --cap-add=DAC_OVERRIDE
        --cap-add=FOWNER

        # Bridge network (Docker isolation) + Claude's built-in sandbox (domain allowlist)
        # Use --add-host to allow access to host dev servers if needed
        --add-host=host.docker.internal:host-gateway

        # Disable telemetry
        -e DISABLE_TELEMETRY=1
        -e DISABLE_ERROR_REPORTING=1

        # Wayland clipboard access (for image pasting in KDE/Wayland)
        -e XDG_RUNTIME_DIR="/run/user/$(id -u)"
        -e WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
        -v "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY:-wayland-0}:/run/user/$(id -u)/${WAYLAND_DISPLAY:-wayland-0}"
    )

    # Forward git identity
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

    # Protect paths that could execute code on the host
    if [ -d "$PWD/.git/hooks" ]; then
        ARGS+=(-v "$PWD/.git/hooks:$PWD/.git/hooks:ro")
    fi
    if [ -d "$CLAUDE_SHARED/hooks" ]; then
        ARGS+=(-v "$CLAUDE_SHARED/hooks:/home/hostuser/.claude-shared/hooks:ro")
    fi

    add_fallback_mask_args

    # The container just idles; the real work runs in `docker exec` sessions, so it
    # survives any one terminal closing.
    if ! docker run "${ARGS[@]}" "$IMAGE_NAME" sleep infinity >/dev/null; then
        echo "❌ cc: failed to start the project container." >&2
        exit 1
    fi
}

# ── Bring the project's container up, or attach to the running one ──
# The boot lock serialises this section: two terminals launched at the same instant
# must not both try to `docker run` the same container name.
exec 201>"$BOOT_LOCK"
flock -x 201
if container_running; then
    # Redaction is fixed at container creation: the sidecar reads .ccignore once,
    # and the fallback masks are bind mounts baked into `docker run`. A second
    # terminal must never silently run under stale — or absent — rules.
    if [ -f "$PWD/.ccignore" ] && ! sidecar_running; then
        if [ -d "$MASK_ROOT" ]; then
            echo "❌ cc: this project's container is using launch-time .ccignore masking" >&2
            echo "   (the FUSE sidecar didn't start — /tmp isn't a shared mount here)." >&2
            echo "   That mode masks a fixed set of paths chosen when the container was" >&2
            echo "   created, so it can't be re-evaluated for a second terminal. One cc" >&2
            echo "   session at a time on this project — close the other one first." >&2
        else
            echo "❌ cc: .ccignore exists, but this project's running container was started" >&2
            echo "   without redaction. Refusing to attach — close all cc sessions for" >&2
            echo "   this project and relaunch to apply it." >&2
        fi
        exit 1
    fi
    if [ -f "$PWD/.ccignore" ] && ! cmp -s "$PWD/.ccignore" "$FUSE_ROOT/patterns" 2>/dev/null; then
        echo "❌ cc: .ccignore changed since this project's container started." >&2
        echo "   The running redaction layer still enforces the OLD rules. Refusing to" >&2
        echo "   attach — close all cc sessions for this project and relaunch." >&2
        exit 1
    fi
    if [ ! -f "$PWD/.ccignore" ] && sidecar_running; then
        echo "⚠️  cc: .ccignore was removed, but the running container still redacts" >&2
        echo "   per the old rules. Close all sessions and relaunch to clear it." >&2
    fi
    wait_for_container_ready   # in case its creator died mid-startup
    echo "🔗 cc: attaching to this project's running container ($CNAME)." >&2
else
    teardown_container    # clear anything a crashed session left behind
    start_container
    wait_for_container_ready
fi
flock -u 201
exec 201>&-

# ── Sleep guard (inhibit system sleep while Claude produces output) ──
# 200>&- / 201>&- so it doesn't inherit our lock fds: a guard outliving cc would
# hold the project's shared lock and stop the container from ever being torn down.
"$SCRIPT_DIR/sleep-guard.sh" "$CNAME" 200>&- 201>&- &
SLEEP_GUARD_PID=$!

cleanup() {
    kill "$SLEEP_GUARD_PID" 2>/dev/null || true

    if [ "$EPHEMERAL" = 1 ]; then
        teardown_container
        [ -n "$SESSION_DIR" ] && rm -rf "$SESSION_DIR"
    else
        # Are we the last terminal out? Drop our shared lock, then try to take the
        # lock exclusively. That can only succeed if no other cc still holds it —
        # and while we hold it, a starting cc blocks on its `flock -s`, so it cannot
        # attach to a container we are about to stop.
        exec 200>&-
        exec 202>"$LOCK_FILE"
        if flock -n -x 202; then
            teardown_container
            flock -u 202
        fi
        exec 202>&-
    fi

    # `|| true`: tput exits 10 when stdout isn't a tty (cc piped or redirected), and
    # the EXIT trap's last status becomes the shell's — that would mask the session's
    # real exit code.
    if [ "$FUSE_FAILED" != 1 ]; then
        tput reset 2>/dev/null || true
    fi
}
trap cleanup EXIT
# Closing the terminal window sends SIGHUP; `kill` sends SIGTERM. Bash would take
# either as a fatal signal and die *without* running the EXIT trap — leaving the
# sleep-guard orphaned (holding a sleep inhibitor) and, if this was the last
# terminal, the container running for good. Exit properly instead, so cleanup runs.
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

# Reset terminal so Claude's TUI starts with a clean screen. `|| true` because tput
# exits 10 with no tty — under `set -e` that would kill a redirected/piped run
# (e.g. `cc claude -p '…' > out.txt`) before the session ever started.
tput reset 2>/dev/null || true

docker exec -it \
    --user "$(id -u):$(id -g)" \
    --workdir "$PWD" \
    -e COLUMNS="$(tput cols 2>/dev/null || echo 120)" \
    -e LINES="$(tput lines 2>/dev/null || echo 40)" \
    -e TERM="${TERM:-xterm-256color}" \
    "$CNAME" /usr/local/bin/docker-entrypoint.sh "${CMD[@]}"
