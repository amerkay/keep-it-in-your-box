#!/usr/bin/env bash
# `.kibignore` redaction + the host-executed-config guard: the .gitignore sync, mount
# probing, and both FUSE backends behind one three-function interface.
#
# Reads:  KIB_ROOT KIB_FUSE_MODE IMAGE_NAME PWD FUSE_CNAME FUSE_ROOT STATE_DIR PATTERNS_STATE
# Writes: PROJECT_MOUNT_SRC PROJECT_MOUNT_OPTS REDACTION_ARGS
# shellcheck disable=SC2034  # the three mount globals are consumed in host/lifecycle.sh

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

# ── Mount probing ────────────────────────────────────────────────
# Ask the kernel directly. `mountpoint -q` is NOT usable: after the FUSE server dies the mount
# stays in the table but stat() returns ENOTCONN, so mountpoint says "not a mountpoint" for a
# directory that still is one — and the unmount gets skipped.
fuse_mounted() {
    awk -v p="$1" '$2 == p { found = 1 } END { exit !found }' /proc/self/mounts 2>/dev/null
}

unmount_fuse() {
    local m="$1"
    fuse_mounted "$m" || return 0
    fusermount3 -u "$m" 2>/dev/null \
        || fusermount -u "$m" 2>/dev/null \
        || umount -l "$m" 2>/dev/null || true # lazy: last resort for a dead server
    ! fuse_mounted "$m"
}

# ── The mode interface ───────────────────────────────────────────
# kib.guest.fuse is served two ways, chosen once by KIB_FUSE_MODE. Both share the SAME server,
# matcher, guard file and stale-rules refusal — only the topology differs:
#
#   sidecar (Linux): server in its own cap-drop=ALL container, reaching the main container by
#     shared-mount propagation. Strongest isolation.
#   single (macOS): no propagation available, so the server runs inside the one project
#     container, started by guest/entrypoint/entrypoint-fuse.sh — which mounts the view, drops
#     SYS_ADMIN from the bounding set, then gosu's to the capless agent.
prepare_redaction() {
    if [ "$KIB_FUSE_MODE" = single ]; then _prepare_redaction_single; else _prepare_redaction_sidecar; fi
}
verify_redaction_attach() {
    if [ "$KIB_FUSE_MODE" = single ]; then _verify_redaction_attach_single; else _verify_redaction_attach_sidecar; fi
}
teardown_redaction() {
    if [ "$KIB_FUSE_MODE" = single ]; then _teardown_redaction_single; else _teardown_redaction_sidecar; fi
}

# The rule file the container enforces, staged host-side so the sandbox cannot edit what it
# is validated against, and so the attach-time staleness check has a stable copy.
_stage_patterns() {
    local dst="$1"
    if [ -f "$PWD/$KIB_RULE_FILE" ]; then cp "$PWD/$KIB_RULE_FILE" "$dst"; else : >"$dst"; fi
    chmod 644 "$dst"
}

# The rule file changed since the container started → the running layer enforces the OLD
# rules. Shared by both modes; $1 is the staged copy to compare against.
_refuse_if_rules_stale() {
    local staged="$1"
    cmp -s "$PWD/$KIB_RULE_FILE" "$staged" 2>/dev/null && return 0
    [ ! -f "$PWD/$KIB_RULE_FILE" ] && [ ! -s "$staged" ] && return 0
    die "$KIB_RULE_FILE changed since this project's container started." \
        "The running redaction layer still enforces the OLD rules. Refusing to" \
        "attach — close all kib sessions for this project and relaunch."
}

# ── single-container mode ────────────────────────────────────────
# No sidecar, no host-side mount, no propagation. kib only stages the rules and adds the
# flags the entrypoint needs; entrypoint-fuse.sh does the mount in-container.
_prepare_redaction_single() {
    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
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
    PROJECT_MOUNT_SRC="" # signal start_container to add no $PWD bind
    echo "🛡️  $KIB_RULE_FILE: single-container FUSE redaction (mounted in-container at $PWD)" >&2
}

# Mount alive (a fuse fs at $PWD) + rules unchanged since creation. Compared after `readlink -f`
# INSIDE the container: the entrypoint's HOST_HOME symlink means the kernel records the mount
# under its resolved path, so a raw compare against $PWD would spuriously fail.
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
            "$KIB_RULE_FILE nor the host-config guard is being enforced in it." \
            "Refusing to attach — close all kib sessions for this project and relaunch." \
            "(A container created by an older kib will always land here.)"
    fi
    _refuse_if_rules_stale "$PATTERNS_STATE"
}

# The mount died with the container; only the host state file remains.
_teardown_redaction_single() {
    rm -f "$PATTERNS_STATE" 2>/dev/null || true
}

# ── sidecar mode ─────────────────────────────────────────────────
# The passthrough runs in its own container, exposed to the main one by shared-mount
# propagation. Matched paths refuse writes — including files created AFTER launch, which no
# bind mount can cover and which a nested `git init` or mid-session clone relies on. Only the
# sidecar gets SYS_ADMIN + /dev/fuse; the main container keeps cap-drop=ALL.
_prepare_redaction_sidecar() {
    # Always on, even with no rule file: the sidecar also enforces global.kibignore against
    # writing files the HOST later executes. Gating it on the rule file is what left every
    # project without one — this repo included — on a raw bind mount with no protection.

    # /tmp must propagate shared or the sidecar's mount never reaches the main container.
    # No fallback: a launch-time bind mask cannot cover files created mid-session, so a
    # downgrade here would silently weaken a redaction the user is relying on.
    local prop
    prop="$(findmnt -no PROPAGATION --target /tmp 2>/dev/null || true)"
    if [[ "$prop" != *shared* ]]; then
        die "kib needs /tmp to be a shared mount for $KIB_RULE_FILE redaction and the" \
            "host-config guard, but it is '${prop:-unknown}'. Fix it with:" \
            "  sudo mount --make-shared /tmp" \
            "To make that survive a reboot, add a systemd drop-in at" \
            "/etc/systemd/system/tmp.mount.d/shared.conf or mount it shared in fstab."
    fi

    # 755 on both: the sidecar runs as our uid, but the main container traverses this path as
    # root before dropping privileges. (`-m` with `-p` would only apply to the deepest dir.)
    mkdir -p "$FUSE_ROOT/mnt"
    chmod 755 "$FUSE_ROOT" "$FUSE_ROOT/mnt"
    # An absent rule file is an empty rule set, not a reason to skip the sidecar. The guard
    # file is NOT copied — it mounts :ro straight from the checkout, so there is no second
    # copy to keep in step.
    _stage_patterns "$FUSE_ROOT/patterns"

    if ! docker run -d --name "$FUSE_CNAME" \
        --cap-drop=ALL --cap-add=SYS_ADMIN \
        --device /dev/fuse --security-opt apparmor=unconfined \
        --user "$(id -u):$(id -g)" --userns=host \
        --network none \
        -v "$PWD:/src" \
        -v "$FUSE_ROOT:$FUSE_ROOT:rshared" \
        -v /etc/passwd:/etc/passwd:ro \
        -v /etc/group:/etc/group:ro \
        -v "$KIB_ROOT/kib:/usr/local/lib/kib:ro" \
        -v "$KIB_GUARD_FILE_HOST:/usr/local/share/global.kibignore:ro" \
        --entrypoint /usr/local/bin/fuse \
        "$IMAGE_NAME" \
        --src /src --mnt "$FUSE_ROOT/mnt" \
        --patterns-file "$FUSE_ROOT/patterns" \
        --guard-file /usr/local/share/global.kibignore >/dev/null; then
        rm -rf "$FUSE_ROOT"
        echo "❌ $KIB_RULE_FILE: could not start FUSE sidecar. Aborting." >&2
        exit 1
    fi

    if ! wait_until 100 0.05 fuse_mounted "$FUSE_ROOT/mnt"; then # ≤5s for the mount
        echo "❌ $KIB_RULE_FILE: FUSE sidecar failed to mount; sidecar logs:" >&2
        docker logs "$FUSE_CNAME" 2>&1 | sed 's/^/   /' >&2 || true
        docker rm -f "$FUSE_CNAME" >/dev/null 2>&1 || true
        rm -rf "$FUSE_ROOT"
        # Never fall through to a leaky fallback: that would silently downgrade the
        # redaction the user asked for.
        echo "   Refusing to launch unprotected: without the sidecar neither $KIB_RULE_FILE" >&2
        echo "   nor the host-config guard is enforced. Aborting." >&2
        exit 1
    fi

    PROJECT_MOUNT_SRC="$FUSE_ROOT/mnt"
    PROJECT_MOUNT_OPTS=":rslave"
    echo "🛡️  $KIB_RULE_FILE: FUSE redacting mount active (sidecar: $FUSE_CNAME)" >&2
}

# The sidecar is unconditional, so its absence is always an error. Only the project's rule file
# can go stale — global.kibignore mounts :ro from the checkout, so the sidecar and this process
# read the very same file.
_verify_redaction_attach_sidecar() {
    if ! sidecar_running; then
        die "this project's container was started without the redaction sidecar, so" \
            "neither $KIB_RULE_FILE nor the host-config guard is being enforced in it." \
            "Refusing to attach — close all kib sessions for this project and relaunch." \
            "(A container created by an older kib will always land here.)"
    fi
    _refuse_if_rules_stale "$FUSE_ROOT/patterns"
}

# Unmount BEFORE removing the sidecar. The other order kills the server first, leaving a
# mounted-but-ENOTCONN mount that gets skipped and orphaned on EVERY exit — and the next launch
# then dies on the rm below.
_teardown_redaction_sidecar() {
    if ! unmount_fuse "$FUSE_ROOT/mnt"; then
        die "a $KIB_RULE_FILE redaction mount is still mounted at" \
            "  $FUSE_ROOT/mnt" \
            "and could not be unmounted. Refusing to delete it: that path is a" \
            "passthrough view of your project, so removing it while mounted would" \
            "delete the real files. Clear it by hand, then relaunch:" \
            "  fusermount3 -u '$FUSE_ROOT/mnt' || sudo umount -l '$FUSE_ROOT/mnt'"
    fi
    docker rm -f "$FUSE_CNAME" >/dev/null 2>&1 || true
    # `|| true`: never let a failed cleanup kill kib under `set -e` — least of all from the
    # EXIT trap, where it would also overwrite the session's exit code.
    rm -rf "$FUSE_ROOT" 2>/dev/null || true
}
