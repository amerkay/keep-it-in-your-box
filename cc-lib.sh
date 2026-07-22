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
#   FUSE_CNAME FUSE_ROOT FUSE_FAILED
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

# ── Global-config pins (.claude.json) ────────────────────────────
# Keys Claude reads from its *global config* rather than settings.json. That file is
# per-project here, and claude-json.seed only lands on a project's FIRST run — so a pin
# added later never reaches a project that already exists. Re-assert them every launch.
#
# leftArrowOpensAgents=false: from a foreground session `←` means "background this
# session", not "go back". With a turn in flight it aborts the running Workflow and
# every subagent, then forks — and work with live agents is structurally non-carryable,
# so it is simply lost. It also mints a new session id per press, littering the resume
# list with empty title-only stubs. See CLAUDE.md "leftArrowOpensAgents".
#
# Writes only when a pin is actually missing or wrong, so the common attach path
# touches nothing: a concurrent session holds this file in memory and rewrites it
# wholesale, and we would rather lose the pin (re-applied next cold start) than clobber
# that session's state. Best-effort — a host without python3 just gets a warning.
pin_global_config() {
    local f="$1"
    [ -f "$f" ] || return 0
    command -v python3 >/dev/null 2>&1 || {
        warn "python3 not found on the host — cannot pin .claude.json keys."
        return 0
    }
    python3 - "$f" <<'PY' || warn "could not pin .claude.json keys (left it untouched)."
import json, os, sys, tempfile

PINS = {"leftArrowOpensAgents": False}

path = sys.argv[1]
try:
    with open(path) as fh:
        cfg = json.load(fh)
except (OSError, ValueError):
    sys.exit(1)                       # unreadable or not JSON: leave it well alone
if not isinstance(cfg, dict):
    sys.exit(1)
if all(cfg.get(k) == v for k, v in PINS.items()):
    sys.exit(0)                       # already pinned — no write, no clobber window
cfg.update(PINS)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".")   # same dir → atomic rename
try:
    with os.fdopen(fd, "w") as fh:
        json.dump(cfg, fh, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
except BaseException:
    os.unlink(tmp)
    raise
print("🔧 cc: pinned %s in .claude.json" % ", ".join(PINS), file=sys.stderr)
PY
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

# ── .ccignore redaction + host-config guard: FUSE sidecar ────────
# A redacting passthrough (ccignore-fuse.py) runs in its own container and is exposed to
# the main one through shared-mount propagation. Matched paths refuse writes — including
# files created *after* launch, which no bind mount can cover, and which is precisely
# what a nested `git init` or a mid-session clone relies on. Redacted paths also read as
# a stub. Only the sidecar gets SYS_ADMIN + /dev/fuse; the main container keeps
# cap-drop=ALL.
start_fuse_sidecar() {
    # Always on, even with no .ccignore: the sidecar also enforces global.ccignore,
    # the guard against writing files the *host* later executes (.git/config,
    # .git/hooks, .vscode/…). Gating it on .ccignore is what left every project
    # without one — this repo included — running as a raw bind mount with no
    # protection at all.

    # The scratch dir must propagate shared, or the sidecar's mount never becomes
    # visible to the main container through the host. There is no fallback: a
    # launch-time bind mask cannot cover files created mid-session (a repo cloned
    # into the project, a nested `git init`), which is exactly what the guard is
    # for. Same principle as the mount-failure abort below — never silently
    # downgrade a redaction the user is relying on.
    local prop; prop="$(findmnt -no PROPAGATION --target /tmp 2>/dev/null || true)"
    if [[ "$prop" != *shared* ]]; then
        FUSE_FAILED=1   # keep the EXIT trap's `tput reset` from wiping this message
        die "cc needs /tmp to be a shared mount for .ccignore redaction and the" \
            "host-config guard, but it is '${prop:-unknown}'. Fix it with:" \
            "  sudo mount --make-shared /tmp" \
            "To make that survive a reboot, add a systemd drop-in at" \
            "/etc/systemd/system/tmp.mount.d/shared.conf or mount it shared in fstab."
    fi

    # 755 on both: the sidecar runs as our uid, but the main container traverses this
    # path as root before dropping privileges. (`-m` with `-p` would only apply to the
    # deepest dir, so set the modes explicitly.)
    mkdir -p "$FUSE_ROOT/mnt"
    chmod 755 "$FUSE_ROOT" "$FUSE_ROOT/mnt"
    # An absent .ccignore is an empty rule set, not a reason to skip the sidecar.
    # The guard file is *not* copied here: it is mounted read-only straight from
    # $SCRIPT_DIR, so there is no second copy to keep in step and nothing for the
    # attach-time staleness check to compare.
    if [ -f "$PWD/.ccignore" ]; then
        cp "$PWD/.ccignore" "$FUSE_ROOT/patterns"
    else
        : > "$FUSE_ROOT/patterns"
    fi
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
        -v "$SCRIPT_DIR/global.ccignore:/usr/local/share/global.ccignore:ro" \
        "$IMAGE_NAME" \
        /usr/local/bin/ccignore-fuse.py \
            --src /src --mnt "$FUSE_ROOT/mnt" \
            --patterns-file "$FUSE_ROOT/patterns" \
            --guard-file /usr/local/share/global.ccignore >/dev/null; then
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
        echo "   Refusing to launch unprotected: without the sidecar neither .ccignore" >&2
        echo "   nor the host-config guard is enforced. Aborting." >&2
        exit 1
    fi

    PROJECT_MOUNT_SRC="$FUSE_ROOT/mnt"
    PROJECT_MOUNT_OPTS=":rslave"
    echo "🛡️  .ccignore: FUSE redacting mount active (sidecar: $FUSE_CNAME)" >&2
}

# Desktop alert — the one launch channel that survives claude's TUI clearing the screen a
# few milliseconds after cc prints to stderr. Best-effort: with no notify-send, or no desktop
# session (ssh, `cc … -p`), it's a silent no-op. urgency: normal (info) | critical (sticky).
notify() {
    local urgency="$1" title="$2" body="$3" icon=dialog-information
    [ "$urgency" = critical ] && icon=dialog-error
    command -v notify-send >/dev/null 2>&1 || return 0
    notify-send -u "$urgency" -i "$icon" "$title" "$body" 2>/dev/null || true
}

# ── DNS: follow the host's live resolver, without editing the host ───
# A long-lived container freezes /etc/resolv.conf at creation, so after the host switches wifi
# or attaches a VPN it keeps the *previous* network's nameserver — unreachable now — and every
# lookup in every attached session times out (routing stays fine; only DNS breaks).
#
# systemd-resolved writes the host's *real* per-link upstream nameservers to
# /run/systemd/resolve/resolv.conf and rewrites it (by atomic rename) on every network change.
# cc bind-mounts that directory read-only and runs a tiny in-container watcher (resolv-sync.sh)
# that copies the current upstreams into the container's /etc/resolv.conf whenever they change,
# so every attached session follows the host across wifi/VPN switches. The container talks DNS
# straight to those real upstreams — never to the host/gateway — which is also what makes this
# work behind a per-connection host firewall (e.g. Portmaster) that holds a relay's
# container->gateway:53 hop while permitting DNS to real servers.
#
# The *directory* is mounted, not the file: systemd-resolved swaps the file by rename, so a
# file bind-mount would pin the old inode and go stale, while a directory mount always resolves
# the current inode. Best-effort: no systemd-resolved (no /run/systemd/resolve/resolv.conf) →
# no mount, no watcher, and the container keeps Docker's default resolv.conf, frozen at
# creation — exactly the pre-fix behaviour, never worse.
RESOLV_SRC_DIR=/run/systemd/resolve                 # host dir systemd-resolved rewrites live
RESOLV_SRC_FILE="$RESOLV_SRC_DIR/resolv.conf"

host_has_resolved() { [ -r "$RESOLV_SRC_FILE" ]; }

# Bind-mount args (read-only) for the live resolver dir + the watcher script. Appended to the
# main container's `docker run` only when the host runs systemd-resolved; a no-op otherwise.
#
# The dir also holds systemd-resolved's Varlink control sockets (io.systemd.Resolve[.Monitor]).
# A read-only *mount* does NOT stop a connect(), and those sockets speak to the host daemon in
# the host's namespace — an unauthenticated connect can drive host-side resolution and dump the
# host's full DNS/interface topology (DumpDNSConfiguration), i.e. a live sandbox->host channel.
# So shadow each socket with /dev/null (an inert char device: connect() → ENOTSOCK), closing the
# channel while the dir mount still tracks resolv.conf across systemd-resolved's atomic renames.
# Nested-under-mount shadowing is fine: Docker applies mounts parent-first by destination depth.
add_resolv_sync_args() {
    host_has_resolved || return 0
    ARGS+=(
        -v "$RESOLV_SRC_DIR:/run/host-resolve:ro"
        -v "/dev/null:/run/host-resolve/io.systemd.Resolve:ro"
        -v "/dev/null:/run/host-resolve/io.systemd.Resolve.Monitor:ro"
        -v "$SCRIPT_DIR/resolv-sync.sh:/usr/local/bin/resolv-sync.sh:ro"
    )
}

# Start the in-container resolv.conf watcher once, right after the container is ready. Called
# only on the create path (under the boot lock), so exactly one watcher is started; it lives
# for the container's whole life — shared by every attached terminal — and is killed when the
# container is removed, so there is nothing to tear down. Run as root (uid 0, bypassing the
# entrypoint) because it writes /etc/resolv.conf, and detached (-d) because it loops forever.
# Reports through a desktop notification: claude's TUI wipes stderr milliseconds after launch.
start_resolv_sync() {
    if ! host_has_resolved; then
        echo "ℹ️  DNS: no systemd-resolved on this host — keeping Docker's default resolv.conf" >&2
        echo "   (frozen at creation; sessions won't follow a wifi/VPN change). See CLAUDE.md § DNS." >&2
        notify normal "cc · DNS not following the host" \
            "No systemd-resolved on this host, so the sandbox keeps Docker's default DNS and won't follow a network change."
        return 0
    fi
    if docker exec -u 0 -d "$CNAME" \
        sh /usr/local/bin/resolv-sync.sh /run/host-resolve/resolv.conf 2>/dev/null; then
        echo "🌐 DNS: syncing resolv.conf to the host live — follows wifi/VPN changes." >&2
        notify normal "cc · DNS is following the host live" \
            "This sandbox keeps its resolv.conf synced to the host's live upstreams and survives wifi/VPN changes."
    else
        echo "⚠️  DNS: could not start the resolv.conf watcher — DNS is frozen at creation." >&2
        notify critical "cc · DNS is NOT following the host" \
            "The resolv.conf watcher failed to start; sessions won't follow a wifi/VPN change. See CLAUDE.md § DNS."
    fi
    return 0
}
