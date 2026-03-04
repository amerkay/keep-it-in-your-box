#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="claude-code-sandbox"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Build image if missing ───────────────────────────────────
if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    echo "🔨 Building Claude Code image..."
    docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
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

    # Bubblewrap runs in weaker nested mode (enableWeakerNestedSandbox in settings.json)
    # Custom seccomp: Docker default + user namespaces + mount/umount2 (safe without CAP_SYS_ADMIN)
    --security-opt seccomp="$SCRIPT_DIR/seccomp.json"
    # AppArmor unconfined: required for bwrap bind mounts inside user namespaces
    # No CAP_SYS_ADMIN means mount() only works inside unprivileged user namespaces
    --security-opt apparmor=unconfined

    # Bridge network (Docker isolation) + Claude's built-in sandbox (domain allowlist)
    # Use --add-host to allow access to host dev servers if needed
    --add-host=host.docker.internal:host-gateway

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
exec docker run "${ARGS[@]}" "$IMAGE_NAME" "$@"
