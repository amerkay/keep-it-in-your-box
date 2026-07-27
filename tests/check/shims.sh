#!/usr/bin/env bash
# Sourced by tests/check.sh — unit tests for host/portable.sh's shims, with the perl/darwin
# paths FORCED so both OS code paths are exercised on this one Linux machine (perl behaves
# identically there).
#
# KIB_OS is saved and restored around the section: everything after it in the run would
# otherwise silently execute the macOS branches too.

# shellcheck source=SCRIPTDIR/_guard.sh
. "${BASH_SOURCE%/*}/_guard.sh" # sourced by tests/check.sh, never run directly

section "Shim unit tests (host/portable.sh, darwin paths forced)"

# shellcheck disable=SC2034  # host/portable.sh's preflight reads it; unused on Linux
IMAGE_NAME=unused
# shellcheck source=SCRIPTDIR/../../host/core.sh
. "$KIB_ROOT/host/core.sh"
# shellcheck source=SCRIPTDIR/../../host/portable.sh
. "$KIB_ROOT/host/portable.sh"
_saved_os="$KIB_OS"
KIB_OS=darwin # force the perl/BSD shims

t_hash8() {
    local h
    h="$(hash8 hello)"
    if [ "$h" = 2cf24dba ]; then
        pass "hash8: sha256 first 8"
    else
        fail "hash8" "got '$h', want 2cf24dba"
    fi
}

# Oracle. NOT flock(1): it is GNU-only, so on a real Mac every call here failed
# "command not found" — which read as "the lock is held", turning two assertions into false
# passes and three into false failures. The suite looked like it was testing lock_fd and was
# testing nothing. perl is the one flock binding present on both platforms (it is what the
# darwin shim itself uses, and `preflight_platform` already requires it on macOS).
_probe_locked() { # true if the file is locked by SOMEONE ELSE
    ! perl -e '
        open(my $fh, "<", $ARGV[0]) or exit 2;
        exit(flock($fh, 2 | 4) ? 0 : 1);   # LOCK_EX | LOCK_NB
    ' "$1" 2>/dev/null
}

_hold_lock() { # <file> <seconds> — background holder, echoes its pid
    # stdout redirected, or the command substitution that reads the pid would block until the
    # holder exits — the pipe stays open as long as a child holds it.
    perl -e '
        open(my $fh, ">", $ARGV[0]) or exit 2;
        flock($fh, 2) or exit 2;           # LOCK_EX, blocking
        sleep $ARGV[1];
    ' "$1" "$2" >/dev/null 2>&1 &
    echo $!
}

t_lockfd() {
    local tmp tmp2 tmp3 hp t0 t1
    tmp="$(mktemp)"
    exec 200>"$tmp"
    if lock_fd -n -x 200; then pass "lock_fd: acquire -n -x"; else fail "lock_fd acquire"; fi
    if _probe_locked "$tmp"; then
        pass "lock_fd: lock persists via the held fd (OFD semantics)"
    else
        fail "lock_fd: lock did not persist across the shim call"
    fi
    lock_fd -u 200
    if _probe_locked "$tmp"; then fail "lock_fd -u"; else pass "lock_fd: -u releases"; fi
    exec 200>&-

    # timeout: hold it elsewhere, -w1 must fail in ~1s
    tmp2="$(mktemp)"
    hp="$(_hold_lock "$tmp2" 3)"
    sleep 0.3
    exec 201>"$tmp2"
    t0="$(date +%s)"
    if lock_fd -w 1 -s 201; then
        fail "lock_fd: -w1 acquired a held exclusive lock"
    else
        pass "lock_fd: -w1 -s times out on a held lock"
    fi
    t1="$(date +%s)"
    [ "$((t1 - t0))" -le 2 ] || warn "lock_fd -w1 waited $((t1 - t0))s (expected ~1)"
    exec 201>&-
    kill "$hp" 2>/dev/null
    wait "$hp" 2>/dev/null || true

    # file form: flock -n FILE CMD (the check_for_updates probe)
    tmp3="$(mktemp)"
    if lock_fd -n "$tmp3" true; then
        pass "lock_fd: file-form succeeds on a free lock"
    else
        fail "lock_fd file-form (free)"
    fi
    hp="$(_hold_lock "$tmp3" 2)"
    sleep 0.3
    if lock_fd -n "$tmp3" true; then
        fail "lock_fd: file-form succeeded on a held lock"
    else
        pass "lock_fd: file-form fails on a held lock"
    fi
    kill "$hp" 2>/dev/null
    wait "$hp" 2>/dev/null || true
    rm -f "$tmp" "$tmp2" "$tmp3"
}

t_detach() {
    detach_pgrp sleep 5
    local pid=$! pgid
    sleep 0.3 # let perl load POSIX, setsid, then exec — else ps races a pre-setsid read
    pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
    if [ -n "$pid" ] && [ "$pgid" = "$pid" ]; then
        pass "detach_pgrp: child is its own process-group leader (kill -\$! works)"
    else
        fail "detach_pgrp" "pid=$pid pgid=$pgid (want equal)"
    fi
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
}

# A detached daemon must inherit NO descriptor above stderr, and the shim must guarantee it on
# its own — note this deliberately passes no `200>&- 201>&-`. Closing by number at the call site
# is not enough on macOS: bash 3.2 saves an fd redirected on a *function call* to a dup >=10 for
# the post-call restore without close-on-exec, so the child inherited the project lock as fd 10.
# The clipboard bridge then held it for life, and since teardown is what kills the bridge,
# teardown could never run — containers stranded until killed by hand.
#
# Probed on fd 3, not 200: bash >=4 sets close-on-exec on fds >9, so the real fd cannot leak on
# this Linux box at all — which is precisely why the bug was macOS-only. Low fds carry no such
# flag, so they reproduce the inheritance the shim has to sever.
t_detach_fds() {
    local d
    d="$(mktemp -d)"
    exec 3>"$d/leak"
    detach_pgrp /bin/sh -c 'printf LEAKED 2>/dev/null >&3'
    sleep 0.3
    exec 3>&-
    if [ -s "$d/leak" ]; then
        fail "detach_pgrp leaks inherited fds to the daemon" \
            "a daemon holding the project lock blocks the teardown that would kill it"
    else
        pass "detach_pgrp: the daemon inherits no fd above stderr (lock cannot leak)"
    fi
    rm -rf "$d"
}

# kill_pgrp undoes detach_pgrp. `kill -TERM -$pid` from a pidfile is only safe while the pid is
# still OURS: a detached child that exited frees it, Linux recycles numbers near-sequentially, and
# the group it then names was kib's own — one launch SIGTERMed itself right after the banner, with
# no message and no container. Both guards are load-bearing, so both are tested.
t_kill_pgrp() {
    local d pid child ours
    d="$(mktemp -d)"

    detach_pgrp sleep 5
    pid=$!
    sleep 0.3
    echo "$pid" >"$d/live.pid"
    kill_pgrp "$d/live.pid"
    sleep 0.2
    if kill -0 "$pid" 2>/dev/null; then
        fail "kill_pgrp does not kill its own detached group" "pid=$pid survived"
        kill -TERM "-$pid" 2>/dev/null || true
    else
        pass "kill_pgrp: reaps a detach_pgrp'd group"
    fi
    if [ -e "$d/live.pid" ]; then
        fail "kill_pgrp leaves the pidfile behind" "$d/live.pid"
    else
        pass "kill_pgrp: drops the pidfile"
    fi

    # The shipped bug, exactly: a recycled number that happens to name kib's own group.
    ours="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
    echo "$ours" >"$d/self.pid"
    kill_pgrp "$d/self.pid" # a suicide here takes the whole check run with it
    pass "kill_pgrp: refuses our own process group"

    # A recycled pid usually names an ordinary child, not a group leader — spare it.
    sleep 5 &
    child=$!
    echo "$child" >"$d/recycled.pid"
    kill_pgrp "$d/recycled.pid"
    sleep 0.2
    if kill -0 "$child" 2>/dev/null; then
        pass "kill_pgrp: spares a pid that does not lead its group"
    else
        fail "kill_pgrp signals a group it does not own" "killed non-leader $child"
    fi
    kill "$child" 2>/dev/null
    wait "$child" 2>/dev/null || true

    is "kill_pgrp: empty pidfile path is a no-op" 0 "$(kill_pgrp '' && echo 0)"
    rm -rf "$d"
}

# The sleep guard's metric, called through the SHARED implementation both it and
# host/sleep-monitor.sh source — so this covers the diagnostic's copy too, which is the whole
# reason the sampler was extracted.
t_busiest() {
    # shellcheck source=SCRIPTDIR/../../host/sleep-sample.sh
    . "$KIB_ROOT/host/sleep-sample.sh"
    is "busiest_delta: max over pids in both samples" 300 \
        "$(kib_busiest_delta "$(printf '100 1000\n200 2000\n')" "$(printf '100 1300\n200 2050\n300 9999\n')")"
    is "busiest_delta: ignores a pid with no baseline" 10 \
        "$(kib_busiest_delta "$(printf '100 1000\n')" "$(printf '100 1010\n999 500000\n')")"
    is "busiest_delta: empty prev → 0" 0 "$(kib_busiest_delta '' '100 5000')"
    is "busiest_delta: empty cur → 0" 0 "$(kib_busiest_delta '100 5000' '')"
}

# wait_until is the one polling helper the four hand-rolled loops collapsed into.
t_wait_until() {
    local n=0
    _t_third_try() {
        n=$((n + 1))
        [ "$n" -ge 3 ]
    }
    if wait_until 10 0.01 _t_third_try; then
        pass "wait_until: returns 0 as soon as the predicate succeeds"
    else
        fail "wait_until: never saw the predicate succeed"
    fi
    if wait_until 3 0.01 false; then
        fail "wait_until: returned 0 for a predicate that never succeeds"
    else
        pass "wait_until: returns non-zero after the try budget"
    fi
}

t_hash8
t_lockfd
t_detach
t_detach_fds
t_kill_pgrp
t_busiest
t_wait_until

KIB_OS="$_saved_os"
unset _saved_os
