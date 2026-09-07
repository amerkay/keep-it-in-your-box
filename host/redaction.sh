#!/usr/bin/env bash
# `.kibignore` redaction + the host-executed-config guard: the FUSE sidecar and the launch-time
# opt-out report, behind one small interface.
#
# Reads:  KIB_ROOT IMAGE_NAME CNAME FUSE_CNAME FUSE_ROOT PWD STATE_DIR PATTERNS_STATE
#         PASSWD_STATE GROUP_STATE
# Writes: REDACTION_ARGS
# shellcheck disable=SC2034  # REDACTION_ARGS is consumed in host/lifecycle.sh

KIB_RULE_FILE=".kibignore"
KIB_GUARD_FILE_HOST="$KIB_ROOT/guest/policy/global.kibignore"

# ── The [redact] opt-out, named at every launch ──────────────────
# `!.env` in a project .kibignore cancels the guard's redaction (kib.shared.rules), so the
# session reads that file in full. The box can write .kibignore, so the user seeing the rule is
# the only control there is — but keep it to one line per rule: this is a deliberate setting on
# the projects that use it, and an alarm printed at every launch stops being read.
report_kibignore_optouts() {
    [ -f "$PWD/$KIB_RULE_FILE" ] || return 0
    have_python || return 0
    local optouts
    optouts="$(kib_py shared.rules optouts "$KIB_GUARD_FILE_HOST" "$PWD/$KIB_RULE_FILE")" || return 0
    [ -n "$optouts" ] || return 0
    echo "ℹ️  $KIB_RULE_FILE un-redacts these for the sandbox — Claude reads them in full:" >&2
    printf '%s\n' "$optouts" | sed 's/^/   !/' >&2
}

# ── The redaction layer ──────────────────────────────────────────
# kib.guest.fuse runs in its OWN container — the sidecar — and the agent's container consumes
# the view by shared-mount propagation. Matched paths refuse writes, including files created
# AFTER launch, which no bind mount can cover and which a nested `git init` or a mid-session
# clone relies on.
#
# ONLY the sidecar gets SYS_ADMIN, /dev/fuse and an AppArmor override, and it runs as the host
# user with --network none. The agent's container keeps `--cap-drop=ALL` under docker-default,
# has no mount capability at any point in its life, and no FUSE server beside it to pivot into.
#
# The one platform-sensitive part is WHERE the propagation root lives: on macOS it must be a
# path the engine serves from inside its VM rather than from the Mac over virtiofs. That choice,
# and the mount/unmount primitives, are fuse_root_path/fuse_root_create/unmount_fuse in
# host/portable.sh. Everything below is shared. (docs/design-notes/macos.md)

# The rule file the sidecar enforces, staged host-side so the sandbox cannot edit what it
# is validated against, and so the attach-time staleness check has a stable copy.
_stage_patterns() {
    local dst="$1"
    if [ -f "$PWD/$KIB_RULE_FILE" ]; then cp "$PWD/$KIB_RULE_FILE" "$dst"; else : >"$dst"; fi
    chmod 644 "$dst"
}

# fusermount3 resolves getpwuid(getuid()) and aborts with "could not determine username" when
# the uid is unknown to the image — which a host uid always is. Binding the HOST's /etc/passwd
# (as kib once did) works on Linux and CANNOT work on macOS, where Open Directory keeps real
# users out of that file, so uid 501 is missing there too. Two synthesised lines instead: same
# code on both platforms, and nothing of the host's user table enters the container.
_stage_passwd() {
    {
        printf 'root:x:0:0:root:/root:/bin/bash\n'
        printf '%s:x:%s:%s::/tmp:/bin/sh\n' "$(id -un)" "$(id -u)" "$(id -g)"
    } >"$PASSWD_STATE"
    {
        printf 'root:x:0:\n'
        printf '%s:x:%s:\n' "$(id -gn)" "$(id -g)"
    } >"$GROUP_STATE"
    chmod 644 "$PASSWD_STATE" "$GROUP_STATE"
}

# One wording for the two callers that meet a view they could not unmount: teardown (warn — see
# teardown_redaction) and the next launch (die — see prepare_redaction). $1 is the emitter.
_stale_mount_report() { # <die|warn>
    "$1" "a $KIB_RULE_FILE redaction mount is still live at" \
        "  $FUSE_ROOT/mnt" \
        "and could not be unmounted. It is a passthrough view of your project, so kib will" \
        "neither delete it (that would delete the real files) nor stack a second view on it." \
        "Clear it by hand, then relaunch — on Linux:" \
        "  fusermount3 -u '$FUSE_ROOT/mnt' || sudo umount -l '$FUSE_ROOT/mnt'" \
        "On macOS that path lives inside the Docker engine VM and the Mac cannot see it;" \
        "restart the engine to clear it."
}

# Restage, then signal the sidecar to re-read. The staged copy must ALWAYS be what the live
# layer enforces — it is the only record of that — so the old bytes go back if the signal does
# not land. `cp` both ways, never `mv`: the sidecar's bind is of this INODE, so a rename leaves
# the host on the old rules while the container reads the new ones. Inverted, and silent.
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
        if docker kill -s HUP "$FUSE_CNAME" >/dev/null 2>&1; then
            rc=0
        else
            cp "$staged.prev" "$staged"
        fi
        rm -f "$staged.prev"
    fi
    exec 204>&-
    [ "$rc" = 0 ] && echo "🛡️  $KIB_RULE_FILE reloaded into the live redaction view — $2." >&2
    return "$rc"
}

# The one way the LOOSENING direction reaches a running view. `[ -t 0 ]`: a headless launch has
# nobody to ask, and defaulting to yes there would let the box's own edit approve itself.
_confirm_looser_rules() {
    local staged="$1" ans optouts
    [ -t 0 ] || return 1
    warn "$KIB_RULE_FILE changed, and the new rules withhold LESS than the running view."
    diff -u "$staged" "$PWD/$KIB_RULE_FILE" | head -40 | sed 's/^/   /' >&2
    optouts="$(kib_py shared.rules optouts "$KIB_GUARD_FILE_HOST" "$PWD/$KIB_RULE_FILE")" || true
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
# file. Without python the gate fails and every edit falls to the prompt — the safe direction.
_reload_or_refuse_stale_rules() {
    local staged="$1"
    cmp -s "$PWD/$KIB_RULE_FILE" "$staged" 2>/dev/null && return 0
    [ ! -f "$PWD/$KIB_RULE_FILE" ] && [ ! -s "$staged" ] && return 0
    if kib_py shared.rules tightens "$staged" "$PWD/$KIB_RULE_FILE"; then
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

prepare_redaction() {
    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
    # An absent rule file is an empty rule set, not a reason to skip the layer: it also
    # enforces global.kibignore against writing files the HOST later executes. Gating it on
    # the rule file is what left every project without one — this repo included — on a raw
    # bind mount with no protection.
    _stage_patterns "$PATTERNS_STATE"
    _stage_passwd

    # A view teardown could not unmount is still live over the real project. Refuse HERE rather
    # than stack a second mount on it — teardown only warns, so that it can never abort the exit
    # path before merge_out_session.
    ! fuse_mounted "$FUSE_ROOT/mnt" || _stale_mount_report die

    # Dies with instructions if the root cannot propagate; never escalates, never degrades.
    fuse_root_create "$FUSE_ROOT" "$(id -u)" "$(id -g)"

    # --uid/--gid: the ids reported in place of whoever owns the project ROOT, and only them. On
    # macOS the project reaches the sidecar over the engine VM's virtiofs, which reports every
    # file as root:root — without the remap git refuses the whole tree ("dubious ownership") and
    # nothing that shells out to it works. On Linux the base ids are already the agent's, so the
    # map is identity. A file owned by someone else keeps its real ids, so the mount's
    # default_permissions still refuses it.
    local run_err
    if ! run_err="$(docker run -d --name "$FUSE_CNAME" \
        --cap-drop=ALL --cap-add=SYS_ADMIN \
        --device /dev/fuse --security-opt apparmor=unconfined \
        --user "$(id -u):$(id -g)" --userns=host \
        --network none \
        -v "$PWD:/src" \
        -v "$PATTERNS_STATE:/kib-patterns:ro" \
        -v "$PASSWD_STATE:/etc/passwd:ro" \
        -v "$GROUP_STATE:/etc/group:ro" \
        -v "$FUSE_ROOT:$FUSE_ROOT:rshared" \
        -v "$KIB_ROOT/kib:/usr/local/lib/kib:ro" \
        -v "$KIB_GUARD_FILE_HOST:/usr/local/share/global.kibignore:ro" \
        --entrypoint /usr/local/bin/fuse \
        "$IMAGE_NAME" \
        --src /src --mnt "$FUSE_ROOT/mnt" \
        --uid "$(id -u)" --gid "$(id -g)" \
        --patterns-file /kib-patterns \
        --guard-file /usr/local/share/global.kibignore 2>&1 >/dev/null)"; then
        fuse_root_destroy "$FUSE_ROOT"
        # The engine's own words, or a name clash / missing /dev/fuse / unshared source mount
        # all read as the same blank failure.
        die "could not start the $KIB_RULE_FILE redaction sidecar." "${run_err:-(no output)}"
    fi

    # Poll the SIDECAR's own mount table, not the root: a `docker exec` is cheap on both
    # platforms, where on macOS every look at the root costs a privileged VM helper. Then check
    # the root ONCE, which is the assertion that actually matters — the sidecar seeing its own
    # mount says nothing about whether it propagated out, and that is precisely how the old
    # /tmp-rooted layout failed on a Mac.
    if ! wait_until 100 0.05 _sidecar_mounted_or_gone || ! _sidecar_mounted \
        || ! fuse_mounted "$FUSE_ROOT/mnt"; then
        echo "❌ kib: the $KIB_RULE_FILE redaction view never reached $FUSE_ROOT/mnt." >&2
        echo "   Sidecar logs:" >&2
        docker logs "$FUSE_CNAME" 2>&1 | sed 's/^/   /' >&2 || true
        docker rm -f "$FUSE_CNAME" >/dev/null 2>&1 || true
        fuse_root_destroy "$FUSE_ROOT"
        # Never fall through to a bind-mounted fallback: a launch-time mask cannot cover files
        # created mid-session, so it would silently weaken the redaction the user relies on.
        die "refusing to launch unprotected — without the sidecar neither $KIB_RULE_FILE nor" \
            "the host-config guard is enforced."
    fi

    # :rslave, not :rshared — the view propagates IN, and a mount the agent somehow made would
    # not propagate back out to the host.
    REDACTION_ARGS=(-v "$FUSE_ROOT/mnt:$PWD:rslave")
    echo "🛡️  $KIB_RULE_FILE: FUSE redacting mount active (sidecar: $FUSE_CNAME)" >&2

    # Carries a later $KIB_RULE_FILE edit into this view without waiting for a launch. The
    # pidfile is in $STATE_DIR, NOT bind-mounted into the box: teardown kills whatever group it
    # names. The path stays a LITERAL — tests/check/wiring.sh finds exec'd scripts by grepping
    # this call shape, and a variable hides them from it.
    detach_pgrp "$KIB_ROOT/host/rules-watch.sh" "$PATTERNS_STATE" "$FUSE_CNAME" 200>&- 201>&-
    echo $! >"$PATTERNS_STATE.watch.pid"
    disown 2>/dev/null || true
}

sidecar_running() { [ -n "$(docker ps -q -f "name=^${FUSE_CNAME}$" 2>/dev/null)" ]; }

# Is there a fuse fs at <path>, as <container> sees it? One probe, two callers: readiness
# polling in the SIDECAR, and the attach check in the AGENT's container. Written twice once,
# which left the attach-time copy — the one keeping a second terminal out of a container whose
# view was unmounted underneath it — free to go stale on its own.
_fuse_mounted_in() { # <container> <path>
    docker exec "$1" sh -c '
        p=$(readlink -f "$1" 2>/dev/null || echo "$1")
        while read -r _d _m _t _r; do
            [ "$_m" = "$p" ] || continue
            case "$_t" in fuse*) exit 0 ;; esac
        done </proc/self/mounts
        exit 1' _ "$2" 2>/dev/null
}

# Zero-arg wrapper: `wait_until … _sidecar_mounted_or_gone` calls it by name.
_sidecar_mounted() { _fuse_mounted_in "$FUSE_CNAME" "$FUSE_ROOT/mnt"; }

# Mounted, or dead — either way waiting longer is pointless. A sidecar that exited on a bad
# argument would otherwise cost 100 failing `docker exec`s before anyone said so.
_sidecar_mounted_or_gone() { _sidecar_mounted || ! sidecar_running; }

# Three things must hold to attach: the sidecar is up (it is unconditional, so its absence is
# always an error — including for a container an older kib left running), the view actually
# reached the AGENT's container, and the rules match — or can be reloaded into — what is running.
# global.kibignore cannot go stale: it mounts :ro from the checkout, so the sidecar and this
# process read the very same file.
verify_redaction_attach() {
    # A live sidecar says nothing about the agent's side: the propagated mount can be gone
    # (unmounted underneath us) while its container still runs, leaving $PWD as the bare
    # mountpoint. Asked in the AGENT's container, so it is the consuming end that answers, and
    # `docker exec` costs the same on both platforms — unlike a probe of the root on macOS.
    if ! sidecar_running || ! _fuse_mounted_in "$CNAME" "$PWD"; then
        die "this project's container has no live redaction view, so neither" \
            "$KIB_RULE_FILE nor the host-config guard is being enforced in it." \
            "Refusing to attach — close all kib sessions for this project and relaunch." \
            "(A container created by an older kib will always land here.)"
    fi
    _reload_or_refuse_stale_rules "$PATTERNS_STATE"
}

# Did this project ever get a sidecar? teardown_redaction also runs defensively on the cold-start
# path, and on macOS every probe of the root costs a privileged VM helper — so answer from local
# state first. The state file is removed LAST, after the unmount, so a leak cannot hide behind it.
_redaction_present() {
    [ -e "$PATTERNS_STATE" ] && return 0
    [ -n "$(docker ps -aq -f "name=^${FUSE_CNAME}$" 2>/dev/null)" ]
}

# unmount_fuse first (host-side, and the only option once the sidecar is gone), then from INSIDE
# the sidecar: its bind is rshared, so an unmount there propagates back out. That second path is
# what covers a host with no fusermount3 of its own — the mount was made by the sidecar's copy,
# so the host is not required to carry one.
_unmount_view() {
    unmount_fuse "$FUSE_ROOT/mnt" && return 0
    sidecar_running || return 1
    docker exec "$FUSE_CNAME" fusermount3 -u "$FUSE_ROOT/mnt" >/dev/null 2>&1 || true
    ! fuse_mounted "$FUSE_ROOT/mnt"
}

# Unmount BEFORE removing the sidecar. The other order kills the server first, leaving a
# mounted-but-ENOTCONN mount that gets skipped and orphaned on EVERY exit — and the next launch
# then dies on the rm below. Confirmed live on Docker Desktop: the mount outlives the container.
teardown_redaction() {
    _redaction_present || return 0
    # First: the watcher must not signal a sidecar being torn down out from under it.
    kill_pgrp "$PATTERNS_STATE.watch.pid" # whole group: it is its own (detach_pgrp)
    if ! _unmount_view; then
        # WARN, never die: this runs from the EXIT trap, ahead of merge_out_session — aborting
        # here would lose the session's .claude.json/history fold-back and overwrite its exit
        # code. Everything below is skipped instead, so nothing is deleted and nothing is
        # forgotten; the next launch refuses on the same mount (prepare_redaction).
        _stale_mount_report warn
        return 0
    fi
    docker rm -f "$FUSE_CNAME" >/dev/null 2>&1 || true
    # `|| true` throughout: never let a failed cleanup kill kib under `set -e` — least of all
    # from the EXIT trap, where it would also overwrite the session's exit code.
    fuse_root_destroy "$FUSE_ROOT"
    rm -f "$PATTERNS_STATE" "$PATTERNS_STATE.prev" "$PASSWD_STATE" "$GROUP_STATE" \
        2>/dev/null || true
}
