#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="claude-code-sandbox"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_LOCK="$SCRIPT_DIR/build.lock"
BUILD_LOG="$SCRIPT_DIR/build.log"
BUILD_PID="$SCRIPT_DIR/build.pid"

# ── Build image if missing (blocking — can't proceed without it) ─
if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    echo "🔨 Building Claude Code image (first time, please wait)..."
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
    echo "🔍 Checking for Claude Code updates..."
    INSTALLED_VERSION="$(docker run --rm --entrypoint="" "$IMAGE_NAME" cat /etc/claude-code-version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    # Fallback for old images without the version file
    if [ -z "$INSTALLED_VERSION" ]; then
        INSTALLED_VERSION="$(docker run --rm --entrypoint="" "$IMAGE_NAME" claude --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    fi
    LATEST_VERSION="$(curl -sf https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/latest 2>/dev/null | tr -d '[:space:]' || true)"
    echo "   Installed: ${INSTALLED_VERSION:-unknown}"
    echo "   Latest:    ${LATEST_VERSION:-unknown}"

    if [ -n "$LATEST_VERSION" ] && { [ -z "$INSTALLED_VERSION" ] || [ "$INSTALLED_VERSION" != "$LATEST_VERSION" ]; }; then
        echo "⬆️  Claude Code update available: $INSTALLED_VERSION → $LATEST_VERSION"
        read -rp "Rebuild image in background? [y/N] " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            # Background build in new process group (setsid) so kill -PGID kills entire tree
            setsid "$SCRIPT_DIR/build-bg.sh" &
            echo $! > "$BUILD_PID"
            disown
            echo "🔨 Starting background rebuild... (log: $BUILD_LOG)"
            echo "   To cancel: kill -TERM -$(cat "$BUILD_PID")"
        fi
    else
        echo "   ✓ Up to date"
    fi
else
    BUILD_RUNNING_PID="$(cat "$BUILD_PID" 2>/dev/null || true)"
    echo "🔨 Background image rebuild in progress... (log: $BUILD_LOG)"
    [ -n "$BUILD_RUNNING_PID" ] && echo "   To cancel: kill -TERM -$BUILD_RUNNING_PID"
fi

# ── Container name from project dir ──────────────────────────
CNAME="cc-$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')-$$"

# ── Docker args ──────────────────────────────────────────────
ARGS=(
    --rm -it
    --name "$CNAME"

    # Mount project at same path as host so Claude uses correct project config
    -v "$PWD:$PWD"

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

    # # Drop all capabilities, add back only what entrypoint needs for user setup + gosu
    # --cap-drop=ALL
    # --cap-add=SETUID
    # --cap-add=SETGID
    # --cap-add=CHOWN
    # --cap-add=DAC_OVERRIDE
    # --cap-add=FOWNER

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

# ── Run ──────────────────────────────────────────────────────
cleanup() { tput reset 2>/dev/null; }
trap cleanup EXIT
# If args are claude flags (start with -), prepend the default command
# If no args, use default CMD; if first arg is a command (e.g. bash), pass through as-is
if [ $# -eq 0 ]; then
    docker run "${ARGS[@]}" "$IMAGE_NAME"
elif [[ "$1" == -* ]]; then
    docker run "${ARGS[@]}" "$IMAGE_NAME" claude --dangerously-skip-permissions "$@"
else
    docker run "${ARGS[@]}" "$IMAGE_NAME" "$@"
fi
