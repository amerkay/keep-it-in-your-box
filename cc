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
# Skip update check if a build is already in progress
if [ -f "$BUILD_LOCK" ] && flock -n "$BUILD_LOCK" true 2>/dev/null; then
    # Lock file exists but is not locked — stale, clean up
    rm -f "$BUILD_LOCK"
fi

if flock -n "$BUILD_LOCK" true 2>/dev/null || [ ! -f "$BUILD_LOCK" ]; then
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

# ── Container name from project dir ──────────────────────────
CNAME="cc-$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')-$$"

# ── .ccignore FUSE sidecar (masks matched paths at launch AND mid-session) ──
# Runs a FUSE redacting passthrough in a separate container and exposes it
# to the main container via shared-mount propagation. Host needs nothing
# beyond docker; main container keeps cap-drop=ALL — only the sidecar gets
# SYS_ADMIN + /dev/fuse, and its only code is ccignore-fuse.py over a
# read-only view of $PWD.
FUSE_SESSION_DIR=""
FUSE_CNAME=""
FUSE_FAILED=0
PROJECT_MOUNT_SRC="$PWD"
PROJECT_MOUNT_OPTS=""
if [ -f "$PWD/.ccignore" ]; then
    # Propagation of the scratch dir must be shared so the sidecar's FUSE
    # mount is visible to the main container through the host.
    _prop="$(findmnt -no PROPAGATION --target /tmp 2>/dev/null || true)"
    if [[ "$_prop" != *shared* ]]; then
        echo "⚠️  .ccignore: /tmp is not a shared mount ($_prop); falling back to" >&2
        echo "   launch-time-only masking. Files created mid-session will NOT be masked." >&2
        FUSE_SESSION_DIR=""
    else
        FUSE_SESSION_DIR="$(mktemp -d -p /tmp cc-fuse.XXXXXX)"
        chmod 755 "$FUSE_SESSION_DIR"
        mkdir -m 755 "$FUSE_SESSION_DIR/mnt"
        cp "$PWD/.ccignore" "$FUSE_SESSION_DIR/patterns"
        chmod 644 "$FUSE_SESSION_DIR/patterns"
        FUSE_CNAME="${CNAME}-fuse"
        if docker run -d --name "$FUSE_CNAME" \
            --cap-drop=ALL --cap-add=SYS_ADMIN \
            --device /dev/fuse --security-opt apparmor=unconfined \
            --user "$(id -u):$(id -g)" --userns=host --entrypoint python3 \
            --network none \
            -v "$PWD:/src" \
            -v "$FUSE_SESSION_DIR:$FUSE_SESSION_DIR:rshared" \
            -v /etc/passwd:/etc/passwd:ro \
            -v /etc/group:/etc/group:ro \
            "$IMAGE_NAME" \
            /usr/local/bin/ccignore-fuse.py \
                --src /src --mnt "$FUSE_SESSION_DIR/mnt" \
                --patterns-file "$FUSE_SESSION_DIR/patterns" >/dev/null; then
            # Wait for mount to be live (≤5s).
            for _ in $(seq 1 100); do
                if mountpoint -q "$FUSE_SESSION_DIR/mnt" 2>/dev/null; then break; fi
                sleep 0.05
            done
            if mountpoint -q "$FUSE_SESSION_DIR/mnt" 2>/dev/null; then
                PROJECT_MOUNT_SRC="$FUSE_SESSION_DIR/mnt"
                PROJECT_MOUNT_OPTS=":rslave"
                echo "🛡️  .ccignore: FUSE redacting mount active (sidecar: $FUSE_CNAME)" >&2
            else
                echo "❌ .ccignore: FUSE sidecar failed to mount; sidecar logs:" >&2
                docker logs "$FUSE_CNAME" 2>&1 | sed 's/^/   /' >&2 || true
                docker rm -f "$FUSE_CNAME" >/dev/null 2>&1 || true
                rm -rf "$FUSE_SESSION_DIR"
                FUSE_SESSION_DIR=""
                FUSE_CNAME=""
                echo "   Refusing to launch with leaky fallback masking. Aborting." >&2
                FUSE_FAILED=1
                exit 1
            fi
        else
            echo "❌ .ccignore: could not start FUSE sidecar. Aborting." >&2
            rm -rf "$FUSE_SESSION_DIR"
            FUSE_SESSION_DIR=""
            FUSE_CNAME=""
            FUSE_FAILED=1
            exit 1
        fi
    fi
fi

# ── Docker args ──────────────────────────────────────────────
ARGS=(
    --rm -it
    --name "$CNAME"

    # Mount project at same path as host so Claude uses correct project config.
    # When FUSE is active, source is the redacting mount with rslave propagation.
    -v "$PROJECT_MOUNT_SRC:$PWD$PROJECT_MOUNT_OPTS"

    # Shared config: OAuth tokens, settings, conversation history
    # Mount at both host home path and container user home so both resolve
    -v "$HOME/.claude:$HOME/.claude"
    -v "$HOME/.claude:/home/hostuser/.claude"

    # Auth/config file (lives at home root, not inside .claude/)
    -v "$HOME/.claude.json:$HOME/.claude.json"
    -v "$HOME/.claude.json:/home/hostuser/.claude.json"

    # Pass host UID/GID and HOME for runtime user creation
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

    # Terminal
    -e COLUMNS="$(tput cols 2>/dev/null || echo 120)"
    -e LINES="$(tput lines 2>/dev/null || echo 40)"
    -e TERM="${TERM:-xterm-256color}"

    # Wayland clipboard access (for image pasting in KDE/Wayland)
    -e XDG_RUNTIME_DIR="/run/user/$(id -u)"
    -e WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
    -v "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY:-wayland-0}:/run/user/$(id -u)/${WAYLAND_DISPLAY:-wayland-0}"
)

# ── Forward git identity ─────────────────────────────────────
GIT_NAME="$(git config --global user.name 2>/dev/null || true)"
GIT_EMAIL="$(git config --global user.email 2>/dev/null || true)"
[ -n "$GIT_NAME" ] && ARGS+=(
    -e GIT_AUTHOR_NAME="$GIT_NAME"
    -e GIT_COMMITTER_NAME="$GIT_NAME"
    -e GIT_AUTHOR_EMAIL="$GIT_EMAIL"
    -e GIT_COMMITTER_EMAIL="$GIT_EMAIL"
)

# ── Protect paths that could execute code on the host ──
if [ -d "$PWD/.git/hooks" ]; then
    ARGS+=(-v "$PWD/.git/hooks:$PWD/.git/hooks:ro")
fi
if [ -d "$HOME/.claude/hooks" ]; then
    ARGS+=(-v "$HOME/.claude/hooks:$HOME/.claude/hooks:ro")
    ARGS+=(-v "$HOME/.claude/hooks:/home/hostuser/.claude/hooks:ro")
fi

# ── Fallback: launch-time-only .ccignore masking via bind mounts ──
# Only used when the FUSE sidecar above didn't activate (e.g. /tmp not shared).
# Same caveat as before: files created on host AFTER launch are NOT masked.
CCIGNORE_TMP=""
if [ -f "$PWD/.ccignore" ] && [ -z "$FUSE_SESSION_DIR" ]; then
    CCIGNORE_TMP="$(mktemp -d)"
    mkdir -p "$CCIGNORE_TMP/dir"
    REDACT_MSG="# REDACTED: This path was redacted inside the Claude Code container by .ccignore. The real contents are available on the host machine."
    printf '%s\n' "$REDACT_MSG" > "$CCIGNORE_TMP/dir/REDACTED.md"
    printf '%s\n' "$REDACT_MSG" > "$CCIGNORE_TMP/file"

    targets=()
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
    accepted=()
    if [ "${#targets[@]}" -gt 0 ]; then
        while IFS= read -r t; do
            for p in "${accepted[@]}"; do
                [[ "$t" == "$p" || "$t" == "$p"/* ]] && continue 2
            done
            accepted+=("$t")
            if [ -d "$t" ]; then
                ARGS+=(-v "$CCIGNORE_TMP/dir:$t:ro")
            else
                ARGS+=(-v "$CCIGNORE_TMP/file:$t:ro")
            fi
        done < <(printf '%s\n' "${targets[@]}" | awk '{print length,$0}' | sort -n -s | cut -d' ' -f2-)
        echo "🛡️  .ccignore: masking ${#accepted[@]} path(s)" >&2
    fi
fi

# ── Sleep guard (inhibit system sleep while Claude produces output) ──
"$SCRIPT_DIR/sleep-guard.sh" "$CNAME" &
SLEEP_GUARD_PID=$!

# ── Run ──────────────────────────────────────────────────────
cleanup() {
    kill "$SLEEP_GUARD_PID" 2>/dev/null || true
    [ -n "$CCIGNORE_TMP" ] && rm -rf "$CCIGNORE_TMP"
    if [ -n "$FUSE_CNAME" ]; then
        docker stop "$FUSE_CNAME" >/dev/null 2>&1 || true
        docker rm -f "$FUSE_CNAME" >/dev/null 2>&1 || true
    fi
    if [ -n "$FUSE_SESSION_DIR" ]; then
        fusermount3 -u "$FUSE_SESSION_DIR/mnt" 2>/dev/null \
            || fusermount -u "$FUSE_SESSION_DIR/mnt" 2>/dev/null || true
        rm -rf "$FUSE_SESSION_DIR"
    fi
    [ "$FUSE_FAILED" = 1 ] || tput reset 2>/dev/null
}
trap cleanup EXIT

# Reset terminal so Claude's TUI starts with a clean screen
tput reset 2>/dev/null

# If args are claude flags (start with -), prepend the default command
# If no args, use default CMD; if first arg is a command (e.g. bash), pass through as-is
if [ $# -eq 0 ]; then
    docker run "${ARGS[@]}" "$IMAGE_NAME"
elif [[ "$1" == -* ]]; then
    docker run "${ARGS[@]}" "$IMAGE_NAME" claude --dangerously-skip-permissions "$@"
else
    docker run "${ARGS[@]}" "$IMAGE_NAME" "$@"
fi
