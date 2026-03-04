#!/bin/sh
set -e

# Get host UID/GID from environment
HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"

# Ensure Claude is also available at the native per-user location.
ensure_user_local_claude() {
	ensure_user_local_claude_user_home="$1"
	ensure_user_local_claude_target="$ensure_user_local_claude_user_home/.local/bin/claude"
	ensure_user_local_claude_system_claude=""
	ensure_user_local_claude_system_claude=$(command -v claude 2>/dev/null || true)

	if [ -z "$ensure_user_local_claude_system_claude" ]; then
		return 0
	fi

	mkdir -p "$ensure_user_local_claude_user_home/.local/bin" 2>/dev/null || true

	if [ ! -e "$ensure_user_local_claude_target" ]; then
		ln -sf "$ensure_user_local_claude_system_claude" "$ensure_user_local_claude_target" 2>/dev/null || true
	fi
}

# If already running as the target user, just exec
if [ "$(id -u)" = "$HOST_UID" ]; then
	USER_HOME=$(getent passwd "$HOST_UID" | cut -d: -f6)
	if [ -z "$USER_HOME" ]; then
		echo "✗ Failed to resolve home directory for UID $HOST_UID" >&2
		exit 1
	fi
	if [ "$HOST_UID" = "0" ]; then
		echo "✗ Refusing to run tool command as root" >&2
		exit 1
	fi
	mkdir -p "$USER_HOME/.local/bin" "$USER_HOME/.local/share" "$USER_HOME/.config" "$USER_HOME/.cache" 2>/dev/null || true
	export HOME="$USER_HOME"
	export PATH="$USER_HOME/.local/bin:$PATH"
	ensure_user_local_claude "$USER_HOME"
	exec "$@"
fi

# Running as root, need to set up user
echo "▶ Setting up container user with UID:GID ${HOST_UID}:${HOST_GID}..."

# Create group if needed
if ! getent group "$HOST_GID" >/dev/null 2>&1; then
	groupadd -g "$HOST_GID" hostgroup
fi

# Handle user creation/modification
if ! id -u "$HOST_UID" >/dev/null 2>&1; then
	# Create new user (suppress UID range warning for macOS UIDs)
	UID_MIN=100 UID_MAX=65000 useradd -u "$HOST_UID" -g "$HOST_GID" -d /home/hostuser -s /bin/bash -m hostuser 2>/dev/null || useradd -u "$HOST_UID" -g "$HOST_GID" -d /home/hostuser -s /bin/bash -m hostuser
	USER_NAME="hostuser"
	USER_HOME="/home/hostuser"
else
	# User already exists
	USER_NAME=$(id -nu "$HOST_UID")
	USER_HOME=$(getent passwd "$HOST_UID" | cut -d: -f6)
fi

# Ensure home directory exists and has correct ownership (for all cases)
mkdir -p "$USER_HOME" 2>/dev/null || true
chown "$HOST_UID:$HOST_GID" "$USER_HOME" 2>/dev/null || true

# Ensure XDG_RUNTIME_DIR exists for Wayland clipboard access
if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
	mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
	chown "$HOST_UID:$HOST_GID" "$XDG_RUNTIME_DIR" 2>/dev/null || true
	chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
fi

# Create tmp directories used by Claude's sandbox (TMPDIR=/tmp/claude)
mkdir -p "/tmp/claude" "/tmp/claude-$HOST_UID" 2>/dev/null || true
chown "$HOST_UID:$HOST_GID" "/tmp/claude" "/tmp/claude-$HOST_UID" 2>/dev/null || true

# Create and fix ownership of common cache/config directories.
mkdir -p "$USER_HOME/.cache" "$USER_HOME/.config" "$USER_HOME/.local" "$USER_HOME/.local/bin" "$USER_HOME/.local/share" 2>/dev/null || true
chown -R "$HOST_UID:$HOST_GID" "$USER_HOME/.cache" "$USER_HOME/.config" "$USER_HOME/.local" 2>/dev/null || true
ensure_user_local_claude "$USER_HOME"
chown -h "$HOST_UID:$HOST_GID" "$USER_HOME/.local/bin/claude" 2>/dev/null || true

# Fix ownership of mounted claude config
if [ -d "$USER_HOME/.claude" ]; then
	mkdir -p "$USER_HOME/.claude/plugins/marketplaces" 2>/dev/null || true
	chown -R "$HOST_UID:$HOST_GID" "$USER_HOME/.claude" 2>/dev/null || true
fi
if [ -f "$USER_HOME/.claude.json" ]; then
	chown "$HOST_UID:$HOST_GID" "$USER_HOME/.claude.json" 2>/dev/null || true
fi

# Set up timezone if TZ environment variable is provided
if [ -n "$TZ" ]; then
	echo "▶ Setting timezone to: $TZ"
	if [ -f "/usr/share/zoneinfo/$TZ" ]; then
		ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
		echo "$TZ" >/etc/timezone
	else
		echo "⚠ Warning: Timezone $TZ not found, using system default"
	fi
fi

# Symlink host home path so Claude's project paths (keyed by absolute path) resolve
# This allows /resume to find conversations started on the host
if [ -n "${HOST_HOME:-}" ] && [ "$HOST_HOME" != "$USER_HOME" ] && [ ! -e "$HOST_HOME" ]; then
	ln -sf "$USER_HOME" "$HOST_HOME"
fi

# Set up environment for the target user
export HOME="$USER_HOME"
export PATH="$USER_HOME/.local/bin:${CCO_PREPEND_PATH:+$CCO_PREPEND_PATH:}$PATH"

# Switch to host project directory
cd "${HOST_PWD:-/workspace}"

# exec gosu preserves the TTY properly (unlike su -c which wraps in a subshell)
exec gosu "$HOST_UID:$HOST_GID" "$@"
