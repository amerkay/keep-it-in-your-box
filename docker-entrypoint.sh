#!/bin/sh
set -e

# Get host UID/GID from environment
HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"

# Ensure Claude is also available at the native per-user location.
# POSIX sh has no `local`, so the variables are prefixed to avoid clobbering the caller's.
ensure_user_local_claude() {
	eulc_home="$1"
	eulc_target="$eulc_home/.local/bin/claude"
	eulc_claude="$(command -v claude 2>/dev/null || true)"

	[ -n "$eulc_claude" ] || return 0

	mkdir -p "$eulc_home/.local/bin" 2>/dev/null || true
	if [ ! -e "$eulc_target" ]; then
		ln -sf "$eulc_claude" "$eulc_target" 2>/dev/null || true
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
# cc points Claude at two mounted dirs: CLAUDE_CONFIG_DIR (this project's private state
# — daemon, sessions, jobs, transcripts, history, .claude.json) and
# CLAUDE_SECURESTORAGE_CONFIG_DIR (shared across every project — the login token).
# The shared dir also holds the assets that *should* be common (settings, plugins,
# skills, agents, commands, hooks, CLAUDE.md), but Claude only looks for those inside
# CLAUDE_CONFIG_DIR — so symlink them across, making both true at once.
CLAUDE_SESSION_DIR="${CLAUDE_CONFIG_DIR:-}"
CLAUDE_SHARED_DIR="${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}"

if [ -n "$CLAUDE_SESSION_DIR" ] && [ -d "$CLAUDE_SHARED_DIR" ]; then
	mkdir -p "$CLAUDE_SESSION_DIR" 2>/dev/null || true
	# Skipped when cc has mounted plugins/ read-only, which is the default.
	if [ -w "$CLAUDE_SHARED_DIR/plugins" ]; then
		mkdir -p "$CLAUDE_SHARED_DIR/plugins/marketplaces" 2>/dev/null || true
	fi

	# Whole-file assets: one symlink each, as before.
	for entry in settings.json keybindings.json CLAUDE.md hooks; do
		src="$CLAUDE_SHARED_DIR/$entry"
		dst="$CLAUDE_SESSION_DIR/$entry"
		[ -e "$src" ] || continue
		# Claude rewrites settings.json atomically (temp file + rename), replacing our
		# symlink with a real file. Fold that edit back into the shared copy before
		# relinking, so an in-session settings change isn't dropped — but only when it
		# really is newer, or we'd revert a change another project made through the
		# shared file meanwhile. (`find -newer`, not `-nt`: this runs under dash.)
		if [ -f "$dst" ] && [ ! -L "$dst" ]; then
			# A read-only shared copy (cc's default) means this asset is deliberately
			# not project-writable: keep the local file as this project's override
			# rather than deleting an edit we cannot fold back.
			[ -w "$src" ] || continue
			if [ -n "$(find "$dst" -newer "$src" 2>/dev/null)" ]; then
				cp -p "$dst" "$src" 2>/dev/null || true
			fi
			rm -f "$dst" 2>/dev/null || true
		fi
		ln -sfn "$src" "$dst" 2>/dev/null || true
	done

	# Asset *directories*: a real per-project dir holding one symlink per shared item,
	# instead of one symlink to the shared dir. cc mounts these read-only (a write there
	# would auto-run in every other project's next session), and a plain symlink would
	# make `/agents`, skill authoring and `/plugin install` fail outright. This way shared
	# items still load, and anything created in-session lands in this project's own dir
	# and works immediately — it simply doesn't follow you to other projects.
	#
	# State *files* need no special case: a JSON writer does temp-file + rename, and the
	# rename replaces our symlink with a real local file, which this dir permits.
	farm_dir() {   # $1 = shared source dir, $2 = per-project dir
		[ -d "$1" ] || return 0
		[ -L "$2" ] && rm -f "$2"               # upgrade a farm built by an older cc
		mkdir -p "$2" 2>/dev/null || true

		# Drop our own links first, so an item deleted from the shared dir since the last
		# launch doesn't linger as a dangling link. Only links *into* the shared dir are
		# ours; real files and dirs are this project's and are never touched.
		for link in "$2"/* "$2"/.*; do
			[ -L "$link" ] || continue
			case "$(readlink "$link" 2>/dev/null)" in
				"$CLAUDE_SHARED_DIR"/*) rm -f "$link" ;;
			esac
		done

		for item in "$1"/*; do
			[ -e "$item" ] || continue          # unmatched glob
			name="${item##*/}"
			[ -e "$2/$name" ] && continue       # a local item of the same name wins
			ln -sfn "$item" "$2/$name" 2>/dev/null || true
		done
	}

	for entry in plugins skills agents commands; do
		farm_dir "$CLAUDE_SHARED_DIR/$entry" "$CLAUDE_SESSION_DIR/$entry"
	done

	# One level deeper for the plugin installer's working dirs. Without this a per-project
	# `/plugin install` fails: the state JSONs update fine (rename replaces their symlink),
	# but cloning a marketplace or unpacking a plugin needs to mkdir *inside* these, and a
	# symlink to the read-only shared dir refuses that.
	for entry in marketplaces cache data; do
		farm_dir "$CLAUDE_SHARED_DIR/plugins/$entry" "$CLAUDE_SESSION_DIR/plugins/$entry"
	done

	# The session dir belongs to one project, so no other container is walking it and this
	# recursive chown cannot race. `-h` retags the symlinks above instead of dereferencing
	# them into the shared dir.
	chown -Rh "$HOST_UID:$HOST_GID" "$CLAUDE_SESSION_DIR" 2>/dev/null || true

	# The shared dir IS touched by every container, so only fix it when the owner actually
	# differs — normally it doesn't, the container user being the host user. (Chowning it
	# unconditionally made two containers starting at once race on the same inodes.)
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
