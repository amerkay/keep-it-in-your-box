#!/usr/bin/env bash
# Inhibits system sleep while a Claude session in the container is actively producing
# output; an idle session still lets the machine sleep.
#
# Activity = the `wchar` counter (bytes written) of the *busiest single process* in this
# terminal's session, growing. Measured, per 3s poll: idle session 218-374B, mid-turn
# spinner 1.4-2.4KB, streaming 3.5KB+. MIN_BYTES sits in that gap with ~4x headroom.
#
# Scoped to this terminal's session, NOT the whole container. One container serves every
# terminal on the project, so a container-wide sample makes one working session inhibit on
# behalf of all N terminals — three tabs, three redundant locks, only one of them earned.
# `cc` stamps its session with a unique CC_SESSION_TAG, which claude's tools and subagents
# inherit across fork/exec; matching on /proc/<pid>/environ therefore answers "is this pid
# ours" without walking ppids, and without a pid registry to keep in step.
#
# Busiest, NOT the sum — the sum is what pinned sleep overnight. Summing over any set that
# grows (the container's pids, or one session's subagents) crosses a fixed threshold once
# the set is big enough, however idle each member is; the max is flat in N. The same
# aggregation bug, not the choice of signal, also killed an attempt at summing CPU ticks.
#
# Only pids present in *both* consecutive samples count: a pid appearing mid-interval has
# no baseline, so its lifetime total would read as one huge delta.
#
# Two non-obvious constraints:
#   - `docker logs` is useless here: PID 1 is `sleep infinity` and each session runs
#     under `docker exec`, whose output goes to that terminal's TTY, never the log stream.
#   - the sampling exec runs as the *host uid* deliberately: /proc/<pid>/io and
#     /proc/<pid>/environ are gated by ptrace_may_access, which root-without-
#     CAP_SYS_PTRACE fails against a uid-1000 process, while a same-uid reader passes.
#
# Usage: sleep-guard.sh <container-name> <session-tag>
#   SLEEP_GUARD_GRACE=30        seconds of quiet before releasing the inhibitor
#   SLEEP_GUARD_MIN_BYTES=1024  bytes per poll, by one process, that count as "active"
#   SLEEP_GUARD_DEBUG=1         print every sample, to sanity-check the thresholds

CONTAINER="${1:?Usage: sleep-guard.sh <container-name> <session-tag>}"
TAG="${2:?Usage: sleep-guard.sh <container-name> <session-tag>}"
POLL=3
GRACE="${SLEEP_GUARD_GRACE:-30}"
MIN_BYTES="${SLEEP_GUARD_MIN_BYTES:-1024}"
DEBUG="${SLEEP_GUARD_DEBUG:-0}"

INHIBIT_PID=""
LAST_ACTIVE=0
declare -A PREV_WCHAR=()

release_lock() {
    if [ -n "$INHIBIT_PID" ] && kill -0 "$INHIBIT_PID" 2>/dev/null; then
        kill "$INHIBIT_PID" 2>/dev/null
        wait "$INHIBIT_PID" 2>/dev/null || true
        INHIBIT_PID=""
    fi
}

acquire_lock() {
    if [ -z "$INHIBIT_PID" ] || ! kill -0 "$INHIBIT_PID" 2>/dev/null; then
        systemd-inhibit --what=sleep --who="claude-code" \
            --why="Claude Code is producing output" sleep infinity &
        INHIBIT_PID=$!
    fi
}

# "<pid> <bytes-written>" for each process in *our* session; empty if none (the session
# has not started yet, or has exited) or if the container is unreachable.
#
# The tag goes in via -e rather than being interpolated into the sh -c body, so no shell
# quoting of it can go wrong. It is read back under a *different* name (CC_GUARD_TAG), so
# the sampling shell's own environ cannot match the CC_SESSION_TAG= pattern and count
# itself as session activity.
#
# grep -z makes each NUL-terminated environ entry a line, so ^...$ anchors to a whole
# entry — an exact match, never a prefix of some other terminal's tag.
# -H forces the filename prefix even if only one file matches, so the parse can't shift.
sample_wchar() {
    docker exec --user "$(id -u)" -e CC_GUARD_TAG="$TAG" "$CONTAINER" sh -c '
        grep -lz "^CC_SESSION_TAG=$CC_GUARD_TAG$" /proc/[0-9]*/environ 2>/dev/null \
            | sed "s|/environ$|/io|" \
            | xargs -r grep -H "^wchar:" 2>/dev/null
    ' 2>/dev/null | awk -F'[/:]' '{print $3, $NF + 0}'
}

trap 'release_lock; exit 0' EXIT INT TERM

# Wait for container to exist (up to 30s)
for _ in $(seq 1 60); do
    docker inspect "$CONTAINER" &>/dev/null && break
    sleep 0.5
done
docker inspect "$CONTAINER" &>/dev/null || exit 1

while docker inspect "$CONTAINER" &>/dev/null; do
    NOW=$(date +%s)
    BUSIEST=0
    declare -A CUR_WCHAR=()

    # A here-string, not a pipe: a pipe would run this loop in a subshell and discard
    # every array update it makes, so PREV_WCHAR would stay empty forever.
    while read -r PID BYTES; do
        [ -z "$PID" ] && continue
        CUR_WCHAR["$PID"]="$BYTES"
        PREV="${PREV_WCHAR[$PID]:-}"
        [ -z "$PREV" ] && continue      # new pid: no baseline, no interval to measure
        DELTA=$((BYTES - PREV))
        [ "$DELTA" -gt "$BUSIEST" ] && BUSIEST=$DELTA
    done <<< "$(sample_wchar)"

    [ "$DEBUG" = 1 ] && \
        echo "[sleep-guard] busiest process in session +${BUSIEST}B this poll (active if ≥${MIN_BYTES}B, ${#CUR_WCHAR[@]} pids), inhibit=${INHIBIT_PID:-none}" >&2

    # No baseline yet (first poll, or the session has not started) leaves BUSIEST at 0,
    # and LAST_ACTIVE at 0 blocks the release branch — so a fresh guard neither inhibits
    # on a stale lifetime total nor releases a lock it never took.
    if [ "$BUSIEST" -ge "$MIN_BYTES" ]; then
        acquire_lock
        LAST_ACTIVE=$NOW
    elif [ "$LAST_ACTIVE" -gt 0 ] && [ $((NOW - LAST_ACTIVE)) -ge "$GRACE" ]; then
        release_lock
    fi

    # Replace wholesale, so dead pids age out instead of accumulating forever. An empty
    # sample (session gone, or docker hiccup) therefore reads as quiet and releases after
    # GRACE — erring towards letting the machine sleep, never towards pinning it awake.
    unset PREV_WCHAR; declare -A PREV_WCHAR=()
    for PID in "${!CUR_WCHAR[@]}"; do PREV_WCHAR["$PID"]="${CUR_WCHAR[$PID]}"; done
    unset CUR_WCHAR

    sleep "$POLL"
done

release_lock
