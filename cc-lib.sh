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
    if ! lock_fd -n "$BUILD_LOCK" true 2>/dev/null; then
        local running; running="$(cat "$BUILD_PID" 2>/dev/null || true)"
        echo "🔨 Background image rebuild in progress... (log: $BUILD_LOG)" >&2
        [ -n "$running" ] && echo "   To cancel: kill -TERM -$running" >&2
        return 0
    fi

    echo "🔍 Checking for Claude Code updates..." >&2
    local installed latest
    installed="$(docker run --rm --entrypoint="" "$IMAGE_NAME" cat /etc/claude-code-version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    # Old images predate /etc/claude-code-version.
    [ -n "$installed" ] || installed="$(docker run --rm --entrypoint="" "$IMAGE_NAME" claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
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
    # Its own process group, so `kill -TERM -PGID` kills the whole build tree.
    detach_pgrp "$SCRIPT_DIR/build-bg.sh"
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

# ── Shared settings.json: refuse host-reaching keys ───────────────
# ~/.claude-shared/settings.json is symlinked into EVERY project and the entrypoint folds
# in-session edits back into it, so one poisoned session reaches every other project's next
# session (audit H5). The file has to stay writable — /config and theme changes are normal
# — so the control lives here instead: cc runs on the host, before any container reads it,
# on both the create and the attach path.
#
# Refused are the key classes whose value is a command the agent runs, or which redirect
# auth traffic. Inline hooks[].command is the one that matters most: it is exactly how a
# poisoned settings.json bypasses the read-only hooks/ directory, the same way
# core.hooksPath bypassed a read-only .git/hooks.
#
# Prevention at launch, not at write: a poisoned file is caught before the *next* session
# loads it, which is the propagation step. Broken JSON warns rather than refuses (Claude
# ignores an unparseable settings file anyway); an unreadable one fails closed.
validate_shared_settings() {
    local f="$CLAUDE_SHARED/settings.json"
    [ -e "$f" ] || return 0
    command -v python3 >/dev/null 2>&1 || {
        warn "python3 not found on the host — cannot validate the shared settings.json."
        return 0
    }
    local bad
    bad="$(python3 - "$f" <<'PY'
import json, sys

# key path -> why it is refused
COMMAND_KEYS = ("apiKeyHelper", "awsAuthRefresh", "awsCredentialExport",
                "otelHeadersHelper")
ENV_KEYS = ("ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN")

try:
    with open(sys.argv[1]) as fh:
        cfg = json.load(fh)
except ValueError:
    sys.exit(3)                      # not JSON — warn, don't block
except OSError:
    sys.exit(4)                      # unreadable — fail closed
if not isinstance(cfg, dict):
    sys.exit(3)

bad = []
for k in COMMAND_KEYS:
    if cfg.get(k):
        bad.append("%s = %s" % (k, cfg[k]))
env = cfg.get("env")
if isinstance(env, dict):
    for k in ENV_KEYS:
        if env.get(k):
            bad.append("env.%s = %s" % (k, env[k]))
sl = cfg.get("statusLine")
if isinstance(sl, dict) and sl.get("command"):
    bad.append("statusLine.command = %s" % sl["command"])
# hooks: {"PreToolUse": [{"hooks": [{"command": "..."}]}]} — an inline command here runs
# without ever touching the read-only hooks/ directory.
hooks = cfg.get("hooks")
if isinstance(hooks, dict):
    for event, matchers in hooks.items():
        for m in matchers if isinstance(matchers, list) else []:
            for h in (m.get("hooks") or []) if isinstance(m, dict) else []:
                if isinstance(h, dict) and h.get("command"):
                    bad.append("hooks.%s[].command = %s" % (event, h["command"]))
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
)" && return 0

    case "$?" in
        3) warn "~/.claude-shared/settings.json is not valid JSON — skipping validation." \
                "Claude ignores an unparseable settings file, so this is not fatal."
           return 0 ;;
        4) die "cannot read ~/.claude-shared/settings.json. Refusing to launch:" \
               "an unreadable shared settings file cannot be checked for keys that" \
               "run commands on your behalf." ;;
    esac

    printf '\n' >&2
    die "~/.claude-shared/settings.json contains a key that runs a command or" \
        "redirects your credentials:" \
        "" \
        "$(printf '%s\n' "$bad" | sed 's/^/    /')" \
        "" \
        "A sandboxed session can write this file, and it loads in EVERY project." \
        "Remove the key, then relaunch:" \
        "    \$EDITOR ~/.claude-shared/settings.json"
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

# ── .ccignore redaction + host-config guard: the mode interface ──
# The redacting passthrough (ccignore-fuse.py) is served two ways, chosen once by
# CC_FUSE_MODE (see cc-portable.sh). Both share the *same* Python server, matcher,
# guard file and stale-rules refusal — only the topology differs:
#
#   sidecar (Linux): the server runs in its own cap-drop=ALL container and reaches
#     the main container through shared-mount propagation. Strongest isolation.
#   single (macOS / CC_SINGLE_CONTAINER=1): no propagation is available, so the
#     server runs inside the one project container. It is started by the trusted
#     entrypoint (entrypoint-fuse.sh) which mounts the view, drops SYS_ADMIN from
#     the bounding set, then gosu's to the capless agent. See "macOS (Plan H)".
#
# cc calls only the three interface functions; each dispatches on CC_FUSE_MODE.
prepare_redaction() {
    if [ "$CC_FUSE_MODE" = single ]; then _prepare_redaction_single; else _prepare_redaction_sidecar; fi
}
verify_redaction_attach() {
    if [ "$CC_FUSE_MODE" = single ]; then _verify_redaction_attach_single; else _verify_redaction_attach_sidecar; fi
}
teardown_redaction() {
    if [ "$CC_FUSE_MODE" = single ]; then _teardown_redaction_single; else _teardown_redaction_sidecar; fi
}

# ── single-container mode ─────────────────────────────────────────
# No sidecar, no host-side mount, no propagation. cc only stages the rules and adds
# the flags the entrypoint needs; entrypoint-fuse.sh does the mount in-container.
_prepare_redaction_single() {
    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
    # The rule set the entrypoint mounts read-only at /cc/patterns. Kept in $STATE_DIR
    # (host-only) so the sandbox can't edit what redaction is validated against, and so
    # the attach-time staleness check has a stable copy to compare against — exactly the
    # role $FUSE_ROOT/patterns plays for the sidecar.
    if [ -f "$PWD/.ccignore" ]; then cp "$PWD/.ccignore" "$PATTERNS_STATE"; else : > "$PATTERNS_STATE"; fi
    chmod 644 "$PATTERNS_STATE"

    # NO -v for $PWD: the entrypoint mounts the redacted view there. The real project is
    # exposed at /cc/real (under a root-700 parent the agent can't traverse), the server
    # and guard read-only. SYS_ADMIN + /dev/fuse exist only until the mount is up; SETPCAP
    # lets the entrypoint then drop SYS_ADMIN (and itself) from the bounding set before the
    # agent runs, so the agent tree is provably not SYS_ADMIN-capable. apparmor is
    # unconfined for the mount (docker-default denies it) — preflight proved the engine
    # accepts the flag.
    REDACTION_ARGS=(
        -v "$PWD:/cc/real"
        -v "$PATTERNS_STATE:/cc/patterns:ro"
        -v "$SCRIPT_DIR/ccignore-fuse.py:/usr/local/bin/ccignore-fuse.py:ro"
        -v "$SCRIPT_DIR/global.ccignore:/usr/local/share/global.ccignore:ro"
        --cap-add=SYS_ADMIN
        --cap-add=SETPCAP
        --device /dev/fuse
        --security-opt apparmor=unconfined
        -e CC_FUSE_INTERNAL=1
        -e CC_FUSE_MNT="$PWD"
    )
    PROJECT_MOUNT_SRC=""     # signal start_container to add no $PWD bind
    echo "🛡️  .ccignore: single-container FUSE redaction (mounted in-container at $PWD)" >&2
}

# Mount alive (a fuse fs at $PWD in the container) + rules unchanged since creation.
# The mountpoint is compared after readlink -f *inside* the container: the entrypoint's
# HOST_HOME symlink (e.g. /Users/kay → /home/hostuser) means the kernel records the mount
# under its resolved path, so a raw string compare against $PWD would spuriously fail.
_verify_redaction_attach_single() {
    if ! docker exec "$CNAME" sh -c '
        p=$(readlink -f "$1" 2>/dev/null || echo "$1")
        while read -r _dev _mp _fstype _rest; do
            [ "$_mp" = "$p" ] || continue
            case "$_fstype" in fuse*) exit 0 ;; esac
        done < /proc/self/mounts
        exit 1
    ' _ "$PWD" 2>/dev/null; then
        die "this project's container has no redaction mount at $PWD, so neither" \
            ".ccignore nor the host-config guard is being enforced in it." \
            "Refusing to attach — close all cc sessions for this project and relaunch." \
            "(A container created by an older cc will always land here.)"
    fi
    if ! cmp -s "$PWD/.ccignore" "$PATTERNS_STATE" 2>/dev/null \
       && ! { [ ! -f "$PWD/.ccignore" ] && [ ! -s "$PATTERNS_STATE" ]; }; then
        die ".ccignore changed since this project's container started." \
            "The running redaction layer still enforces the OLD rules. Refusing to" \
            "attach — close all cc sessions for this project and relaunch."
    fi
}

# The mount died with the container; only the host state file remains.
_teardown_redaction_single() {
    rm -f "$PATTERNS_STATE" 2>/dev/null || true
}

# ── sidecar mode ─────────────────────────────────────────────────
# A redacting passthrough (ccignore-fuse.py) runs in its own container and is exposed to
# the main one through shared-mount propagation. Matched paths refuse writes — including
# files created *after* launch, which no bind mount can cover, and which is precisely
# what a nested `git init` or a mid-session clone relies on. Redacted paths also read as
# a stub. Only the sidecar gets SYS_ADMIN + /dev/fuse; the main container keeps
# cap-drop=ALL.
_prepare_redaction_sidecar() {
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

# The sidecar is unconditional, so its absence is always an error (that is also what a
# container created by an older cc looks like) — without it there is no host-config guard
# either. Only the project's .ccignore can go stale; global.ccignore is mounted read-only
# from $SCRIPT_DIR, so the sidecar and this process read the very same file.
_verify_redaction_attach_sidecar() {
    if ! sidecar_running; then
        die "this project's container was started without the redaction sidecar, so" \
            "neither .ccignore nor the host-config guard is being enforced in it." \
            "Refusing to attach — close all cc sessions for this project and relaunch." \
            "(A container created by an older cc will always land here.)"
    fi
    if ! cmp -s "${PWD}/.ccignore" "$FUSE_ROOT/patterns" 2>/dev/null \
       && ! { [ ! -f "$PWD/.ccignore" ] && [ ! -s "$FUSE_ROOT/patterns" ]; }; then
        die ".ccignore changed since this project's container started." \
            "The running redaction layer still enforces the OLD rules. Refusing to" \
            "attach — close all cc sessions for this project and relaunch."
    fi
}

# Unmount BEFORE removing the sidecar. The other order kills the FUSE server first,
# leaving a mounted-but-ENOTCONN mount that `mountpoint -q` reports as "not a mountpoint"
# — so the unmount is skipped, the mount is orphaned on *every* exit, and the next launch
# of this project dies on the rm below.
_teardown_redaction_sidecar() {
    if ! unmount_fuse "$FUSE_ROOT/mnt"; then
        die "a .ccignore redaction mount is still mounted at" \
            "  $FUSE_ROOT/mnt" \
            "and could not be unmounted. Refusing to delete it: that path is a" \
            "passthrough view of your project, so removing it while mounted would" \
            "delete the real files. Clear it by hand, then relaunch:" \
            "  fusermount3 -u '$FUSE_ROOT/mnt' || sudo umount -l '$FUSE_ROOT/mnt'"
    fi
    docker rm -f "$FUSE_CNAME" >/dev/null 2>&1 || true
    # `|| true`: never let a failed cleanup kill cc under `set -e` — least of all from the
    # EXIT trap, where it would also overwrite the session's exit code.
    rm -rf "$FUSE_ROOT" 2>/dev/null || true
}

# Desktop alert — the one launch channel that survives claude's TUI clearing the screen a
# few milliseconds after cc prints to stderr. Reserved for *problems*: a launch that works
# notifies nothing, so any popup means something needs the user. Best-effort: with no
# notifier, or no desktop session (ssh, `cc … -p`), it's a silent no-op.
# urgency: normal (degraded) | critical (sticky). notify_desktop (cc-portable.sh) maps
# urgency→icon on Linux and routes to osascript on macOS.
notify() { notify_desktop "$1" "$2" "$3"; }

# ── Clipboard: mediate Wayland instead of handing over the socket ─
# The host compositor socket used to be bind-mounted into the main container read-write and
# unmediated. It is there for one job — pasting an image *from* the host clipboard — but the
# raw socket also grants clipboard *writes*, and a write is host code execution at your next
# terminal paste (an embedded ESC[201~ ends bracketed paste early, so the remainder is
# interpreted as typed input). Audit H8.
#
# So the main container never sees the real socket. A sidecar runs wayland-guard.py, which
# relays the protocol, forwards reads verbatim, and refuses every selection-setting request.
# Host-side terminal select+copy is unaffected: your terminal emulator is a host client and
# never comes through here.
#
# Fail-soft, unlike the FUSE sidecar: no Wayland, or a proxy that won't start, means no
# socket is mounted at all. Absent Wayland is not a security hole (you lose image paste), so
# aborting the launch would be wrong — falling back to the raw socket would be.
WL_HOST_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY:-wayland-0}"

host_has_wayland() { [ -S "$WL_HOST_SOCK" ]; }

# Mount args for the main container — only the *proxied* socket, never the real one. Always
# exposed as wayland-0 inside, whatever the host display is called.
add_wayland_args() {
    [ -S "$WL_ROOT/wayland-0" ] || return 0
    ARGS+=(
        -e XDG_RUNTIME_DIR="/run/user/$(id -u)"
        -e WAYLAND_DISPLAY=wayland-0
        -v "$WL_ROOT/wayland-0:/run/user/$(id -u)/wayland-0"
    )
}

# Turn a denial logged by the proxy into a desktop notification. The sidecar has no desktop
# session, so the alert has to be raised here. setsid + the pid file so teardown can kill the
# whole pipeline by process group (a plain kill would leave `docker logs -f` running).
# Rate-limited to one per 30s: a loop calling wl-copy must not be able to spam the desktop.
#
# 200>&- 201>&- is LOAD-BEARING, exactly as it is for sleep-guard.sh: this follower outlives
# the cc that started it (it runs for the container's whole life). Inheriting the project's
# shared lock on fd 200 means the last terminal out can never take that lock *exclusively*,
# so teardown_container never runs and the container — with its sidecars — is stranded until
# a manual `docker rm -f`. Shipped that way once; it left containers running for every
# project whose sessions had all been closed.
start_wayland_notifier() {
    command -v notify-send >/dev/null 2>&1 || return 0
    setsid sh -c '
        last=0
        docker logs -f "$1" 2>&1 | while IFS= read -r line; do
            case "$line" in WLGUARD-DENY*) ;; *) continue ;; esac
            now=$(date +%s)
            [ $((now - last)) -lt 30 ] && continue
            last=$now
            notify-send -u critical -i dialog-error "cc · clipboard write blocked" "$2" || true
        done' _ "$WL_CNAME" \
        "The sandbox tried to write your clipboard. Blocked — your next paste is safe. Project: $(basename "$PWD")" \
        >/dev/null 2>&1 200>&- 201>&- &
    echo $! > "$WL_ROOT/notify.pid"
}

start_wayland_guard() {
    if ! host_has_wayland; then
        echo "ℹ️  clipboard: no Wayland socket on this host — image paste unavailable." >&2
        return 0
    fi
    mkdir -p "$WL_ROOT"
    chmod 755 "$WL_ROOT"          # the main container traverses this as root before gosu

    # The real socket is mounted read-only: that does not stop a connect() (see the Varlink
    # note below), which is exactly what the proxy needs and all it gets. --network none
    # because the proxy speaks only AF_UNIX.
    if ! docker run -d --name "$WL_CNAME" \
        --cap-drop=ALL --security-opt no-new-privileges --network none \
        --user "$(id -u):$(id -g)" --userns=host --entrypoint python3 \
        -v "$WL_HOST_SOCK:/run/host-wayland.sock:ro" \
        -v "$WL_ROOT:$WL_ROOT" \
        -v /etc/passwd:/etc/passwd:ro \
        -v /etc/group:/etc/group:ro \
        -v "$SCRIPT_DIR/wayland-guard.py:/usr/local/bin/wayland-guard.py:ro" \
        "$IMAGE_NAME" \
        /usr/local/bin/wayland-guard.py \
            --upstream /run/host-wayland.sock \
            --listen "$WL_ROOT/wayland-0" >/dev/null 2>&1
    then
        warn "could not start the clipboard proxy — image paste is unavailable this session."
        rm -rf "$WL_ROOT" 2>/dev/null || true
        return 0
    fi

    local _
    for _ in $(seq 1 100); do                       # ≤5s for the proxy to bind
        [ -S "$WL_ROOT/wayland-0" ] && break
        sleep 0.05
    done
    if [ ! -S "$WL_ROOT/wayland-0" ]; then
        warn "the clipboard proxy never came up; image paste is unavailable. Logs:" \
             "$(docker logs "$WL_CNAME" 2>&1 | tail -5)"
        docker rm -f "$WL_CNAME" >/dev/null 2>&1 || true
        rm -rf "$WL_ROOT" 2>/dev/null || true
        return 0
    fi
    start_wayland_notifier
    echo "📋 clipboard: mediated (read-only from the sandbox; sidecar: $WL_CNAME)" >&2
}

stop_wayland_guard() {
    local pid
    pid="$(cat "$WL_ROOT/notify.pid" 2>/dev/null || true)"
    # Negative pid: the notifier is a setsid'd pipeline, so kill the whole process group.
    [ -n "$pid" ] && kill -TERM "-$pid" 2>/dev/null || true
    docker rm -f "$WL_CNAME" >/dev/null 2>&1 || true
    rm -rf "$WL_ROOT" 2>/dev/null || true
}

# ── Clipboard on macOS: a one-way pbpaste bridge, no socket ───────
# macOS has no Wayland socket to proxy, and no equivalent to bind in. So instead of a
# protocol proxy, cc runs a host-side watcher (clipboard-bridge.sh) over a spool dir that
# is bind-mounted into the container at /cc/clip. The container-side shims (installed by
# the entrypoint) drop a request file and read back the response; the host answers reads
# with pbpaste / an osascript PNG extraction, and NEVER calls pbcopy. Writes are refused
# at the shim, so — exactly like the Wayland guard — reads pass and writes cannot happen.
# A write attempt leaves a deny marker the bridge turns into a desktop alert.
start_clipboard_bridge() {
    is_macos || return 0
    command -v pbpaste >/dev/null 2>&1 || {
        echo "ℹ️  clipboard: pbpaste not found — paste from the host is unavailable." >&2
        return 0
    }
    mkdir -p "$CLIP_STATE"
    chmod 755 "$CLIP_STATE"         # the container traverses this as root before gosu
    # 200>&- 201>&- is LOAD-BEARING, exactly as for the Wayland notifier and sleep-guard:
    # the bridge outlives the cc that starts it (it runs for the container's whole life),
    # and inheriting the project's shared lock on fd 200 would stop the last terminal out
    # from ever tearing the container down. detach_pgrp backgrounds it in its own group.
    detach_pgrp "$SCRIPT_DIR/clipboard-bridge.sh" "$CLIP_STATE" "$(basename "$PWD")" 200>&- 201>&-
    # The pid is a SIBLING of the spool, not inside it: $CLIP_STATE is bind-mounted rw into
    # the container, so a file there is sandbox-writable. On teardown the host reads this pid
    # and `kill -TERM -<pid>`s it — a sandbox that could overwrite it (e.g. with 1) would turn
    # teardown into a host process-group kill. ${CLIP_STATE}.pid lives in the 700 $STATE_DIR,
    # which is never mounted in.
    echo $! > "${CLIP_STATE}.pid"
    disown 2>/dev/null || true
    echo "📋 clipboard: pbpaste bridge active (read-only from the sandbox)" >&2
}

add_clipboard_bridge_args() {
    [ -d "$CLIP_STATE" ] || return 0
    # /cc-clip, NOT under /cc: entrypoint-fuse.sh does `chmod 700 /cc` to fence the real
    # project, which would also lock the agent out of the clipboard spool it must reach.
    ARGS+=(
        -v "$CLIP_STATE:/cc-clip"
        -e CC_CLIP_BRIDGE=1
        # VERIFY (Mac): which reader Claude Code invokes for image paste in a Linux
        # container. WAYLAND_DISPLAY makes it choose the wl-paste path (shimmed to the
        # bridge). If the Mac test shows it uses xclip/DISPLAY instead, flip this one line
        # to `-e DISPLAY=:0`; both shims are installed, so only the trigger changes.
        -e WAYLAND_DISPLAY=cc-clip
        -e XDG_RUNTIME_DIR="/run/user/$(id -u)"
    )
}

stop_clipboard_bridge() {
    is_macos || return 0
    local pid
    pid="$(cat "${CLIP_STATE}.pid" 2>/dev/null || true)"
    # Numeric-only, even though the pid file is host-only ($STATE_DIR, never mounted in):
    # `kill -TERM -<pid>` signals a whole process group, so a non-numeric or empty value
    # must never reach it.
    case "$pid" in ''|*[!0-9]*) pid="" ;; esac
    # Negative pid: the bridge runs in its own process group (detach_pgrp).
    [ -n "$pid" ] && kill -TERM "-$pid" 2>/dev/null || true
    rm -f "${CLIP_STATE}.pid" 2>/dev/null || true
    rm -rf "$CLIP_STATE" 2>/dev/null || true
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
# Only *failures* raise a desktop notification (claude's TUI wipes stderr milliseconds after
# launch, so stderr alone is unreadable); the working case stays silent — a popup on every
# launch saying "things are normal" is noise the user has to dismiss.
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
    else
        echo "⚠️  DNS: could not start the resolv.conf watcher — DNS is frozen at creation." >&2
        notify critical "cc · DNS is NOT following the host" \
            "The resolv.conf watcher failed to start; sessions won't follow a wifi/VPN change. See CLAUDE.md § DNS."
    fi
    return 0
}
