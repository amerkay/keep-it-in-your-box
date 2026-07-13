#!/usr/bin/env bash
# Sourced by `cc` — not a standalone script.
#
# Holds the self-contained subsystems: image build/update, the shared-CLAUDE.md
# sync, the .ccignore→.gitignore + pre-commit sync, and the two .ccignore
# redaction backends (FUSE sidecar, and the launch-time bind-mount fallback).
# `cc` itself keeps the launch flow: identity, locks, container lifecycle, exec.
#
# Runs in cc's shell, so it shares cc's `set -euo pipefail` and its globals:
#   SCRIPT_DIR IMAGE_NAME PWD CLAUDE_SHARED
#   FUSE_CNAME FUSE_ROOT MASK_ROOT FUSE_FAILED
#   PROJECT_MOUNT_SRC PROJECT_MOUNT_OPTS ARGS
#
# Several of those are *written* here and *read* back in cc, which shellcheck can't see
# across the source boundary — hence the file-wide SC2034 exemption.
# shellcheck disable=SC2034

BUILD_LOCK="$SCRIPT_DIR/build.lock"
BUILD_LOG="$SCRIPT_DIR/build.log"
BUILD_PID="$SCRIPT_DIR/build.pid"
CLAUDE_DIST_URL="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/latest"

# ── Messaging ────────────────────────────────────────────────────
# One argument per line, so a multi-line explanation stays readable at the call site.
# The `[ $# -gt 0 ]` guard matters: `printf '   %s\n'` with no arguments would still
# print the format once, adding a stray blank line to every single-line message.
die()  { printf '❌ cc: %s\n' "$1" >&2; shift; [ $# -gt 0 ] && printf '   %s\n' "$@" >&2; exit 1; }
warn() { printf '⚠️  cc: %s\n' "$1" >&2; shift; [ $# -gt 0 ] && printf '   %s\n' "$@" >&2; return 0; }

latest_claude_version() {
    curl -sf "$CLAUDE_DIST_URL" 2>/dev/null | tr -d '[:space:]' || true
}

# ── Image ────────────────────────────────────────────────────────
build_image_if_missing() {
    docker image inspect "$IMAGE_NAME" &>/dev/null && return 0
    echo "🔨 Building Claude Code image (first time, please wait)..." >&2
    local latest; latest="$(latest_claude_version)"
    docker build --build-arg CLAUDE_VERSION="${latest:-latest}" -t "$IMAGE_NAME" "$SCRIPT_DIR"
}

check_for_updates() {
    # Never unlink build.lock: build-bg.sh holds flock on that *inode*, so removing
    # it would let the next build lock a fresh one — two concurrent builds, both
    # truncating build.log and racing on `docker tag`. Test it in place instead;
    # flock creates the file if it is absent.
    if ! flock -n "$BUILD_LOCK" true 2>/dev/null; then
        local running; running="$(cat "$BUILD_PID" 2>/dev/null || true)"
        echo "🔨 Background image rebuild in progress... (log: $BUILD_LOG)" >&2
        [ -n "$running" ] && echo "   To cancel: kill -TERM -$running" >&2
        return 0
    fi

    echo "🔍 Checking for Claude Code updates..." >&2
    local installed latest
    installed="$(docker run --rm --entrypoint="" "$IMAGE_NAME" cat /etc/claude-code-version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    # Old images predate /etc/claude-code-version.
    [ -n "$installed" ] || installed="$(docker run --rm --entrypoint="" "$IMAGE_NAME" claude --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    latest="$(latest_claude_version)"
    echo "   Installed: ${installed:-unknown}" >&2
    echo "   Latest:    ${latest:-unknown}" >&2

    if [ -z "$latest" ] || { [ -n "$installed" ] && [ "$installed" = "$latest" ]; }; then
        echo "   ✓ Up to date" >&2
        return 0
    fi

    echo "⬆️  Claude Code update available: $installed → $latest" >&2
    # `|| answer=""`: read exits 1 on EOF, which under `set -e` would kill a
    # non-interactive run (`cc claude -p '…' < /dev/null`) before the session started.
    local answer=""
    read -rp "Rebuild image in background? [y/N] " answer || answer=""
    [[ "$answer" =~ ^[Yy]$ ]] || return 0
    # setsid: its own process group, so `kill -TERM -PGID` kills the whole build tree.
    setsid "$SCRIPT_DIR/build-bg.sh" &
    echo $! > "$BUILD_PID"
    disown
    echo "🔨 Starting background rebuild... (log: $BUILD_LOG)" >&2
    echo "   To cancel: kill -TERM -$(cat "$BUILD_PID")" >&2
}

# ── Shared sandbox policy (secrets hard-stop, .ccignore rules) ────
# Kept in a marker-delimited block at the top of the shared CLAUDE.md, so it always
# tracks this repo's shared-CLAUDE.md while anything the user (or Claude's `#`
# shortcut) writes below the block survives.
sync_shared_claude_md() {
    [ -f "$SCRIPT_DIR/shared-CLAUDE.md" ] || return 0
    local md="$CLAUDE_SHARED/CLAUDE.md" rest=""
    local b="<!-- >>> cc sandbox policy (auto-synced by cc — do not edit this block) >>> -->"
    local e="<!-- <<< cc sandbox policy (auto-synced by cc) <<< -->"

    [ -f "$md" ] && rest="$(awk -v b="$b" -v e="$e" '
        $0==b {skip=1; next} $0==e {skip=0; next} !skip {print}' "$md")"
    {
        printf '%s\n' "$b"
        cat "$SCRIPT_DIR/shared-CLAUDE.md"
        printf '%s\n' "$e"
        # `if`, not `[ -n "$rest" ] && printf`: an AND-list as the group's last command
        # makes the whole group exit 1 when rest is empty (no user memory yet), which
        # would skip the `&& mv` below and strand the .cc.tmp file.
        if [ -n "$rest" ]; then printf '%s\n' "$rest"; fi
    } > "$md.cc.tmp" && mv "$md.cc.tmp" "$md"
}

# ── .ccignore → .gitignore + host pre-commit guard ────────────────
# .ccignore hides sensitive paths from the container, but nothing stops git from
# committing them on the host — leaking their real contents into history and diffs.
# Two layers keep them out: .gitignore (blocks untracked files from being added) and
# a pre-commit hook (the real backstop — also catches already-tracked files).
# Both anchor at the git toplevel, so skip with a note when cc runs from a subdir.
sync_ccignore_gitignore() {
    [ -f "$PWD/.ccignore" ] || return 0
    local top; top="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$top" ] || return 0                       # not a git repo — nothing to sync
    if [ "$(realpath "$top" 2>/dev/null || echo "$top")" \
       != "$(realpath "$PWD" 2>/dev/null || echo "$PWD")" ]; then
        echo "ℹ️  .ccignore: launched from a subdir of the git repo; skipping" >&2
        echo "   .gitignore sync + pre-commit guard (they anchor at the repo root)." >&2
        return 0
    fi

    # Translate .ccignore rules to gitignore syntax: bare names match anywhere (as in
    # gitignore), '/'-containing rules anchor at the root. Leading-'/' and '..' rules
    # are unsafe and skipped, exactly as ccignore-fuse.py skips them.
    local patterns="" line neg
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"     # ltrim
        line="${line%"${line##*[![:space:]]}"}"     # rtrim
        # Detach a leading '!' so the anchoring '/' lands after it: `!/foo`, not `/!foo`
        # (which is a literal path starting with '!' and negates nothing). Reattached below.
        neg=""
        case "$line" in !*) neg="!"; line="${line#!}" ;; esac
        line="${line%/}"
        [ -z "$line" ] && continue
        case "$line" in /*) continue ;; esac
        case "/$line/" in */../*) continue ;; esac
        case "$line" in
            */*) patterns+="$neg/$line"$'\n' ;;
            *)   patterns+="$neg$line"$'\n' ;;
        esac
    done < "$PWD/.ccignore"

    local gi="$PWD/.gitignore" rest=""
    local b="# >>> ccignore (auto-synced by cc — do not edit this block) >>>"
    local e="# <<< ccignore (auto-synced by cc) <<<"
    [ -f "$gi" ] && rest="$(awk -v b="$b" -v e="$e" '
        $0==b {skip=1; next} $0==e {skip=0; next} !skip {print}' "$gi")"
    {
        [ -n "$rest" ] && printf '%s\n' "$rest"
        if [ -n "$patterns" ]; then
            printf '%s\n' "$b"
            printf '%s\n' "# Mirrors .ccignore so paths hidden from the sandbox are never committed."
            printf '%s' "$patterns"
            printf '%s\n' "$e"
        fi
    } > "$gi.cc.tmp" && mv "$gi.cc.tmp" "$gi"

    local hooks="$PWD/.git/hooks" hook="$PWD/.git/hooks/pre-commit"
    mkdir -p "$hooks"
    if [ -e "$hook" ] && ! grep -q "MARKER: ccignore-precommit" "$hook" 2>/dev/null; then
        warn ".ccignore: existing pre-commit hook at $hook; not overwriting." \
             "ccignored files may still be committable — merge the guard manually" \
             "from $SCRIPT_DIR/ccignore-precommit.py"
    elif ! cmp -s "$SCRIPT_DIR/ccignore-precommit.py" "$hook" 2>/dev/null; then
        cp "$SCRIPT_DIR/ccignore-precommit.py" "$hook" && chmod +x "$hook"
    fi
}

# ── Mount probing ────────────────────────────────────────────────
# Is anything mounted at $1? Ask the kernel directly. `mountpoint -q` is NOT usable:
# once the FUSE server dies, the mount stays in the mount table but every stat() on it
# returns ENOTCONN — so mountpoint reports "not a mountpoint" for a directory that very
# much still is one, and the unmount gets skipped.
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

# ── .ccignore redaction, primary: FUSE sidecar ───────────────────
# A redacting passthrough (ccignore-fuse.py) runs in its own container and is exposed to
# the main one through shared-mount propagation. Matched paths read as a stub and refuse
# writes — including files created *after* launch, which the bind-mount fallback cannot
# cover. Only the sidecar gets SYS_ADMIN + /dev/fuse; the main container keeps cap-drop=ALL.
start_fuse_sidecar() {
    [ -f "$PWD/.ccignore" ] || return 0

    # The scratch dir must propagate shared, or the sidecar's mount never becomes
    # visible to the main container through the host.
    local prop; prop="$(findmnt -no PROPAGATION --target /tmp 2>/dev/null || true)"
    if [[ "$prop" != *shared* ]]; then
        echo "⚠️  .ccignore: /tmp is not a shared mount ($prop); falling back to" >&2
        echo "   launch-time-only masking. Files created mid-session will NOT be masked." >&2
        return 0
    fi

    # 755 on both: the sidecar runs as our uid, but the main container traverses this
    # path as root before dropping privileges. (`-m` with `-p` would only apply to the
    # deepest dir, so set the modes explicitly.)
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
        rm -rf "$FUSE_ROOT"
        FUSE_FAILED=1
        echo "❌ .ccignore: could not start FUSE sidecar. Aborting." >&2
        exit 1
    fi

    local _
    for _ in $(seq 1 100); do                       # ≤5s for the mount to come live
        fuse_mounted "$FUSE_ROOT/mnt" && break
        sleep 0.05
    done
    if ! fuse_mounted "$FUSE_ROOT/mnt"; then
        echo "❌ .ccignore: FUSE sidecar failed to mount; sidecar logs:" >&2
        docker logs "$FUSE_CNAME" 2>&1 | sed 's/^/   /' >&2 || true
        docker rm -f "$FUSE_CNAME" >/dev/null 2>&1 || true
        rm -rf "$FUSE_ROOT"
        FUSE_FAILED=1
        # Never fall through to the leaky fallback: that would silently downgrade the
        # redaction the user asked for.
        echo "   Refusing to launch with leaky fallback masking. Aborting." >&2
        exit 1
    fi

    PROJECT_MOUNT_SRC="$FUSE_ROOT/mnt"
    PROJECT_MOUNT_OPTS=":rslave"
    echo "🛡️  .ccignore: FUSE redacting mount active (sidecar: $FUSE_CNAME)" >&2
}

# ── .ccignore redaction, fallback: launch-time bind mounts ───────
# Used only where the sidecar can't run (/tmp not a shared mount). Masks the paths that
# match *at launch* by bind-mounting a stub over each. Files created on the host after
# launch are NOT masked — hence it is the fallback, and cc allows only one session at a
# time in this mode (the masks are baked into `docker run` and can't be re-evaluated).
add_fallback_mask_args() {
    [ -f "$PWD/.ccignore" ] || return 0
    [ -z "$PROJECT_MOUNT_OPTS" ] || return 0        # FUSE is active; nothing to do

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

    [ "${#targets[@]}" -gt 0 ] || return 0

    # Shortest path first, then skip anything equal to or nested under an accepted path:
    # bind-mounting a child over a parent that is itself masked would be pointless, and
    # the ordering makes "already covered" a simple prefix test.
    local accepted=()
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
}
