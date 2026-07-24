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
#   FUSE_CNAME FUSE_ROOT
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

# ── Credential broker: keep the real token OUT of the sandbox ─────
# The agent used to get ~/.claude-shared/.credentials.json mounted read-write, so a
# compromised session could exfiltrate the account OAuth token under open egress (audit
# H3/H4 — the single widest hole). Instead: a host-side broker sidecar holds the real
# token; the agent gets a base-URL env var (ANTHROPIC_BASE_URL) pointed at the broker, a
# PLACEHOLDER in CLAUDE_CODE_OAUTH_TOKEN, and a synthetic .credentials.json shadowing the
# real one. The broker terminates the agent's plain HTTP, strips the placeholder, injects
# the real token, and re-originates its own TLS to api.anthropic.com — no TLS MITM, no CA
# in the container. See docs/FUTURE_TASKS.md G1/C1 and cc-broker.py. A fully compromised
# agent can *use* the API through the broker but cannot read the token; the win holds even
# with egress wide open.
#
# ── THE BROKERED CREDENTIAL IS STATIC ─────────────────────────────────────────
# It is a long-lived token minted by `cc --broker-login` (which wraps `claude setup-token`)
# and stored HOST-ONLY at ~/.keep-it-in-your-box/claude-token, mounted READ-ONLY into the
# broker. It is NOT ~/.claude-shared/.credentials.json, and the broker never writes any
# credential. Brokering the live credentials file logged the account out: Anthropic's
# subscription refresh tokens are single-use and rotate, so the broker's refresh loop
# invalidated the token family for the host CLI and every other project's sidecar, and the
# in-place write to a single-file bind mount could tear it. See cc-broker.py's docstring
# for the full post-mortem. Do not reintroduce a refresh path.
#
# The broker sits on a dedicated user-defined bridge (cc-broker alias). The MAIN container
# stays multi-homed: it keeps the default bridge + host-gateway (so a host dev server on
# :3000 and the LAN stay reachable) and is ALSO connected to the broker net (Gate D verified
# container→container works under Portmaster). Net-new infra — nothing else here uses a
# user-defined network.
#
# OPT-IN, off by default: enable with `broker = on` in ~/.keep-it-in-your-box/config, or
# CC_BROKER=1; CC_BROKER=0 forces it off. When off, nothing changes — the real credential is
# mounted exactly as before.
broker_wanted() {
    case "${CC_BROKER:-}" in 1) return 0 ;; 0) return 1 ;; esac
    [ "${KIB_BROKER:-off}" = on ]
}

# Host-only token store, alongside ~/.keep-it-in-your-box/config and never bind-mounted into
# the agent — the thing that governs the agent's credentials must live where the agent
# cannot read it. Derived from KIB_CONFIG so there is one definition of "the kib dir".
KIB_DIR="$(dirname "$KIB_CONFIG")"
BROKER_TOKEN_FILE="$KIB_DIR/claude-token"

# User-defined provider definitions (generic MCP brokering — any service, no code change).
# Exported so EVERY cc-broker.py invocation (--list-providers, --host-config, --match-upstream,
# --serve in the sidecar) folds them onto the built-in presets. The dir is host-only; it is
# also mounted read-only into the broker sidecar, which reads it via this same env var.
PROVIDERS_DIR="$KIB_DIR/providers.d"
export CC_PROVIDERS_DIR="$PROVIDERS_DIR"

# -s, not -f: an empty file is not a token. This is the single predicate for "is the broker
# usable", used by the launch path, the attach check and --broker-status alike.
broker_has_token() { [ -s "$BROKER_TOKEN_FILE" ]; }

# The registry (single source of truth is cc-broker.py's PROVIDERS). Each line is
# `id|delivery|credential_kind|token_basename`. The bash side iterates this instead of
# duplicating the table, so a new provider is a row in cc-broker.py and nothing here.
_broker_list_providers() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 "$SCRIPT_DIR/cc-broker.py" --list-providers 2>/dev/null
}

# A provider is ACTIVE when its host credential file ($KIB_DIR/<token_basename>) is non-empty.
# Emit the active ids whose delivery is in the space-separated set $1, in registry order.
_active_providers() {
    local want="$1" id delivery kind basename ids=""
    while IFS='|' read -r id delivery kind basename; do
        [ -n "$id" ] || continue
        case " $want " in *" $delivery "*) ;; *) continue ;; esac
        [ -s "$KIB_DIR/$basename" ] && ids="${ids:+$ids }$id"
    done <<EOF
$(_broker_list_providers)
EOF
    printf '%s' "$ids"
}

# `broker_enabled_providers` are the routes the BROKER SIDECAR serves (base_url_env +
# reverse_proxy_mcp); `hosted_mcp_providers` run in their OWN sidecar (start_hosted_mcp). The
# claude row is required for the broker to launch (checked in start_broker); MCP rows are
# purely additive and never block a launch. Order follows the registry (claude first).
broker_enabled_providers() { _active_providers "base_url_env reverse_proxy_mcp"; }
hosted_mcp_providers()     { _active_providers "hosted_mcp"; }

# Fixed at container creation, like the .ccignore rules and the unlock-shared mode: a second
# terminal must never attach under a broker config that changed since the container started.
# Covers BOTH sidecar-served routes and hosted MCPs, so adding/removing either forces a relaunch.
broker_config_hash() {
    hash8 "$(broker_enabled_providers)|$(hosted_mcp_providers)|$CC_BROKER_ENDPOINT_MODE"
}

# Read the host-facing facts for one provider out of cc-broker.py — the single source of
# truth, so the bash side never duplicates the PROVIDERS table. Sets CCB_* in the CALLER's
# scope; returns non-zero if python3 is missing or the table can't be read.
_broker_host_config() {
    command -v python3 >/dev/null 2>&1 || return 1
    local out
    out="$(python3 "$SCRIPT_DIR/cc-broker.py" --host-config "${1:-claude}" 2>/dev/null)" || return 1
    [ -n "$out" ] || return 1
    eval "$out"
}

# config.json the broker reads. Host-only (in $STATE_DIR, never mounted into the AGENT); it
# lists the enabled providers and each token's IN-BROKER path.
_write_broker_config() {
    mkdir -p "$BROKER_OUT" && chmod 700 "$BROKER_DIR" "$BROKER_OUT"
    # Derive `enabled` + `token_paths` from the SAME source as broker_config_hash
    # (broker_enabled_providers), so the config the broker reads and the attach-hash can never
    # disagree. bash-3.2 clean (no associative arrays).
    local id enabled_json="" token_json="" sep=""
    for id in $(broker_enabled_providers); do
        enabled_json="${enabled_json}${sep}\"$id\""
        token_json="${token_json}${sep}\"$id\": \"/run/broker/token/$id\""
        sep=", "
    done
    printf '{"enabled": [%s], "out_dir": "/run/broker/out", "token_paths": {%s}}\n' \
        "$enabled_json" "$token_json" > "$BROKER_DIR/config.json"
    chmod 600 "$BROKER_DIR/config.json"
}

# Fail-HARD: brokering IS the agent's core auth, and a placeholder is shadowed
# unconditionally (so a dead broker leaks nothing — it just can't authenticate). Abort the
# launch cleanly, BEFORE the TUI clears the screen, rather than surface a confusing auth
# error deep in the session. Tear down anything already started (FUSE/clipboard sidecars,
# the half-started broker) so nothing is stranded.
_broker_abort() {
    teardown_container              # stops main (if up) + all sidecars incl. stop_broker
    die "$1" \
        "" \
        "This is a broker STARTUP failure, not an auth problem. The sandbox will not run" \
        "without brokering the credential — the real token must never enter the container." \
        "Fix the cause above and relaunch, or set CC_BROKER=0 to launch WITHOUT the broker" \
        "(the pre-broker behaviour: the token is mounted into the container)."
}

# Turn a mid-session broker problem into a desktop alert. Startup problems already abort
# loudly; this covers the running container. Linux-only and raw setsid/notify-send by design,
# exactly like the Wayland notifier (the sanctioned exception in the portability contract).
# 200>&- 201>&- is LOAD-BEARING: this follower outlives the cc that starts it, and inheriting
# the project's shared lock (fd 200) would stop the last terminal out from ever tearing the
# container down.
#
# The alert budget is deliberately small and self-limiting. The refresh loop that used to
# exist paged once every 30s indefinitely — 30 popups in 15 minutes, which trains you to
# dismiss the one that matters. After 3 alerts it backs off to one per 15 minutes; the log
# line is always written either way.
start_broker_notifier() {
    is_macos && return 0
    command -v notify-send >/dev/null 2>&1 || return 0
    setsid sh -c '
        last=0; count=0
        docker logs -f "$1" 2>&1 | while IFS= read -r line; do
            case "$line" in BROKER-FATAL*|BROKER-ERR*) ;; *) continue ;; esac
            gap=30; [ "$count" -ge 3 ] && gap=900
            now=$(date +%s)
            [ $((now - last)) -lt $gap ] && continue
            last=$now; count=$((count + 1))
            notify-send -u critical -i dialog-error "cc · credential broker" "$2" || true
        done' _ "$BROKER_CNAME" \
        "The credential broker could not reach the API or use its token. Check: cc --broker-status. Project: $(basename "$PWD")" \
        >/dev/null 2>&1 200>&- 201>&- &
    echo $! > "$BROKER_DIR/notify.pid"
}

# Bring up the broker sidecar on its own bridge, wait for it to mint the placeholder and bind
# its port, then mark it enabled. Called on the CREATE path only, under the boot lock, before
# the main container's docker run (which reads the placeholder + base-URL via
# add_broker_env_args). No-op when the broker isn't wanted.
start_broker() {
    broker_wanted || return 0
    if ! broker_has_token; then
        # Fail hard rather than silently falling back: "carry on without the broker" means
        # mounting the real credential into the container, which is the exact exposure the
        # user opted out of. Refusing is the safe direction, and the fix is one command.
        die "the credential broker is enabled, but there is no token at" \
            "  $BROKER_TOKEN_FILE" \
            "" \
            "Mint one on the host (it never enters the sandbox):" \
            "  cc --broker-login" \
            "" \
            "Or set CC_BROKER=0 for this launch to run WITHOUT the broker (the pre-broker" \
            "behaviour: the real token is mounted into the container)."
    fi
    _write_broker_config                       # creates $BROKER_OUT / $BROKER_DIR (chmod 700)
    rm -f "$BROKER_OUT/ready" 2>/dev/null || true

    if ! docker network inspect "$BROKER_NET" >/dev/null 2>&1; then
        docker network create "$BROKER_NET" >/dev/null 2>&1 \
            || _broker_abort "could not create the broker network ($BROKER_NET)."
    fi

    # One read-only token mount per SIDECAR-SERVED route, at /run/broker/token/<id> (the path
    # _write_broker_config puts in token_paths). claude is always present here (checked above);
    # a reverse_proxy_mcp route like dataforseo adds its own when its token file exists.
    local id delivery kind basename
    local -a tok_mounts=()
    while IFS='|' read -r id delivery kind basename; do
        case "$delivery" in base_url_env|reverse_proxy_mcp) ;; *) continue ;; esac
        [ -s "$KIB_DIR/$basename" ] || continue
        tok_mounts+=( -v "$KIB_DIR/$basename:/run/broker/token/$id:ro" )
    done <<EOF
$(_broker_list_providers)
EOF

    # cap-drop=ALL, no devices — strictly less privileged than the FUSE sidecar. Tokens are
    # mounted HERE ONLY and READ-ONLY: the broker has no write path to any credential, by
    # construction rather than by discipline. The placeholder + ready marker land in
    # $BROKER_OUT, which cc reads host-side.
    # User-defined provider defs (if any) are mounted read-only so the sidecar's serve() folds
    # them onto the LLM built-ins, exactly as the host-side --list/--host-config calls do.
    local -a prov_mount=()
    [ -d "$PROVIDERS_DIR" ] && prov_mount=(
        -v "$PROVIDERS_DIR:/run/broker/providers.d:ro" -e CC_PROVIDERS_DIR=/run/broker/providers.d )

    local -a broker_run=(
        docker run -d --name "$BROKER_CNAME"
        --cap-drop=ALL --security-opt no-new-privileges
        --user "$(id -u):$(id -g)" --userns=host --entrypoint python3
        --network "$BROKER_NET" --network-alias cc-broker
        "${tok_mounts[@]}"
        "${prov_mount[@]}"
        -v "$BROKER_OUT:/run/broker/out"
        -v "$BROKER_DIR/config.json:/run/broker/config.json:ro"
        -v /etc/passwd:/etc/passwd:ro
        -v /etc/group:/etc/group:ro
        -v "$SCRIPT_DIR/cc-broker.py:/usr/local/bin/cc-broker.py:ro"
        "$IMAGE_NAME"
        /usr/local/bin/cc-broker.py --serve --config /run/broker/config.json
    )
    if ! "${broker_run[@]}" >/dev/null 2>&1; then
        _broker_abort "could not start the credential broker sidecar."
    fi

    local _
    for _ in $(seq 1 100); do                       # ≤5s to mint the placeholder + bind
        [ -f "$BROKER_OUT/ready" ] && break
        broker_running || break                     # died early — fall through to the log dump
        sleep 0.05
    done
    if [ ! -f "$BROKER_OUT/ready" ]; then
        echo "❌ broker: sidecar never became ready; logs:" >&2
        docker logs "$BROKER_CNAME" 2>&1 | tail -10 | sed 's/^/   /' >&2 || true
        _broker_abort "the credential broker did not come up."
    fi

    broker_config_hash > "$BROKER_HASH"
    start_broker_notifier
    BROKER_ENABLED=1
    echo "🔐 credential broker: active — the real token is NOT in the sandbox (sidecar: $BROKER_CNAME)." >&2

    # Add-ons, both fail-SOFT (a broken MCP must never block the session the way a broker
    # startup failure does): bring up any hosted-MCP sidecars, then write every active brokered
    # MCP route into the agent's .claude.json so the agent reaches them WITHOUT holding a header.
    start_hosted_mcp
    inject_brokered_mcps
}

# ── Hosted MCP sidecars (shape B/C: a LOCAL/client-signed MCP that can't be header-brokered) ──
# The MCP server runs in its own cap-drop=ALL sidecar on the broker network, holding its
# credential file READ-ONLY; the agent reaches it at http://<id>:<port><mcp_path>. The secret
# (e.g. a Google service-account JSON and its client-side JWT signing) never enters the agent
# container. supergateway bridges the server's stdio to streamable-HTTP. FAIL-SOFT: on any
# error we warn and skip that MCP (and don't inject its .claude.json entry), never abort.
#
# NOTE (verify on first real use, like the codex/gemini rows): needs `uv`/`uvx` + `npx` and
# network in the image to fetch supergateway and the server; HOME/cache dirs are pointed at
# /tmp so the unprivileged sidecar user can write them.
HOSTED_MCP_UP=""            # space-separated ids whose sidecar came up (read by inject_brokered_mcps)
start_hosted_mcp() {
    local ids id; ids="$(hosted_mcp_providers)"
    [ -n "$ids" ] || return 0
    for id in $ids; do
        local CCB_TOKEN_BASENAME="" CCB_CREDENTIAL_ENV="" CCB_MCP_PORT="" \
              CCB_HOST_RUN="" CCB_EXTRA_ENV=""
        if ! _broker_host_config "$id"; then
            warn "hosted MCP '$id': could not read its host-config — skipping."
            continue
        fi
        [ -n "$CCB_HOST_RUN" ] && [ -n "$CCB_MCP_PORT" ] && [ -n "$CCB_TOKEN_BASENAME" ] || {
            warn "hosted MCP '$id': incomplete registry entry — skipping."; continue; }

        local cname="${CNAME}-hmcp-${id}"
        docker rm -f "$cname" >/dev/null 2>&1 || true      # clear a crashed leftover
        # extra_env (KEY=VAL, constants) → -e flags; word-split is safe (no metacharacters).
        local -a env_args=() kv
        for kv in $CCB_EXTRA_ENV; do env_args+=( -e "$kv" ); done
        local -a run=(
            docker run -d --name "$cname"
            --cap-drop=ALL --security-opt no-new-privileges
            --user "$(id -u):$(id -g)" --userns=host
            --network "$BROKER_NET" --network-alias "$id"
            -v "$KIB_DIR/$CCB_TOKEN_BASENAME:/run/cred/$CCB_TOKEN_BASENAME:ro"
            -e "$CCB_CREDENTIAL_ENV=/run/cred/$CCB_TOKEN_BASENAME"
            -e "HOME=/tmp" -e "UV_CACHE_DIR=/tmp/.uv" -e "npm_config_cache=/tmp/.npm"
            "${env_args[@]}"
            -v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro
            --entrypoint sh "$IMAGE_NAME"
            -c "exec npx -y supergateway --stdio \"$CCB_HOST_RUN\" --outputTransport streamableHttp --port $CCB_MCP_PORT --host 0.0.0.0"
        )
        if "${run[@]}" >/dev/null 2>&1; then
            HOSTED_MCP_UP="${HOSTED_MCP_UP:+$HOSTED_MCP_UP }$id"
            echo "🔐 hosted MCP '$id': sidecar up (cred stays host-side: $cname)." >&2
        else
            warn "hosted MCP '$id': sidecar failed to start — the agent will launch without it."
        fi
    done
}

# Write every ACTIVE brokered MCP route into the agent's per-project .claude.json mcpServers,
# as { "<name>": {"type":"<transport>","url":"http://<host>:<port><path>", "_ccBroker": true} }
# with NO auth header — cc owns this file, the agent never sees a credential. reverse_proxy_mcp
# routes point at the broker (cc-broker:<listen_port>); hosted_mcp routes point at their sidecar
# alias (<id>:<mcp_port>) and are injected ONLY if their sidecar came up (HOSTED_MCP_UP).
# Entries we own carry "_ccBroker": true; every launch we drop the stale ones we own and
# rewrite the current set, so disabling a provider cleanly removes its entry. User-authored
# servers (without the marker) are never touched.
inject_brokered_mcps() {
    [ "$BROKER_ENABLED" = 1 ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    local cfg="$SESSION_DIR/.claude.json"

    # Build the desired entry set as `name<TAB>type<TAB>url` lines from the registry.
    local specs="" id delivery kind basename
    while IFS='|' read -r id delivery kind basename; do
        local host="" port="" active=0
        case "$delivery" in
            reverse_proxy_mcp) [ -s "$KIB_DIR/$basename" ] && { host="cc-broker"; active=1; } ;;
            hosted_mcp) case " $HOSTED_MCP_UP " in *" $id "*) host="$id"; active=1 ;; esac ;;
            *) continue ;;
        esac
        [ "$active" = 1 ] || continue
        local CCB_MCP_SERVER_NAME="" CCB_MCP_PATH="" CCB_MCP_TRANSPORT="" CCB_MCP_PORT=""
        _broker_host_config "$id" || continue
        [ -n "$CCB_MCP_SERVER_NAME" ] && [ -n "$CCB_MCP_PORT" ] || continue
        specs="${specs}${CCB_MCP_SERVER_NAME}	${CCB_MCP_TRANSPORT:-http}	http://${host}:${CCB_MCP_PORT}${CCB_MCP_PATH}
"
    done <<EOF
$(_broker_list_providers)
EOF

    CC_MCP_SPECS="$specs" CC_MCP_CFG="$cfg" python3 - <<'PY' || warn "could not inject brokered MCP entries into .claude.json"
import json, os, sys
cfg = os.environ["CC_MCP_CFG"]
specs = [l.split("\t") for l in os.environ["CC_MCP_SPECS"].splitlines() if l.strip()]
try:
    with open(cfg) as fh:
        data = json.load(fh)
except (OSError, ValueError):
    data = {}
servers = data.get("mcpServers")
if not isinstance(servers, dict):
    servers = {}
# Drop only the entries WE own (marker), leaving user-authored servers intact.
servers = {k: v for k, v in servers.items()
           if not (isinstance(v, dict) and v.get("_ccBroker"))}
for name, transport, url in specs:
    servers[name] = {"type": transport, "url": url, "_ccBroker": True}
data["mcpServers"] = servers
tmp = cfg + ".tmp.%d" % os.getpid()
with open(tmp, "w") as fh:
    json.dump(data, fh, indent=2)
os.replace(tmp, cfg)
if specs:
    sys.stderr.write("🔐 brokered MCP(s) wired into .claude.json: %s\n"
                     % ", ".join(s[0] for s in specs))
PY
}

# Agent-facing wiring, appended to the main container's ARGS. Reads the base-URL env name,
# token env name, port and placeholder path from cc-broker.py (single source of truth — no
# duplicated table). Three things go in, and all three are needed:
#   1. the base URL, so the SDK talks to the broker instead of api.anthropic.com;
#   2. a PLACEHOLDER token in CLAUDE_CODE_OAUTH_TOKEN, which takes precedence over the
#      credentials file, so the agent authenticates through the broker;
#   3. a synthetic .credentials.json shadowing the real one. (2) alone would leave the real
#      file readable inside $CLAUDE_SHARED, which is the whole exposure. It lands AFTER the
#      $CLAUDE_SHARED mount so it overlays the file inside it (Docker applies mounts
#      parent-first by destination depth).
add_broker_env_args() {
    [ "$BROKER_ENABLED" = 1 ] || return 0
    # Loop the sidecar-served routes. base_url_env rows (claude/codex/gemini) need the agent's
    # base-URL + placeholder-token env, and — where a credential file is shadowed (claude) — the
    # synthetic .credentials.json mount. reverse_proxy_mcp rows (dataforseo) need NOTHING here:
    # the agent reaches them via the .claude.json URL (inject_brokered_mcps), not an env var.
    local id delivery
    for id in $(broker_enabled_providers); do
        local CCB_BASE_URL_ENV="" CCB_TOKEN_ENV="" CCB_PLACEHOLDER_TOKEN="" \
              CCB_LISTEN_PORT="" CCB_PLACEHOLDER_CONTAINER_PATH="" CCB_DELIVERY=""
        _broker_host_config "$id" \
            || _broker_abort "could not read the broker's host-config for '$id'."
        [ "$CCB_DELIVERY" = base_url_env ] || continue
        [ -n "$CCB_BASE_URL_ENV" ] && [ -n "$CCB_TOKEN_ENV" ] && [ -n "$CCB_PLACEHOLDER_TOKEN" ] \
            && [ -n "$CCB_LISTEN_PORT" ] \
            || _broker_abort "the broker's host-config for '$id' is incomplete."
        ARGS+=(
            -e "$CCB_BASE_URL_ENV=http://cc-broker:$CCB_LISTEN_PORT"
            -e "$CCB_TOKEN_ENV=$CCB_PLACEHOLDER_TOKEN"
        )
        # Only claude shadows a real credential file; codex/gemini have no file to overlay.
        [ -n "$CCB_PLACEHOLDER_CONTAINER_PATH" ] \
            && ARGS+=( -v "$BROKER_OUT/$id.cred.json:$CCB_PLACEHOLDER_CONTAINER_PATH:ro" )
    done
}

# Dual-home the main container onto the broker net AFTER its docker run (a container's single
# --network at run time would replace the default bridge; connecting a second net keeps both,
# and gives the container Docker's embedded resolver so `cc-broker` resolves). Fail-hard: no
# broker route means no auth.
connect_broker_network() {
    [ "$BROKER_ENABLED" = 1 ] || return 0
    docker network connect "$BROKER_NET" "$CNAME" >/dev/null 2>&1 \
        || _broker_abort "could not attach the container to the broker network ($BROKER_NET)."
}

# Attach-path refusal: a second terminal must not attach to a container running WITHOUT the
# broker (its real token would be mounted) or under a since-changed broker config. Same shape
# as verify_redaction_attach and the unlock-shared stale check.
verify_broker_attach() {
    broker_wanted || return 0
    broker_has_token || return 0
    if ! broker_running; then
        die "the credential broker is requested, but this project's container is running" \
            "WITHOUT it — so the real token is mounted, defeating the broker. Refusing to" \
            "attach. Close all cc sessions for this project and relaunch. (A container" \
            "created before the broker existed, or with CC_BROKER=0, always lands here.)"
    fi
    if [ "$(cat "$BROKER_HASH" 2>/dev/null || true)" != "$(broker_config_hash)" ]; then
        die "the credential-broker configuration changed since this project's container" \
            "started. Refusing to attach under stale broker settings — close all cc" \
            "sessions for this project and relaunch."
    fi
}

stop_broker() {
    local pid
    pid="$(cat "$BROKER_DIR/notify.pid" 2>/dev/null || true)"
    case "$pid" in ''|*[!0-9]*) pid="" ;; esac
    # Negative pid: the notifier is a setsid'd pipeline — kill the whole process group.
    [ -n "$pid" ] && kill -TERM "-$pid" 2>/dev/null || true
    docker rm -f "$BROKER_CNAME" >/dev/null 2>&1 || true
    # Hosted-MCP sidecars share the broker net and must go before `network rm`. Match by the
    # ${CNAME}-hmcp-* name prefix so we get every one without tracking their ids here.
    local hm
    for hm in $(docker ps -aq -f "name=^${BROKER_CNAME%-broker}-hmcp-" 2>/dev/null); do
        docker rm -f "$hm" >/dev/null 2>&1 || true
    done
    # The main container must be gone first (teardown_container stops it before calling this),
    # or the network still has an endpoint and rm fails — harmless, it's retried next teardown.
    docker network rm "$BROKER_NET" >/dev/null 2>&1 || true
    rm -rf "$BROKER_DIR" 2>/dev/null || true
}

# ── Credential lifecycle: cc --login / --logout / --status <name> ──────────────
# All run HOST-SIDE and exit before any container work, so they are usable while the sandbox
# is broken or has never been built. None ever prints a credential. Registry-driven: adding a
# provider row to cc-broker.py makes `cc --login <that-id>` work with no change here.

_broker_need_python() {
    command -v python3 >/dev/null 2>&1 && return 0
    die "python3 is required host-side to manage broker credentials, and it is not on PATH." \
        "On macOS: xcode-select --install"
}

# Resolve one provider from the registry. Sets _P_DELIVERY/_P_KIND/_P_BASENAME/_P_FILE in the
# caller's scope; returns 1 for an unknown id.
_provider_lookup() {
    local id delivery kind basename
    _P_DELIVERY=""; _P_KIND=""; _P_BASENAME=""; _P_FILE=""
    while IFS='|' read -r id delivery kind basename; do
        [ "$id" = "$1" ] || continue
        _P_DELIVERY="$delivery"; _P_KIND="$kind"; _P_BASENAME="$basename"; _P_FILE="$KIB_DIR/$basename"
        return 0
    done <<EOF
$(_broker_list_providers)
EOF
    return 1
}

_provider_ids_csv() {
    local id rest out=""
    while IFS='|' read -r id rest; do out="${out:+$out, }$id"; done <<EOF
$(_broker_list_providers)
EOF
    printf '%s' "$out"
}

# Atomic mode-600 write of a secret to a host file (never briefly world-readable).
_store_secret_file() {
    local tmp="$1.tmp.$$"
    ( umask 077; printf '%s\n' "$2" > "$tmp" ) || die "could not write $1"
    chmod 600 "$tmp" && mv -f "$tmp" "$1" || { rm -f "$tmp"; die "could not install $1"; }
}

# Per-provider "how to obtain it" guidance (human hints, not machine facts — kept here rather
# than in the registry so the table stays word-splittable).
_provider_login_hint() {
    case "$1" in
        claude)
            if command -v claude >/dev/null 2>&1; then
                echo "   Running \`claude setup-token\`; complete the browser flow, then copy the"
                echo "   token it prints (starts sk-ant-oat01-)."; echo
                claude setup-token || echo "   ⚠️  claude setup-token exited non-zero — paste a token anyway, or Ctrl-C." >&2
            else
                echo "   \`claude\` is not on PATH — run this on the host and copy the token:"
                echo "     claude setup-token"
            fi ;;
        codex)  echo "   Create an OpenAI API key (starts sk-…): https://platform.openai.com/api-keys" ;;
        gemini) echo "   Create a Gemini API key: https://aistudio.google.com/apikey" ;;
        # Everything else is a user-defined MCP (providers.d/); service-specific guidance lives
        # with its provider def (e.g. examples/providers/*.json), not in this hardcoded table.
        *)      if [ "$_P_KIND" = file_path ]; then
                    echo "   Provide the path to the credential file for '$1'."
                else
                    echo "   Paste the credential for '$1'."
                fi ;;
    esac
    echo
}

# Add (or replace) a provider credential, stored HOST-ONLY. paste_token → hidden paste;
# file_path → copy a file the user names. Then probe (advisory).
provider_login() {
    local id="${1:-claude}"
    _broker_need_python
    _provider_lookup "$id" || die "unknown provider: $id" "known: $(_provider_ids_csv)"
    [ -t 0 ] || die "cc --login needs an interactive terminal."
    mkdir -p "$KIB_DIR" && chmod 700 "$KIB_DIR"

    echo "🔐 cc --login $id — add a credential the broker injects for you."
    echo "   Stored HOST-ONLY at: $_P_FILE"
    echo "   (mounted read-only into the broker; it never enters the sandbox)."
    echo
    _provider_login_hint "$id"

    if [ "$_P_KIND" = file_path ]; then
        local path=""
        printf '   Path to the credential file: '
        read -r path || true
        case "$path" in "~/"*) path="$HOME/${path#\~/}" ;; esac
        [ -n "$path" ] || die "no path entered — nothing was written."
        [ -f "$path" ] || die "no such file: $path"
        ( umask 077; cp "$path" "$_P_FILE.tmp.$$" ) || die "could not read $path"
        chmod 600 "$_P_FILE.tmp.$$" && mv -f "$_P_FILE.tmp.$$" "$_P_FILE" \
            || { rm -f "$_P_FILE.tmp.$$"; die "could not install $_P_FILE"; }
        echo "   ✅ copied to $_P_FILE (mode 600)."
    else
        local secret=""
        printf '   Paste the credential (input hidden), then Enter: '
        read -rs secret || true
        echo
        case "$secret" in
            "")        die "nothing entered — nothing was written." ;;
            *[!\ -~]*) die "that contains control characters — not stored." ;;
        esac
        # Claude token shape is advisory only; the probe decides. Other providers accept anything.
        if [ "$id" = claude ]; then
            case "$secret" in
                sk-ant-oat01-*|sk-ant-api*) ;;
                *) echo "   ⚠️  that doesn't start with sk-ant-oat01-/sk-ant-api — storing anyway; the probe decides." >&2 ;;
            esac
        fi
        _store_secret_file "$_P_FILE" "$secret"
        unset secret
        echo "   ✅ stored (mode 600)."
    fi
    echo
    provider_probe "$id" || _login_ok_after_probe "$?"
}

# Map a probe exit status to login's: a successful store is a successful login UNLESS the probe
# definitively rejected the credential (1). 0 (accepted) and 2 (inconclusive) both keep login
# successful. Factored out so tests/check.sh can assert the truth table directly.
_login_ok_after_probe() { [ "$1" != 1 ]; }

# Remove a provider credential. The sandbox's own credential is untouched.
provider_logout() {
    local id="${1:-claude}"
    _provider_lookup "$id" || die "unknown provider: $id" "known: $(_provider_ids_csv)"
    if [ ! -e "$_P_FILE" ]; then
        echo "🔐 no stored credential for '$id' at $_P_FILE — nothing to remove."
        return 0
    fi
    rm -f "$_P_FILE" || die "could not remove $_P_FILE"
    echo "🔐 removed $_P_FILE"
    [ "$id" = claude ] && echo "   Revoke it at https://console.anthropic.com/settings/keys if it may have leaked."
    echo "   Re-add with: cc --login $id"
    if [ "$id" = claude ] && broker_wanted; then
        echo "   The broker is ENABLED, so cc will refuse to launch until you do."
    fi
}

# Ask the upstream whether a stored credential is accepted. Exit status mirrors cc-broker.py
# --probe: 0 accepted, 1 rejected, 2 inconclusive (incl. providers with no probe defined).
provider_probe() {
    local id="${1:-claude}"
    _broker_need_python
    _provider_lookup "$id" || return 1
    [ -s "$_P_FILE" ] || { echo "🔐 no credential stored for '$id' ($_P_FILE)"; return 1; }
    echo "   checking the stored credential for '$id'…"
    python3 "$SCRIPT_DIR/cc-broker.py" --probe "$_P_FILE" "$id"
}

# Status of EVERY registry provider (never prints contents — size/mode only).
provider_status() {
    echo "🔐 credential broker"
    echo "   enabled:  $(broker_wanted && echo yes || echo "no  (set 'broker = on' in $KIB_CONFIG, or CC_BROKER=1)")"
    local id delivery kind basename file mode size
    while IFS='|' read -r id delivery kind basename; do
        file="$KIB_DIR/$basename"
        if [ -s "$file" ]; then
            mode="$(ls -l "$file" 2>/dev/null | cut -c1-10)"
            size="$(wc -c < "$file" 2>/dev/null | tr -d ' ')"
            printf '   %-11s stored  (%s bytes, %s) [%s]\n' "$id" "$size" "$mode" "$delivery"
        else
            printf '   %-11s —       add: cc --login %s   [%s]\n' "$id" "$id" "$delivery"
        fi
    done <<EOF
$(_broker_list_providers)
EOF
    if broker_has_token; then
        echo
        provider_probe claude
    fi
    broker_has_token          # exit non-zero when claude (the required cred) is absent
}

# Back-compat aliases: the original --broker-* subcommands act on the claude provider.
broker_login()  { provider_login  claude; }
broker_logout() { provider_logout claude; }
broker_probe()  { provider_probe  claude; }
broker_status() { provider_status; }

# ── Inline-credential detector (C4) + cc --mcp-adopt ───────────────────────────
# Allowing the insecure `claude mcp add --header "Authorization: …"` path is fine — but that
# credential lands in the sandbox, so the agent can read it (and it's already on its way to the
# API). warn_inline_mcp_secrets flags it on every launch (WARN only, never blocks); mcp_adopt
# migrates it into the broker. Neither ever prints the secret value.
warn_inline_mcp_secrets() {
    command -v python3 >/dev/null 2>&1 || return 0
    CC_MCP_JSON="$PWD/.mcp.json" CC_CLAUDE_JSON="$SESSION_DIR/.claude.json" \
    CC_WARN_BROKER_PY="$SCRIPT_DIR/cc-broker.py" \
        python3 - <<'PY' || true
import importlib.util, json, os, sys
# Same secret-shape tests as the interceptor (cc-broker.py) so the warner and the front-line
# blocker agree on what counts as a secret — they used to drift (the interceptor caught AUTH-named
# and value-shaped secrets the warner missed).
_spec = importlib.util.spec_from_file_location("ccbroker", os.environ["CC_WARN_BROKER_PY"])
ccb = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(ccb)
files = [("project .mcp.json",  os.environ.get("CC_MCP_JSON", "")),
         ("session .claude.json", os.environ.get("CC_CLAUDE_JSON", ""))]
for label, path in files:
    if not path:
        continue
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        continue
    servers = data.get("mcpServers")
    if not isinstance(servers, dict):
        continue
    for name, e in servers.items():
        if not isinstance(e, dict) or e.get("_ccBroker"):
            continue          # our brokered entries carry no secret — skip
        reason = None
        for k, v in (e.get("headers") or {}).items():
            if v and ccb.is_auth_header(k, str(v)):
                reason = "inline auth header"; break
        if not reason:
            for k, v in (e.get("env") or {}).items():
                if v and ccb.env_is_secret("%s=%s" % (k, v)):
                    reason = "inline env secret (%s)" % k; break
        if reason:
            # Value is NEVER printed — only the name + reason.
            sys.stderr.write('⚠️  MCP "%s" (%s) carries an %s the agent can read — '
                             'it is already sent to the API.\n' % (name, label, reason))
            sys.stderr.write('   Broker it instead:  cc --mcp-adopt %s\n' % name)
PY
}

# Migrate an inline-credential MCP into the broker: store the secret host-side, strip it from
# the project config, and let inject_brokered_mcps re-add a header-free brokered entry at the
# next launch. Only remote MCPs whose upstream matches a reverse_proxy_mcp route can be adopted;
# a local/stdio MCP (shape B/C) needs a hosted_mcp row instead, and adopt says so.
mcp_adopt() {
    local name="$1"
    [ -n "$name" ] || die "usage: cc --mcp-adopt <server-name>"
    _broker_need_python
    CC_ADOPT_NAME="$name" CC_KIB_DIR="$KIB_DIR" CC_BROKER_PY="$SCRIPT_DIR/cc-broker.py" \
    CC_PROVIDERS_DIR="$PROVIDERS_DIR" \
    CC_MCP_JSON="$PWD/.mcp.json" CC_CLAUDE_JSON="$SESSION_DIR/.claude.json" \
        python3 - <<'PY' || return $?
import importlib.util, json, os, sys
name    = os.environ["CC_ADOPT_NAME"]
kib     = os.environ["CC_KIB_DIR"]
script  = os.environ["CC_BROKER_PY"]
provdir = os.environ["CC_PROVIDERS_DIR"]
files   = [f for f in (os.environ.get("CC_MCP_JSON", ""),
                       os.environ.get("CC_CLAUDE_JSON", "")) if f]

# Shared synthesis/secret helpers from cc-broker.py (single source of truth). Merge user provider
# defs so match_upstream_route sees routes already added for this host.
_spec = importlib.util.spec_from_file_location("ccbroker", script)
ccb = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(ccb)
ccb._merge_user_providers()

hit = None
for path in files:
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        continue
    servers = data.get("mcpServers")
    if isinstance(servers, dict) and isinstance(servers.get(name), dict):
        hit = (path, data, servers, servers[name]); break
if hit is None:
    sys.exit("no MCP named %r with an inline config found in .mcp.json or .claude.json" % name)
path, data, servers, entry = hit
if entry.get("_ccBroker"):
    sys.exit("%r is already a brokered entry — nothing to adopt." % name)

url = entry.get("url", "")
hdrname, authval = ccb.find_auth_header(list((entry.get("headers") or {}).items()))
if not url or not authval:
    sys.exit("%r has no inline remote auth header to broker. A local/stdio MCP needs a "
             "hosted_mcp definition (cc --add-mcp … --run …), not adoption." % name)

# Reuse an EXISTING brokered route (a user def you already added) if one serves this host;
# otherwise SYNTHESIZE a new provider definition from the inline entry — this is what makes
# adoption generic for an MCP we've never heard of. (No MCP is built in, so a match here is
# always a prior user route, never a preset.)
matched = ccb.match_upstream_route(url)
if matched:
    pid, basename, scheme = matched
    where = "existing route '%s'" % pid
else:
    scheme = ccb.scheme_of(authval)
    transport = entry.get("type") if entry.get("type") in ("http", "sse") else "http"
    try:
        prov = ccb.synthesize_reverse_proxy(name, url, hdrname, scheme, ccb.next_free_port(), transport)
    except ValueError as e:
        sys.exit(str(e))
    basename = prov["token_basename"]
    ccb.write_provider_def(provdir, name, prov)
    where = "new provider def %s.json (port %d)" % (name, prov["listen_port"])

# Recover the raw secret and store it host-side, mode 600, atomically.
ccb.store_secret(kib, basename, ccb.recover_secret(authval, scheme))

# Strip the inline entry so the secret leaves the project entirely.
del servers[name]
data["mcpServers"] = servers
t2 = path + ".tmp.%d" % os.getpid()
with open(t2, "w") as fh:
    json.dump(data, fh, indent=2)
os.replace(t2, path)

sys.stderr.write("🔐 adopted '%s' via %s; stored the credential host-side as %s and removed the "
                 "inline entry from %s.\n" % (name, where, basename, os.path.basename(path)))
PY
    if broker_wanted; then
        echo "   Relaunch cc to use '$name' through the broker (no header in the sandbox)."
    else
        echo "   Enable the broker to use it: set 'broker = on' in $KIB_CONFIG (or CC_BROKER=1), then relaunch."
    fi
}

# Declare a brokered MCP directly (without first adding it inline). Remote header-authed MCP:
#   cc --add-mcp <name> --url <url> [--header "Header-Name: Scheme"]   (scheme: Bearer|Basic|"")
# then `cc --login <name>` pastes the token. Hosted (local/stdio) MCP whose secret can't be
# header-injected:
#   cc --add-mcp <name> --run "<cmd>" --cred-env <ENV> [--cred-kind file|token] [--port N] \
#       [--env KEY=VAL]...   (--env repeatable; extra env the hosted server needs, e.g. a flag)
# Writes a provider def to $PROVIDERS_DIR/<name>.json; the login/broker paths do the rest.
mcp_add() {
    _broker_need_python
    local name="" url="" header="" run="" cred_env="" cred_kind="paste_token" port="" envs=""
    name="$1"; shift || true
    [ -n "$name" ] && [ "${name#--}" = "$name" ] || die "usage: cc --add-mcp <name> --url <url> [--header \"H: Scheme\"]  (or --run <cmd> --cred-env <ENV> [--env KEY=VAL]...)"
    while [ $# -gt 0 ]; do
        case "$1" in
            --url)       url="$2"; shift 2 ;;
            --header)    header="$2"; shift 2 ;;
            --run)       run="$2"; shift 2 ;;
            --cred-env)  cred_env="$2"; shift 2 ;;
            --cred-kind) cred_kind="$2"; shift 2 ;;
            --port)      port="$2"; shift 2 ;;
            --env)       envs="${envs}${2}
"; shift 2 ;;
            *) die "cc --add-mcp: unknown option '$1'" ;;
        esac
    done
    mkdir -p "$PROVIDERS_DIR" && chmod 700 "$PROVIDERS_DIR"
    [ -z "$port" ] && port="$(python3 "$SCRIPT_DIR/cc-broker.py" --next-port)"

    CC_ADD_NAME="$name" CC_ADD_URL="$url" CC_ADD_HEADER="$header" CC_ADD_RUN="$run" \
    CC_ADD_CRED_ENV="$cred_env" CC_ADD_CRED_KIND="$cred_kind" CC_ADD_PORT="$port" \
    CC_ADD_ENV="$envs" CC_ADD_DIR="$PROVIDERS_DIR" CC_ADD_BROKER_PY="$SCRIPT_DIR/cc-broker.py" \
    python3 - <<'PY' || return $?
import importlib.util, os, sys
e = os.environ
_spec = importlib.util.spec_from_file_location("ccbroker", e["CC_ADD_BROKER_PY"])
ccb = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(ccb)
name, provdir, port = e["CC_ADD_NAME"], e["CC_ADD_DIR"], int(e["CC_ADD_PORT"])
url, header, run = e["CC_ADD_URL"], e["CC_ADD_HEADER"], e["CC_ADD_RUN"]
# --env KEY=VAL (newline-separated) → extra_env dict; only meaningful for a hosted server.
extra_env = {}
for line in e.get("CC_ADD_ENV", "").splitlines():
    line = line.strip()
    if not line:
        continue
    if "=" not in line:
        sys.exit("--env expects KEY=VAL, got %r" % line)
    k, _, v = line.partition("=")
    if not k.strip():
        sys.exit("--env expects KEY=VAL, got %r" % line)
    extra_env[k.strip()] = v
if url and run:
    sys.exit("give --url (remote MCP) OR --run (hosted MCP), not both.")
if url and extra_env:
    sys.exit("--env only applies to a hosted MCP (--run); a reverse-proxy route has no server to set env on.")
if url:
    hdrname, scheme = "Authorization", "Bearer"
    if header:
        hdrname, _, sc = header.partition(":")
        hdrname, scheme = hdrname.strip(), sc.strip()
    try:
        prov = ccb.synthesize_reverse_proxy(name, url, hdrname, scheme, port)
    except ValueError:
        sys.exit("--url must be an http(s) URL")
elif run:
    if not e["CC_ADD_CRED_ENV"]:
        sys.exit("--run needs --cred-env <ENV> (the env var the server reads its credential from)")
    kind = e["CC_ADD_CRED_KIND"]
    base = "%s.json" % name if kind == "file" else "%s-token" % name
    prov = {
        "id": name, "delivery": "hosted_mcp",
        "credential_kind": "file_path" if kind == "file" else "paste_token",
        "token_basename": base, "host_run": run.split(),
        "credential_env": e["CC_ADD_CRED_ENV"], "mcp_port": port,
        "mcp_path": "/mcp", "mcp_transport": "http", "mcp_server_name": name,
        "extra_env": extra_env,
    }
else:
    sys.exit("give --url <url> (remote MCP) or --run <cmd> --cred-env <ENV> (hosted MCP)")
ccb.write_provider_def(provdir, name, prov)
sys.stderr.write("🔐 wrote provider def %s.json (%s, port %d).\n" % (name, prov["delivery"], port))
PY
    echo "   Now add its credential:  cc --login $name"
}

# Front-line preventer for the pasted vendor command. A user won't learn our flags — they take a
# service's own `claude mcp add … --header "Authorization: …" …` line and swap `claude`→`cc`. Run
# verbatim, that puts the raw secret in the container's argv → in `.claude.json` → readable by
# every session. Nothing INSIDE the box can fix it (a process's argv is already in the box), so we
# catch `mcp add`/`add-json` HERE, host-side, before any docker exec, and do the secure thing.
#
# Tri-state exit — 1 = NOT an intercept, passthrough to a normal launch (the default; a real
# session must never be swallowed); 0 = handled (auto-brokered/staged), cc exits 0; 2 = blocked,
# cc exits 2. Remote header-authed form → auto-broker (reuses mcp_add's synthesis + mcp_adopt's
# mode-600 store). Local/stdio form with a secret `--env` → block, unless CC_ALLOW_INLINE_MCP_SECRET=1.
# Distinct from warn_inline_mcp_secrets (the post-hoc detector for secrets that arrived some other
# way): this one PREVENTS the write. Host-global + identity-free, like `cc --add-mcp`.
intercept_mcp_add() {
    # Cheap bash gate: engage only for `[claude] mcp add|add-json`; everything else passes through.
    local -a a=( "$@" )
    # Drop leading `claude` token(s) (bash-3.2 slice). One is injected by the `cc`=`kib claude`
    # alias; a second appears only if the user also typed it (`cc claude mcp add`) — strip in a
    # loop so that habit can't slip an inline secret past the gate into the container's argv.
    while [ "${a[0]:-}" = claude ]; do a=( "${a[@]:1}" ); done
    [ "${a[0]:-}" = mcp ] || return 1
    case "${a[1]:-}" in add|add-json) ;; *) return 1 ;; esac
    # No python → we can't classify/broker; passthrough (rare: python3 is a broker prerequisite).
    command -v python3 >/dev/null 2>&1 || return 1

    mkdir -p "$PROVIDERS_DIR" && chmod 700 "$PROVIDERS_DIR"
    CC_IC_KIB="$KIB_DIR" CC_IC_DIR="$PROVIDERS_DIR" CC_IC_ALLOW="${CC_ALLOW_INLINE_MCP_SECRET:-0}" \
    CC_IC_BROKER_ON="$(broker_wanted && echo 1 || echo 0)" \
    CC_IC_BROKER_PY="$SCRIPT_DIR/cc-broker.py" \
    CC_IC_NEXT_PORT="$(python3 "$SCRIPT_DIR/cc-broker.py" --next-port 2>/dev/null || echo 8100)" \
    python3 - "${a[@]}" <<'PY'
import importlib.util, json, os, re, sys
env = os.environ
# Shared secret-shape tests + reverse-proxy synthesis live in cc-broker.py (the single source of
# truth, imported here like tests/broker-test.py) so this front-line interceptor and the
# after-the-fact warner can never disagree about what a secret is.
_spec = importlib.util.spec_from_file_location("ccbroker", env["CC_IC_BROKER_PY"])
ccb = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(ccb)

kib, provdir = env["CC_IC_KIB"], env["CC_IC_DIR"]
allow, broker_on = env.get("CC_IC_ALLOW") == "1", env.get("CC_IC_BROKER_ON") == "1"
try:
    port = int(env["CC_IC_NEXT_PORT"])
except ValueError:
    port = 8100
argv = sys.argv[1:]                       # ['mcp', 'add'|'add-json', ...]
sub, rest = argv[1], argv[2:]

# Parse the `claude mcp add` grammar tolerantly. add-json carries a JSON blob instead of flags.
headers, envs, positionals, transport = [], [], [], ""
if sub == "add-json":
    positionals = [t for t in rest if not t.startswith("-")]
    spec = {}
    if len(positionals) >= 2:
        try:
            spec = json.loads(positionals[1])
        except ValueError:
            sys.exit(1)                    # malformed → let claude handle it
    headers = ["%s: %s" % (k, v) for k, v in (spec.get("headers") or {}).items()]
    envs = ["%s=%s" % (k, v) for k, v in (spec.get("env") or {}).items()]
    url = spec.get("url", "")
    name = positionals[0] if positionals else None
    transport = spec.get("type", "")
else:
    i, seen_ddash = 0, False
    while i < len(rest):
        t = rest[i]
        if seen_ddash:
            i += 1; continue               # tokens after `--` are the stdio command
        if t == "--":
            seen_ddash = True; i += 1; continue
        for flag, bucket in (("--header", headers), ("-H", headers), ("--env", envs), ("-e", envs)):
            if t == flag and i + 1 < len(rest):
                bucket.append(rest[i + 1]); i += 2; break
            if t.startswith(flag + "="):
                bucket.append(t.split("=", 1)[1]); i += 1; break
        else:
            if t in ("--transport", "-t") and i + 1 < len(rest):
                transport = rest[i + 1]; i += 2; continue
            if t.startswith("--transport="):
                transport = t.split("=", 1)[1]; i += 1; continue
            if t in ("--scope", "-s") and i + 1 < len(rest):
                i += 2; continue           # ignore scope value
            if t.startswith("-"):
                i += 1; continue           # unknown flag
            positionals.append(t); i += 1
            continue
        continue
    name = positionals[0] if positionals else None
    url = positionals[1] if len(positionals) > 1 else ""

secret_env = [e for e in envs if ccb.env_is_secret(e)]
is_remote = bool(re.match(r"https?://", url))
hname, hval = ccb.find_auth_header(headers)     # picks the auth header wherever it sits (not [0])

# ── Remote + auth header → AUTO-BROKER (secret never enters the box) ──
if is_remote and hval and name:
    scheme = ccb.scheme_of(hval)
    secret = ccb.recover_secret(hval, scheme)
    if not secret:
        sys.exit(1)
    try:
        prov = ccb.synthesize_reverse_proxy(name, url, hname, scheme, port, transport)
    except ValueError:
        sys.exit(1)
    ccb.write_provider_def(provdir, name, prov)
    dest = ccb.store_secret(kib, "%s-token" % name, secret)
    w = sys.stderr.write
    w("🔐 Intercepted an inline MCP credential and brokered it host-side — it never entered the sandbox.\n")
    w("   • '%s' → %s%s (reverse-proxy route, port %d)\n" % (name, prov["upstream_origin"], prov["mcp_path"], port))
    w("   • credential stored host-only: %s (mode 600)\n" % os.path.basename(dest))
    w("   • provider def: providers.d/%s.json\n" % name)
    if broker_on:
        w("   Start a session with `cc` — the agent gets a header-free broker URL, not the token.\n")
    else:
        w("   ⚠️  The broker is OFF, so this route isn't active yet. Enable it, then relaunch:\n")
        w("        echo 'broker = on' >> ~/.keep-it-in-your-box/config\n")
    sys.exit(0)

# ── Local/stdio server with a secret in --env → BLOCK (can't header-broker it) ──
if secret_env:
    if allow:
        sys.exit(1)                        # explicit opt-out: knowingly carry the secret into the box
    w = sys.stderr.write
    nm = name or "<name>"
    w("❌ cc won't carry an inline MCP secret into the sandbox.\n")
    w("   '%s' passes its credential to a LOCAL server via --env, which cc can't broker: the server\n" % nm)
    w("   runs its own code and reads the secret as an env value (and multi-value creds like\n")
    w("   USERNAME+PASSWORD aren't supported yet). Instead:\n")
    w("     • If the service has a remote endpoint, use --header — cc auto-brokers it:\n")
    w('         cc claude mcp add --header "Authorization: Bearer <token>" --transport http %s <url>\n' % nm)
    w('     • Or a single-value hosted server:  cc --add-mcp %s --run "<cmd>" --cred-env <ENV>\n' % nm)
    w("     • To knowingly accept the secret INSIDE the sandbox, re-run with:\n")
    w("         CC_ALLOW_INLINE_MCP_SECRET=1 cc claude mcp add …\n")
    sys.exit(2)

sys.exit(1)                                # no secret to protect → passthrough
PY
    return $?
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
