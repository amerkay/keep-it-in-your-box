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
echo "▶ Setting up container user with UID:GID ${HOST_UID}:${HOST_GID}..." >/dev/null

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

# ── Claude config: per-project session dir + shared assets ────────────────
# cc mounts two dirs and points Claude at them:
#   CLAUDE_CONFIG_DIR            → this project's private state (daemon, sessions,
#                                  jobs, transcripts, history, .claude.json)
#   CLAUDE_SECURESTORAGE_CONFIG_DIR → shared across every project (login token)
# The shared dir also holds the assets that *should* be common — settings, plugins,
# skills, agents, commands, hooks, CLAUDE.md — which Claude only looks for inside
# CLAUDE_CONFIG_DIR. Symlink them across so both are true at once.
CLAUDE_SESSION_DIR="${CLAUDE_CONFIG_DIR:-}"
CLAUDE_SHARED_DIR="${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}"

if [ -n "$CLAUDE_SESSION_DIR" ] && [ -d "$CLAUDE_SHARED_DIR" ]; then
	mkdir -p "$CLAUDE_SESSION_DIR" "$CLAUDE_SHARED_DIR/plugins/marketplaces" 2>/dev/null || true

	for entry in plugins skills agents commands hooks settings.json keybindings.json CLAUDE.md; do
		src="$CLAUDE_SHARED_DIR/$entry"
		dst="$CLAUDE_SESSION_DIR/$entry"
		[ -e "$src" ] || continue
		# Claude writes settings.json atomically (temp file + rename), which replaces
		# our symlink with a real file. Fold that edit back into the shared copy
		# before relinking, so a setting changed in-session isn't silently dropped —
		# but only if it really is newer, or we'd revert a change another project
		# made through the shared file in the meantime. (`find -newer`, not `-nt`:
		# this runs under dash.)
		if [ -f "$dst" ] && [ ! -L "$dst" ]; then
			if [ -n "$(find "$dst" -newer "$src" 2>/dev/null)" ]; then
				cp -p "$dst" "$src" 2>/dev/null || true
			fi
			rm -f "$dst" 2>/dev/null || true
		fi
		ln -sfn "$src" "$dst" 2>/dev/null || true
	done

	# The session dir belongs to one project, so no other container is walking it —
	# a recursive chown here cannot race. (The old code chowned the whole shared
	# tree on every launch; two containers starting at once raced on the same
	# inodes.) -h so it retags the symlinks above instead of dereferencing them
	# into the shared dir.
	chown -Rh "$HOST_UID:$HOST_GID" "$CLAUDE_SESSION_DIR" 2>/dev/null || true

	# The shared dir IS touched by every container, so only fix it when the owner
	# actually differs — normally it doesn't, since the container user is the host user.
	if [ "$(stat -c %u "$CLAUDE_SHARED_DIR" 2>/dev/null || echo "$HOST_UID")" != "$HOST_UID" ]; then
		chown -Rh "$HOST_UID:$HOST_GID" "$CLAUDE_SHARED_DIR" 2>/dev/null || true
	fi
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

# Symlink Playwright's Chromium to where Chrome DevTools MCP expects stable Chrome
mkdir -p /opt/google/chrome 2>/dev/null || true
ln -sf "$(readlink -f /usr/local/bin/google-chrome-stable)" /opt/google/chrome/chrome 2>/dev/null || true

# npx wrapper: adds Docker-compatible flags when Chrome DevTools MCP is invoked.
# Lives in /usr/local/bin (before /usr/bin in PATH) so it's container-only,
# doesn't touch host-mounted plugin configs, and survives plugin updates.
cat > /usr/local/bin/npx << 'NPXWRAPPER'
#!/bin/sh
real_npx="$(which -a npx | grep -v /usr/local/bin/npx | head -1)"
for arg in "$@"; do
  case "$arg" in chrome-devtools-mcp@*)
    exec "$real_npx" "$@" --headless --executable-path=/usr/local/bin/google-chrome-stable --chrome-arg=--no-sandbox --chrome-arg=--disable-setuid-sandbox --no-usage-statistics
    ;;
  esac
done
exec "$real_npx" "$@"
NPXWRAPPER
chmod +x /usr/local/bin/npx

# Set up environment for the target user
export HOME="$USER_HOME"
export PATH="$USER_HOME/.local/bin:${CCO_PREPEND_PATH:+$CCO_PREPEND_PATH:}$PATH"

# Switch to host project directory
cd "${HOST_PWD:-/workspace}"

# exec gosu preserves the TTY properly (unlike su -c which wraps in a subshell)
exec gosu "$HOST_UID:$HOST_GID" "$@"
