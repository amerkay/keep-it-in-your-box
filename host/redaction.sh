#!/usr/bin/env bash
# `.kibignore` redaction + the host-executed-config guard: the .gitignore sync and the host
# half of the in-container FUSE mount, behind one three-function interface.
#
# Reads:  KIB_ROOT CNAME PWD STATE_DIR PATTERNS_STATE
# Writes: REDACTION_ARGS
# shellcheck disable=SC2034  # REDACTION_ARGS is consumed in host/lifecycle.sh

KIB_RULE_FILE=".kibignore"
KIB_GUARD_FILE_HOST="$KIB_ROOT/guest/policy/global.kibignore"

# ── .kibignore → .gitignore ──────────────────────────────────────
# .kibignore hides paths from the container, but nothing stops git committing them on the host.
# .gitignore blocks untracked files from being added; already-tracked ones are the audit gate's
# job. Both anchor at the git toplevel, hence the subdir skip.
#
# The translation is kib.shared.rules — the same parser the FUSE server uses, so anchoring,
# negation and unsafe-rule skipping cannot drift. This function owns only the block placement.
sync_kibignore_gitignore() {
    [ -f "$PWD/$KIB_RULE_FILE" ] || return 0
    have_python || return 0
    local top
    top="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$top" ] || return 0 # not a git repo — nothing to sync
    if [ "$(realpath "$top" 2>/dev/null || echo "$top")" \
        != "$(realpath "$PWD" 2>/dev/null || echo "$PWD")" ]; then
        echo "ℹ️  $KIB_RULE_FILE: launched from a subdir of the git repo; skipping the" >&2
        echo "   .gitignore sync (it anchors at the repo root)." >&2
        return 0
    fi

    local patterns
    patterns="$(kib_py shared.rules to-gitignore "$PWD/$KIB_RULE_FILE")" || {
        warn "could not translate $KIB_RULE_FILE to .gitignore patterns; left .gitignore alone."
        return 0
    }

    local gi="$PWD/.gitignore" rest=""
    local b="# >>> kibignore (auto-synced by kib — do not edit this block) >>>"
    local e="# <<< kibignore (auto-synced by kib) <<<"
    # Strip every marker kib has ever written, not just the current one: a leftover `ccignore`
    # block would live forever alongside the new one, re-ignoring paths since removed.
    [ -f "$gi" ] && rest="$(awk '
        /^# >>> (cc|kib)ignore \(auto-synced/ { skip = 1; next }
        /^# <<< (cc|kib)ignore \(auto-synced/ { skip = 0; next }
        !skip { print }' "$gi")"
    {
        [ -n "$rest" ] && printf '%s\n' "$rest"
        if [ -n "$patterns" ]; then
            printf '%s\n' "$b"
            printf '%s\n' "# Mirrors $KIB_RULE_FILE so paths hidden from the sandbox are never committed."
            printf '%s\n' "$patterns"
            printf '%s\n' "$e"
        fi
    } >"$gi.kib.tmp" && mv "$gi.kib.tmp" "$gi"
}

# ── The redaction layer ──────────────────────────────────────────
# kib.guest.fuse runs INSIDE the one project container, started by
# guest/entrypoint/entrypoint-fuse.sh — which mounts the view over $PWD, drops SYS_ADMIN and
# SETPCAP from the bounding set, then gosu's to the capless agent. Matched paths refuse writes,
# including files created AFTER launch, which no bind mount can cover and which a nested
# `git init` or a mid-session clone relies on.
#
# It is deliberately NOT a second container reached by shared-mount propagation: propagation is
# a shared-kernel feature, so that topology could never run on macOS and forecloses every
# hypervisor-isolated substrate. See docs/design-notes/microvm.md.
#
# So the host side is only: stage the rules, and add the flags the entrypoint needs.

# The rule file the container enforces, staged host-side so the sandbox cannot edit what it
# is validated against, and so the attach-time staleness check has a stable copy.
_stage_patterns() {
    local dst="$1"
    if [ -f "$PWD/$KIB_RULE_FILE" ]; then cp "$PWD/$KIB_RULE_FILE" "$dst"; else : >"$dst"; fi
    chmod 644 "$dst"
}

# The rule file changed since the container started → the running layer enforces the OLD
# rules. $1 is the staged copy to compare against.
_refuse_if_rules_stale() {
    local staged="$1"
    cmp -s "$PWD/$KIB_RULE_FILE" "$staged" 2>/dev/null && return 0
    [ ! -f "$PWD/$KIB_RULE_FILE" ] && [ ! -s "$staged" ] && return 0
    die "$KIB_RULE_FILE changed since this project's container started." \
        "The running redaction layer still enforces the OLD rules. Refusing to" \
        "attach — close all kib sessions for this project and relaunch."
}

prepare_redaction() {
    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
    # An absent rule file is an empty rule set, not a reason to skip the layer: it also
    # enforces global.kibignore against writing files the HOST later executes. Gating it on
    # the rule file is what left every project without one — this repo included — on a raw
    # bind mount with no protection.
    _stage_patterns "$PATTERNS_STATE"

    # NO -v for $PWD — the entrypoint mounts the redacted view there. The real project sits at
    # /kib/real under a root-700 parent the agent cannot traverse. SYS_ADMIN + /dev/fuse last
    # only until the mount is up; SETPCAP then lets the entrypoint drop both from the bounding
    # set, so the agent tree is provably not SYS_ADMIN-capable. docker-default apparmor denies
    # the mount, hence unconfined.
    REDACTION_ARGS=(
        -v "$PWD:/kib/real"
        -v "$PATTERNS_STATE:/kib/patterns:ro"
        -v "$KIB_ROOT/kib:/usr/local/lib/kib:ro"
        -v "$KIB_GUARD_FILE_HOST:/usr/local/share/global.kibignore:ro"
        --cap-add=SYS_ADMIN
        --cap-add=SETPCAP
        --device /dev/fuse
        --security-opt apparmor=unconfined
        -e KIB_FUSE_INTERNAL=1
        -e KIB_FUSE_MNT="$PWD"
    )
    echo "🛡️  $KIB_RULE_FILE: FUSE redaction active (mounted in-container at $PWD)" >&2
}

_die_no_redaction() {
    die "this project's container is not running kib's redaction layer, so neither" \
        "$KIB_RULE_FILE nor the host-config guard is being enforced in it." \
        "Refusing to attach — close all kib sessions for this project and relaunch." \
        "(A container created by an older kib will always land here.)"
}

# Two things must hold to attach: the layer is THIS kib's (not a container an older kib left
# running), and its rules have not changed since creation.
verify_redaction_attach() {
    # The env check is what discriminates. An older kib served the same view from a separate
    # container over shared-mount propagation, so its container also has a fuse fs at $PWD and
    # the mount probe alone would wave it through — then the session would die in `setpriv`,
    # which needs caps that container was never given.
    #
    # Captured, not piped into `grep -q`: under `set -o pipefail` an early-exiting grep can
    # SIGPIPE `docker inspect`, failing the pipeline on a container that is perfectly fine.
    local env_lines
    env_lines="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' \
        "$CNAME" 2>/dev/null || true)"
    case $'\n'"$env_lines"$'\n' in
        *$'\nKIB_FUSE_INTERNAL=1\n'*) ;;
        *) _die_no_redaction ;;
    esac

    # Mount still alive. Compared after `readlink -f` INSIDE the container: the entrypoint's
    # HOST_HOME symlink means the kernel records the mount under its resolved path, so a raw
    # compare against $PWD would spuriously fail.
    docker exec "$CNAME" sh -c '
        p=$(readlink -f "$1" 2>/dev/null || echo "$1")
        while read -r _dev _mp _fstype _rest; do
            [ "$_mp" = "$p" ] || continue
            case "$_fstype" in fuse*) exit 0 ;; esac
        done < /proc/self/mounts
        exit 1
    ' _ "$PWD" 2>/dev/null || _die_no_redaction

    _refuse_if_rules_stale "$PATTERNS_STATE"
}

# The mount lives and dies with the container, so there is nothing to unmount here — only the
# host-side state file remains.
teardown_redaction() {
    rm -f "$PATTERNS_STATE" 2>/dev/null || true
}
