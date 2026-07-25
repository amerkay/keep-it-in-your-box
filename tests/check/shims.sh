#!/usr/bin/env bash
# Sourced by tests/check.sh — unit tests for host/portable.sh's shims, with the perl/darwin
# paths FORCED so both OS code paths are exercised on this one Linux machine (perl behaves
# identically there).
#
# KIB_OS is saved and restored around the section: everything after it in the run would
# otherwise silently execute the macOS branches too.

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

t_lockfd() {
    local tmp tmp2 tmp3 hp t0 t1
    tmp="$(mktemp)"
    exec 200>"$tmp"
    if lock_fd -n -x 200; then pass "lock_fd: acquire -n -x"; else fail "lock_fd acquire"; fi
    if flock -n -x "$tmp" -c true 2>/dev/null; then
        fail "lock_fd: lock did not persist across the shim call"
    else
        pass "lock_fd: lock persists via the held fd (OFD semantics)"
    fi
    lock_fd -u 200
    if flock -n -x "$tmp" -c true 2>/dev/null; then pass "lock_fd: -u releases"; else fail "lock_fd -u"; fi
    exec 200>&-

    # timeout: hold it elsewhere, -w1 must fail in ~1s
    tmp2="$(mktemp)"
    flock -x "$tmp2" -c "sleep 3" &
    hp=$!
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
    flock -x "$tmp3" -c "sleep 2" &
    hp=$!
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
t_busiest
t_wait_until

KIB_OS="$_saved_os"
unset _saved_os
