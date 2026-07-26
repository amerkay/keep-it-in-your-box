#!/bin/sh
set -e

# Get host UID/GID from environment
HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"

# Fail-closed cap check. This container is created with no CAP_SYS_ADMIN at all — the redacted
# view is mounted by the FUSE sidecar, in its own container — so seeing it here means the launch
# path regressed to the shape where the agent could mount. Baked into the image, so a sandboxed
# session cannot edit it, and unconditional: refuse rather than run the agent cap-capable.
assert_no_sysadmin() {
    ans_bnd=$(awk '/^CapBnd:/{print $2}' /proc/self/status 2>/dev/null)
    [ -n "$ans_bnd" ] || return 0
    if [ $((0x$ans_bnd & 0x200000)) -ne 0 ]; then
        echo "✗ kib: refusing to run — CAP_SYS_ADMIN is in this session's bounding set." >&2
        echo "  The sandbox container is not supposed to have it at all; the redaction mount" >&2
        echo "  belongs to the sidecar. Aborting rather than run the agent with mount" >&2
        echo "  capability. (CapBnd=$ans_bnd)" >&2
        exit 1
    fi
}

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

# macOS clipboard bridge (KIB_CLIP_BRIDGE=1): install container-side shims that talk to the
# host pbpaste watcher over the /kib-clip spool. Reads (wl-paste / xclip -o) drop a request
# and read the response; writes (wl-copy / pbcopy / xclip without -o) leave a deny marker
# and fail — one-way by construction, mirroring the Wayland guard. Placed in /usr/local/bin
# (ahead of /usr/bin), so they shadow the real wl-clipboard, which has no socket here anyway.
install_clipboard_shims() {
    cat >/usr/local/bin/wl-paste <<'SHIM'
#!/bin/sh
# kib clipboard bridge — READ ONLY. Requests a selection from the host over /kib-clip.
DIR=/kib-clip
[ -d "$DIR" ] || exit 1
type=text
while [ $# -gt 0 ]; do
	# Both spellings: wl-paste uses -l/--list-types and --type, xclip -t/-target with a
	# TARGETS value for the same two questions. The xclip shim execs straight into here.
	case "$1" in
		-l | --list-types)      type=list ;;
		-t | -target | --type)
			# $2, not a shift-then-$1: `shift` is a special builtin, so a TRAILING -t left the
			# loop's own shift with nothing to take and dash aborted the shim outright (rc=2,
			# no request written, no output). One shift per iteration can never over-shift.
			case "${2:-}" in image/*) type=png ;; TARGETS) type=list ;; esac
			;;
		--type=image/*)         type=png ;;
		--type=TARGETS)         type=list ;;
	esac
	shift
done
id="$$.$(date +%s%N 2>/dev/null || date +%s)"
printf '%s\n' "$type" > "$DIR/req.$id"
# 10s, not 2: the host answers text with pbpaste (instant) but a png with osascript, whose
# cold start plus a large image routinely passed 2s — the read then returned empty and the
# paste silently produced nothing.
i=0
while [ ! -e "$DIR/done.$id" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
[ -e "$DIR/resp.$id" ] && cat "$DIR/resp.$id"
rm -f "$DIR/req.$id" "$DIR/resp.$id" "$DIR/done.$id" 2>/dev/null
SHIM

    cat >/usr/local/bin/xclip <<'SHIM'
#!/bin/sh
# kib clipboard bridge — xclip-compatible. `-o`/`-out` reads via the bridge; anything else
# is a write and is refused.
# "$@" is forwarded, not dropped: xclip asks for an image as `-t image/png -o`, and without
# the args wl-paste defaulted to text and returned the wrong selection entirely.
for a in "$@"; do case "$a" in -o | -out) exec /usr/local/bin/wl-paste "$@" ;; esac; done
DIR=/kib-clip
[ -d "$DIR" ] && : > "$DIR/deny.$$" 2>/dev/null
echo "kib: clipboard WRITE refused — the sandbox clipboard is read-only." >&2
exit 1
SHIM

    for w in wl-copy pbcopy; do
        cat >"/usr/local/bin/$w" <<'SHIM'
#!/bin/sh
# kib clipboard bridge — WRITE refused. A clipboard write is host code execution at the
# user's next paste, so it is blocked here exactly as the Wayland guard blocks it.
DIR=/kib-clip
[ -d "$DIR" ] && : > "$DIR/deny.$$" 2>/dev/null
echo "kib: clipboard WRITE refused — the sandbox clipboard is read-only." >&2
exit 1
SHIM
    done

    chmod +x /usr/local/bin/wl-paste /usr/local/bin/xclip \
        /usr/local/bin/wl-copy /usr/local/bin/pbcopy 2>/dev/null || true
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
    assert_no_sysadmin
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
    USER_HOME="/home/hostuser"
else
    # User already exists
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
# kib points Claude at two mounted dirs: CLAUDE_CONFIG_DIR (this project's private state —
# daemon, sessions, jobs, transcripts, history, .claude.json) and
# CLAUDE_SECURESTORAGE_CONFIG_DIR (the shared-assembly dir — login token + the shared assets
# nest-bound from canonical ~/.claude). Claude looks for shared assets only inside
# CLAUDE_CONFIG_DIR, hence the symlinks across. CLAUDE.md is NOT farmed here — kib assembles
# it (policy + user memory) straight into CLAUDE_CONFIG_DIR.
CLAUDE_SESSION_DIR="${CLAUDE_CONFIG_DIR:-}"
CLAUDE_SHARED_DIR="${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}"

if [ -n "$CLAUDE_SESSION_DIR" ] && [ -d "$CLAUDE_SHARED_DIR" ]; then
    mkdir -p "$CLAUDE_SESSION_DIR" 2>/dev/null || true
    # Skipped when plugins/ is mounted read-only, which is the default.
    if [ -w "$CLAUDE_SHARED_DIR/plugins" ]; then
        mkdir -p "$CLAUDE_SHARED_DIR/plugins/marketplaces" 2>/dev/null || true
    fi

    # Whole-file assets: one symlink each. CLAUDE.md is deliberately absent (see above).
    for entry in settings.json keybindings.json hooks; do
        src="$CLAUDE_SHARED_DIR/$entry"
        dst="$CLAUDE_SESSION_DIR/$entry"
        [ -e "$src" ] || continue
        # Claude rewrites settings.json atomically, replacing our symlink with a real file.
        # Fold that back into the shared copy before relinking so an in-session change is not
        # dropped — but only when genuinely newer, or we would revert another project's edit.
        # (`find -newer`, not `-nt`: this runs under dash.)
        if [ -f "$dst" ] && [ ! -L "$dst" ]; then
            # A read-only shared copy means this asset is deliberately not project-writable:
            # keep the local file as this project's override rather than deleting an edit we
            # cannot fold back.
            [ -w "$src" ] || continue
            if [ -n "$(find "$dst" -newer "$src" 2>/dev/null)" ]; then
                cp -p "$dst" "$src" 2>/dev/null || true
            fi
            rm -f "$dst" 2>/dev/null || true
        fi
        ln -sfn "$src" "$dst" 2>/dev/null || true
    done

    # Drop what we planted last start, deepest first, and rmdir what that empties — else an item
    # deleted from the shared dir lingers as a dangling mirror. Only links INTO the shared dir are
    # ours; a dir still holding project content refuses the rmdir. Bounded by the plant depth.
    prune_farm() { # $1 = per-project dir, $2 = depth
        for entry in "$1"/* "$1"/.*; do
            case "${entry##*/}" in . | ..) continue ;; esac # never recurse into the parent
            if [ -L "$entry" ]; then
                case "$(readlink "$entry" 2>/dev/null)" in
                    "$CLAUDE_SHARED_DIR"/*) rm -f "$entry" ;;
                esac
            elif [ "${2:-0}" -gt 0 ] && [ -d "$entry" ]; then
                (prune_farm "$entry" "$(($2 - 1))")
                rmdir "$entry" 2>/dev/null || true # refused while project content remains
            fi
        done
    }

    # Asset DIRECTORIES get a real per-project dir holding one symlink per shared item, not one
    # symlink to the shared dir: these mount read-only (a write there would auto-run in every
    # other project's next session), and a plain symlink makes `/agents`, skill authoring and
    # `/plugin install` fail outright. This way shared items still load and in-session creations
    # land in this project's dir. State FILES need no special case — a JSON writer's rename
    # replaces our symlink with a real local file, which this dir permits.
    # $3 is how many levels BELOW $2 stay real dirs instead of becoming symlinks; callers differ.
    farm_dir() {                  # $1 = shared source dir, $2 = per-project dir, $3 = depth (0)
        [ -L "$2" ] && rm -f "$2" # upgrade a farm built by an older kib
        # The per-project dir is created even with NO shared source: it is where in-session
        # authoring lands. Returning early left a user with no canonical commands/ with no
        # commands/ in the box either, so authoring one had nowhere to go.
        mkdir -p "$2" 2>/dev/null || true
        prune_farm "$2" "${3:-0}"
        [ -d "$1" ] || return 0

        for item in "$1"/*; do
            [ -e "$item" ] || continue # unmatched glob
            name="${item##*/}"
            # Recurse in a SUBSHELL: this runs under dash, where the loop variables above are
            # global, and a plain recursive call would clobber the caller's own iteration.
            if [ "${3:-0}" -gt 0 ] && [ -d "$item" ]; then
                (farm_dir "$item" "$2/$name" "$(($3 - 1))")
                continue
            fi
            [ -e "$2/$name" ] && continue # a local item of the same name wins
            ln -sfn "$item" "$2/$name" 2>/dev/null || true
        done
    }

    # A failed install strands its staging clone — hundreds of files every later start re-walks
    # and re-chowns. Safe here: container creation, so nothing can be mid-install.
    rm -rf "$CLAUDE_SESSION_DIR"/plugins/cache/temp_git_* 2>/dev/null || true

    for entry in plugins skills agents commands; do
        farm_dir "$CLAUDE_SHARED_DIR/$entry" "$CLAUDE_SESSION_DIR/$entry"
    done

    # Deeper where the installer writes: it renames onto cache/<marketplace>/<plugin>/<version>
    # and mkdirs data/<key>, and a symlink to the read-only shared dir refuses that — shallower,
    # the rename hit EROFS and the UI hung on "Installing…". marketplaces stays 0: git clones,
    # which no farm makes writable, so the installer re-clones per-project. (redaction-config-guard.md)
    farm_dir "$CLAUDE_SHARED_DIR/plugins/marketplaces" "$CLAUDE_SESSION_DIR/plugins/marketplaces"
    farm_dir "$CLAUDE_SHARED_DIR/plugins/cache" "$CLAUDE_SESSION_DIR/plugins/cache" 2
    farm_dir "$CLAUDE_SHARED_DIR/plugins/data" "$CLAUDE_SESSION_DIR/plugins/data" 1

    # The session dir belongs to one project, so no other container is walking it and this
    # chown cannot race. `-h` retags the symlinks above instead of dereferencing them into the
    # shared dir. Bounded at depth 5 because only the farm above is root-created and it plants
    # no deeper than plugins/cache/<marketplace>/<plugin>/<version>; unbounded it also walked
    # the plugin cache — 100k+ entries, ~0.1s on a Linux bind but ~30s over macOS virtiofs,
    # every second of it before the container reports ready. (macos.md)
    find "$CLAUDE_SESSION_DIR" -maxdepth 5 \
        -exec chown -h "$HOST_UID:$HOST_GID" {} + 2>/dev/null || true

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
    # The parent may not exist: macOS homes live under /Users, which a debian image has no
    # reason to have. A project UNDER $HOME gets it free — the $PWD bind's mountpoint creates
    # the whole chain, and this branch is then skipped — but one outside $HOME does not, and
    # `ln` would fail ENOENT with `set -e` killing PID 1: the container dying with no message.
    mkdir -p "$(dirname "$HOST_HOME")"
    ln -sf "$USER_HOME" "$HOST_HOME"
fi

# …and the same absolute host paths must resolve one level down. Claude's plugin state records
# them verbatim (installPath, installLocation), and those files are farmed from the READ-ONLY
# shared mount, so Claude cannot rewrite them to container paths. Without this alias every
# host-installed plugin dangles and its MCP servers silently never start — enabledPlugins true,
# nothing in /mcp.
#
# BOTH spellings, because which one Claude resolves depends on the block above: a project under
# $HOME gets $HOST_HOME as a REAL directory (the $PWD bind's mountpoint made it) and no symlink,
# so only $HOST_HOME/.claude resolves; one outside $HOME gets the symlink, and $USER_HOME is the
# reachable target. $USER_HOME also covers a host user already called `hostuser`.
for _h in "$USER_HOME" "${HOST_HOME:-}"; do
    if [ -n "$CLAUDE_SESSION_DIR" ] && [ -n "$_h" ] && [ -d "$_h" ] && [ ! -L "$_h" ] \
        && [ ! -e "$_h/.claude" ] && [ ! -L "$_h/.claude" ]; then
        ln -s "$CLAUDE_SESSION_DIR" "$_h/.claude" 2>/dev/null || true
        chown -h "$HOST_UID:$HOST_GID" "$_h/.claude" 2>/dev/null || true
    fi
done
unset _h

# Playwright's Chromium, parked where Puppeteer's `--channel stable` resolution looks. Still
# load-bearing after the shim below: a caller who passes their own `--channel` gets no
# `--executable-path` from us, and this is what that resolution then finds.
mkdir -p /opt/google/chrome 2>/dev/null || true
ln -sf "$(readlink -f /usr/local/bin/google-chrome-stable)" /opt/google/chrome/chrome 2>/dev/null || true

# npx shim: lets `chrome-devtools-mcp` launch a browser at all here. Chrome's sandbox needs an
# unprivileged user namespace, which --cap-drop=ALL + seccomp deny, so an unflagged launch dies
# with "Target.setDiscoverTargets: Target closed". (The rejected image-wide wrapper is in
# docs/design-notes/terminal-and-security.md.)
#
# In /usr/local/bin, ahead of /usr/bin, so it is container-only and the plugin's STOCK manifest
# keeps working across updates. Conservative: fires for that one package, and only appends what
# the caller did not pass, so a custom --executable-path/--channel/--browser-url still wins.
# KIB_CHROME_MCP_ARGS=0 disables it.
cat >/usr/local/bin/npx <<'NPXWRAPPER'
#!/bin/sh
# Find the real npx by walking PATH (no `which`: Debian is retiring it, and a bare `command -v`
# would just find this shim again). Fail loudly rather than exec'ing "".
real_npx=""
IFS=:
for d in $PATH; do
  [ -n "$d" ] || d=.
  if [ "$d/npx" != /usr/local/bin/npx ] && [ -x "$d/npx" ]; then real_npx="$d/npx"; break; fi
done
unset IFS
[ -n "$real_npx" ] || { echo "kib: npx shim found no real npx on PATH" >&2; exit 127; }

extra=""
if [ "${KIB_CHROME_MCP_ARGS:-1}" != 0 ]; then
  pkg=0 headless=0 exec_path=0 sandbox=0 stats=0 remote=0
  for arg in "$@"; do
    case "$arg" in
      # With or without @version, and npx's --package= form: a plugin bump that drops the
      # pin must not silently take Chrome down with it.
      chrome-devtools-mcp|chrome-devtools-mcp@*|--package=chrome-devtools-mcp|--package=chrome-devtools-mcp@*) pkg=1 ;;
      --headless|--headless=*) headless=1 ;;
      --executable-path|--executable-path=*|--channel|--channel=*) exec_path=1 ;;
      # Exactly the two flags we would add — NOT a glob on *sandbox*, which also matches
      # --chrome-arg=--disable-gpu-sandbox and would leave Chrome unable to start at all.
      --chrome-arg=--no-sandbox|--chrome-arg=--disable-setuid-sandbox) sandbox=1 ;;
      --usage-statistics|--usage-statistics=*|--no-usage-statistics) stats=1 ;;
      # Attaching to an already-running browser: our launch flags would be rejected as
      # conflicting options, so add nothing at all.
      --browser-url|--browser-url=*) remote=1 ;;
    esac
  done
  if [ "$pkg" = 1 ] && [ "$remote" = 0 ]; then
    [ "$headless" = 1 ] || extra="$extra --headless"
    [ "$exec_path" = 1 ] || extra="$extra --executable-path=/usr/local/bin/google-chrome-stable"
    [ "$sandbox" = 1 ] || extra="$extra --chrome-arg=--no-sandbox --chrome-arg=--disable-setuid-sandbox"
    [ "$stats" = 1 ] || extra="$extra --no-usage-statistics"
  fi
fi
# $extra unquoted on purpose — it is a word list built only from the space-free literals above.
exec "$real_npx" "$@" $extra
NPXWRAPPER
chmod +x /usr/local/bin/npx

# macOS clipboard bridge shims (once, at container creation — `docker exec` sessions take
# the already-target-user branch above and never reach here).
if [ "${KIB_CLIP_BRIDGE:-0}" = 1 ]; then
    install_clipboard_shims
fi

# Set up environment for the target user
export HOME="$USER_HOME"
export PATH="$USER_HOME/.local/bin:${KIB_PREPEND_PATH:+$KIB_PREPEND_PATH:}$PATH"

# Switch to the host project directory — which is the sidecar's redacted view, propagated in.
# kib refuses to start the container at all if that mount is not up, so there is nothing to
# check here.
cd "${HOST_PWD:-/workspace}"

# exec gosu preserves the TTY properly (unlike su -c which wraps in a subshell).
exec gosu "$HOST_UID:$HOST_GID" "$@"
