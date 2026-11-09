#!/usr/bin/env bash
# `.kibignore` redaction + the host-executed-config guard: the view (host/view, run here as an
# NFS server the VM mounts) and the launch-time opt-out report, behind one small interface.
#
# Reads:  KIB_ROOT KIB_VIEW KIB_HOST_ONLY CNAME PWD VIEW_STATE VIEW_MNT PATTERNS_STATE
# Writes: REDACTION_ARGS
# shellcheck disable=SC2034  # REDACTION_ARGS is consumed in host/lifecycle.sh

KIB_RULE_FILE=".kibignore"
KIB_GUARD_FILE_HOST="$KIB_ROOT/guest/policy/global.kibignore"

# The rule checks are the view's own binary, so `.kibignore` has one matcher. The project's rule
# file goes in on stdin, where the arguments say `-`.
_rules() { # <kib-view subcommand args…>
    local f="$PWD/$KIB_RULE_FILE"
    [ -f "$f" ] || f=/dev/null
    [ -x "$KIB_VIEW" ] && "$KIB_VIEW" "$@" <"$f"
}
_optouts() { _rules optouts "$KIB_GUARD_FILE_HOST" -; }

# ── The [redact] opt-out, named at every launch ──────────────────
# `!.env` in a project .kibignore cancels the guard's redaction, and so does a wildcard `!*`, so
# the session reads that file in full. The box can write .kibignore, so the user seeing the rule
# is the only control there is — but keep it to one line per rule: this is a deliberate setting
# on the projects that use it, and an alarm printed at every launch stops being read.
report_kibignore_optouts() {
    [ -f "$PWD/$KIB_RULE_FILE" ] || return 0
    local optouts
    optouts="$(_optouts)" || return 0
    [ -n "$optouts" ] || return 0
    note "ℹ️  $KIB_RULE_FILE un-redacts these for the sandbox — Claude reads them in full:
$(printf '%s\n' "$optouts" | sed 's/^/   !/')"
}

# The rule file the view enforces, staged host-only so the sandbox cannot edit what it is
# validated against, and so the attach-time staleness check has a stable copy.
_stage_patterns() {
    local dst="$1"
    if [ -f "$PWD/$KIB_RULE_FILE" ]; then cp "$PWD/$KIB_RULE_FILE" "$dst"; else : >"$dst"; fi
    chmod 644 "$dst"
}

# Restage, then signal the view to re-read. The staged copy must ALWAYS be what the live layer
# enforces — it is the only record of that — so the old bytes go back if the signal does not land.
#
# Locked at all because an attaching launch and host/rules-watch.sh both write this file. fd
# 204, NOT 202: teardown holds the project lock there while it calls in here (host/lifecycle.sh)
# and 203 is canonical .claude.json's. Never unlinked.
_reload_rules() { # <staged> <why>
    local staged="$1" rc=1
    exec 204>"$staged.lock"
    lock_fd -x 204 || {
        exec 204>&-
        return 1
    }
    if cp "$staged" "$staged.prev"; then
        _stage_patterns "$staged"
        if kill -HUP "$(cat "$VIEW_STATE.pid" 2>/dev/null)" 2>/dev/null; then
            rc=0
        else
            cp "$staged.prev" "$staged"
        fi
        rm -f "$staged.prev"
    fi
    exec 204>&-
    [ "$rc" = 0 ] || return 1
    echo "🛡️  $KIB_RULE_FILE reloaded into the live redaction view — $2." >&2
}

# The one way the LOOSENING direction reaches a running view. `[ -t 0 ]`: a headless launch has
# nobody to ask, and defaulting to yes there would let the box's own edit approve itself.
_confirm_looser_rules() {
    local staged="$1" ans optouts
    [ -t 0 ] || return 1
    warn "$KIB_RULE_FILE changed, and the new rules withhold LESS than the running view."
    diff -u "$staged" "$PWD/$KIB_RULE_FILE" | head -40 | sed 's/^/   /' >&2
    optouts="$(_optouts)" || true
    [ -n "$optouts" ] && printf '%s\n' "$optouts" | sed 's/^/   hands the session: !/' >&2
    echo "   A session in the box can write $KIB_RULE_FILE, so an edit nobody made by hand is" >&2
    echo "   expected here. Applying it is what makes those files readable." >&2
    printf '   Apply to the running redaction view? [y/N] ' >&2
    read -r ans || return 1
    case "$ans" in [yY] | [yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# The rule file changed since the container started, so the running layer is on the OLD rules. A
# change that can only redact MORE is swapped in without asking; anything that could hand the
# session a path it could not read before is the user's call, because the box can write this
# file. If the check cannot run, every edit falls to the prompt — the safe direction.
_reload_or_refuse_stale_rules() {
    local staged="$1"
    cmp -s "$PWD/$KIB_RULE_FILE" "$staged" 2>/dev/null && return 0
    [ ! -f "$PWD/$KIB_RULE_FILE" ] && [ ! -s "$staged" ] && return 0
    if _rules tightens "$staged" - >/dev/null 2>&1; then
        _reload_rules "$staged" "it redacts strictly more" && return 0
    elif _confirm_looser_rules "$staged"; then
        _reload_rules "$staged" "you confirmed it" && return 0
    fi
    die "$KIB_RULE_FILE changed since this project's container started, and the change was" \
        "not applied. The running redaction layer still enforces the OLD rules. Refusing to" \
        "attach — close all kib sessions for this project and relaunch." \
        "A session in the box can edit $KIB_RULE_FILE, so an edit nobody made by hand" \
        "is expected here. The staged copy is what the live layer enforces:" \
        "  diff -u '$staged' '$PWD/$KIB_RULE_FILE'"
}

# ── The redaction layer ──────────────────────────────────────────
# The view runs HERE, as the host user, and serves the project over NFS on a random loopback
# port; VM root mounts it and the box binds that mount at $PWD. So the VM never sees the raw
# project, nothing in it needs SYS_ADMIN or /dev/fuse, and the box stays capless at creation.
# Matched paths refuse writes, including files created AFTER launch, which no bind can cover and
# which a nested `git init` or a mid-session clone relies on. (PLAN_NFS_VIEW.md)
prepare_redaction() {
    local port secret view
    mkdir -p "$STATE_DIR" "${VIEW_STATE%/*}"
    chmod 700 "$STATE_DIR" "$KIB_HOST_ONLY" "${VIEW_STATE%/*}"
    # An absent rule file is an empty rule set, not a reason to skip the layer: it also
    # enforces global.kibignore against writing files the HOST later executes.
    _stage_patterns "$PATTERNS_STATE"
    [ -x "$KIB_VIEW" ] || die "kib's redaction view is not built ($KIB_VIEW). Run: kib build"
    # Rootless Docker cannot mount NFS, so there the view mounts itself with FUSE.
    view=("$KIB_VIEW" nfs --src "$PWD" --patterns-file "$PATTERNS_STATE"
        --guard-file "$KIB_GUARD_FILE_HOST")
    if engine_rootless; then
        view[1]=fuse && view+=(--mnt "$VIEW_MNT") && mkdir -p "$VIEW_MNT"
    fi
    : >"$VIEW_STATE.addr"
    detach_pgrp "${view[@]}" >"$VIEW_STATE.addr" 2>"$VIEW_STATE.log" 200>&- 201>&- 205>&-
    echo $! >"$VIEW_STATE.pid"
    disown 2>/dev/null || true
    wait_until 100 0.05 _view_up || true
    _view_ready || _view_failed "never started"
    if ! engine_rootless; then
        # "<port> <secret>": the secret is the only path it mounts, and only once (nfs.go).
        read -r port secret <"$VIEW_STATE.addr"
        vm_view_mount "$VIEW_MNT" "$port" "$secret" || _view_failed "could not be mounted in the VM"
    fi

    REDACTION_ARGS=(-v "$VIEW_MNT:$PWD")
    echo "🛡️  $KIB_RULE_FILE: redacting view active ($(engine_rootless && echo FUSE || echo NFS))" >&2

    # Carries a later $KIB_RULE_FILE edit into this view without waiting for a launch. The
    # pidfile is NOT bind-mounted into the box: teardown kills whatever group it names. The path
    # stays a LITERAL — tests/check/wiring.sh finds exec'd scripts by grepping this call shape,
    # and a variable hides them from it.
    detach_pgrp "$KIB_ROOT/host/rules-watch.sh" "$VIEW_STATE" 200>&- 201>&- 205>&-
    echo $! >"$PATTERNS_STATE.watch.pid"
    disown 2>/dev/null || true
}

_view_running() { kill -0 "$(cat "$VIEW_STATE.pid" 2>/dev/null)" 2>/dev/null; }
_view_up() { _view_ready || ! _view_running; }
_view_ready() { # NFS: it printed its address. FUSE: its mount is in this host's table.
    if engine_rootless; then grep -q " $VIEW_MNT fuse" /proc/self/mounts; else [ -s "$VIEW_STATE.addr" ]; fi
}

# Never fall through to a raw bind: a launch-time mask cannot cover files created mid-session.
_view_failed() { # <what went wrong>
    echo "❌ kib: the $KIB_RULE_FILE redaction view $1. Its log:" >&2
    sed 's/^/   /' "$VIEW_STATE.log" >&2 2>/dev/null || true
    teardown_redaction
    die "refusing to launch unprotected — without the view neither $KIB_RULE_FILE nor the" \
        "host-config guard is enforced."
}

# Build and install folders (host/lifecycle.sh mounts each on a volume), relative to the project,
# one per line: found in the raw project, fast, then kept only if the VIEW has its parent too, so
# none is ever inside a redacted folder (that mountpoint would fail the launch). Never descends
# into one. A root node_modules or .venv the manifest implies counts before the first install.
LOCAL_DIR_NAMES="node_modules .pnpm-store .next .nuxt .turbo target .terraform .venv venv"
local_dirs() {
    local n names="" d found=()
    for n in $LOCAL_DIR_NAMES; do names="$names -o -name $n"; done
    # shellcheck disable=SC2086 # one argument per name
    while IFS= read -r d; do found+=("$d"); done < <(
        find . -mindepth 1 -maxdepth 6 -name .git -prune -o -type d \( ${names# -o } \) \
            -print -prune 2>/dev/null
        [ ! -f package.json ] || [ -e node_modules ] || echo ./node_modules
        if [ -f pyproject.toml ] || [ -f requirements.txt ]; then
            [ -e .venv ] || echo ./.venv
        fi
    )
    [ "${#found[@]}" = 0 ] || vm_view_has "$VIEW_MNT" ${found[@]+"${found[@]}"}
}

# Three things must hold to attach: the view is up (it is unconditional, so its absence is
# always an error, including for a container an older kib left running), it reaches the BOX, and
# the rules match — or can be reloaded into — what is running. global.kibignore cannot go stale:
# the view reads it from the checkout, as this process does.
verify_redaction_attach() {
    if ! _view_running || ! docker exec "$CNAME" ls -A "$PWD" >/dev/null 2>&1; then
        die "this project's container has no live redaction view, so neither" \
            "$KIB_RULE_FILE nor the host-config guard is being enforced in it." \
            "Refusing to attach — close all kib sessions for this project and relaunch." \
            "(A container created by an older kib will always land here.)"
    fi
    _reload_or_refuse_stale_rules "$PATTERNS_STATE"
}

# Unmount first, then stop the view: a soft mount of a dead server only times out. Also runs
# defensively at every cold start, so only when this project left something behind.
teardown_redaction() {
    [ -e "$VIEW_STATE.pid" ] || [ -e "$PATTERNS_STATE" ] || return 0
    # First: the watcher must not signal a view being torn down out from under it.
    kill_pgrp "$PATTERNS_STATE.watch.pid" # whole group: it is its own (detach_pgrp)
    vm_view_unmount "$VIEW_MNT"
    kill_pgrp "$VIEW_STATE.pid"
    rm -f "$PATTERNS_STATE" "$PATTERNS_STATE.prev" "$VIEW_STATE.addr" 2>/dev/null || true
}
