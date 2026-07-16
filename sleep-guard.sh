#!/usr/bin/env bash
# Inhibits system sleep while a Claude session in the container is actively producing
# output; an idle session still lets the machine sleep.
#
# Activity = the `wchar` counter (bytes written) of the *busiest single process* in the
# container, growing. Measured, per 3s poll: idle session 218-374B, mid-turn spinner
# 1.4-2.4KB, streaming 3.5KB+. MIN_BYTES sits in that gap with ~4x headroom either side.
#
# Busiest, NOT the container sum — the sum is what pinned sleep overnight. One container
# serves every terminal on the project, so N idle tabs sum to N x ~300B and cross any
# fixed threshold once N grows; the max is flat in N. (The same aggregation bug, not the
# choice of signal, also killed an attempt at summing CPU ticks.)
#
# Only pids present in *both* consecutive samples count: a pid appearing mid-interval has
# no baseline, so its lifetime total would read as one huge delta. That matters because
# resolv-sync.sh respawns a grep every 3s, so the container always has fresh pids.
#
# Two non-obvious constraints:
#   - `docker logs` is useless here: PID 1 is `sleep infinity` and each session runs
#     under `docker exec`, whose output goes to that terminal's TTY, never the log stream.
#   - the sampling exec runs as the *host uid* deliberately: /proc/<pid>/io is gated by
#     ptrace_may_access, which root-without-CAP_SYS_PTRACE fails against a uid-1000
#     process, while a same-uid reader passes.
#
# Known gap: every terminal on the project runs its own guard and they all sample the same
# container, so one working session makes all N guards inhibit. Redundant but correct —
# they release together. Scoping a pid to the terminal that owns it is not worth the code.
#
# Usage: sleep-guard.sh <container-name>
#   SLEEP_GUARD_GRACE=30        seconds of quiet before releasing the inhibitor
#   SLEEP_GUARD_MIN_BYTES=1024  bytes per poll, by one process, that count as "active"
#   SLEEP_GUARD_DEBUG=1         print every sample, to sanity-check the thresholds

CONTAINER="${1:?Usage: sleep-guard.sh <container-name>}"
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

# "<pid> <bytes-written>" per process in the container; empty if unreadable.
# -H forces the filename prefix even if only one file matches, so the parse can't shift.
sample_wchar() {
    docker exec --user "$(id -u)" "$CONTAINER" \
        sh -c 'grep -H "^wchar:" /proc/[0-9]*/io 2>/dev/null' 2>/dev/null \
        | awk -F'[/:]' '{print $3, $NF + 0}'
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
    SAMPLE="$(sample_wchar)"

    if [ -n "$SAMPLE" ]; then
        BUSIEST=0
        declare -A CUR_WCHAR=()
        # A here-string, not a pipe: a pipe would run this in a subshell and discard
        # every array update it makes, so PREV_WCHAR would stay empty forever.
        while read -r PID BYTES; do
            [ -z "$PID" ] && continue
            CUR_WCHAR["$PID"]="$BYTES"
            PREV="${PREV_WCHAR[$PID]:-}"
            [ -z "$PREV" ] && continue      # new pid: no baseline, no interval to measure
            DELTA=$((BYTES - PREV))
            [ "$DELTA" -gt "$BUSIEST" ] && BUSIEST=$DELTA
        done <<< "$SAMPLE"

        # The first sample only sets baselines: a container that has been up for a while
        # has large wchar totals that say nothing about activity right now.
        if [ "${#PREV_WCHAR[@]}" -gt 0 ]; then
            [ "$DEBUG" = 1 ] && \
                echo "[sleep-guard] busiest process +${BUSIEST}B this poll (active if ≥${MIN_BYTES}B), inhibit=${INHIBIT_PID:-none}" >&2

            if [ "$BUSIEST" -ge "$MIN_BYTES" ]; then
                acquire_lock
                LAST_ACTIVE=$NOW
            elif [ "$LAST_ACTIVE" -gt 0 ] && [ $((NOW - LAST_ACTIVE)) -ge "$GRACE" ]; then
                release_lock
            fi
        fi

        # Replace wholesale, so dead pids age out instead of accumulating forever.
        unset PREV_WCHAR; declare -A PREV_WCHAR=()
        for PID in "${!CUR_WCHAR[@]}"; do PREV_WCHAR["$PID"]="${CUR_WCHAR[$PID]}"; done
        unset CUR_WCHAR
    fi

    sleep "$POLL"
done

release_lock
