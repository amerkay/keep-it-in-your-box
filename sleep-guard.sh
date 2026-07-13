#!/usr/bin/env bash
# Inhibits system sleep while a Claude session in the container is actively producing
# output; an idle session still lets the machine sleep.
#
# Activity = the `wchar` counter (bytes written) summed over every process in the
# container, growing. Two non-obvious constraints:
#   - `docker logs` is useless here: PID 1 is `sleep infinity` and each session runs
#     under `docker exec`, whose output goes to that terminal's TTY, never the log stream.
#   - the sampling exec runs as the *host uid* deliberately: /proc/<pid>/io is gated by
#     ptrace_may_access, which root-without-CAP_SYS_PTRACE fails against a uid-1000
#     process, while a same-uid reader passes.
#
# Usage: sleep-guard.sh <container-name>
#   SLEEP_GUARD_GRACE=30        seconds of quiet before releasing the inhibitor
#   SLEEP_GUARD_MIN_BYTES=1024  bytes per poll that count as "active" (filters idle
#                               TUI repaints, which are ~24B)
#   SLEEP_GUARD_DEBUG=1         print every sample, to sanity-check the thresholds

CONTAINER="${1:?Usage: sleep-guard.sh <container-name>}"
POLL=3
GRACE="${SLEEP_GUARD_GRACE:-30}"
MIN_BYTES="${SLEEP_GUARD_MIN_BYTES:-1024}"
DEBUG="${SLEEP_GUARD_DEBUG:-0}"

INHIBIT_PID=""
LAST_ACTIVE=0
PREV=-1

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

# Total bytes written by every process in the container; empty if unreadable.
sample_wchar() {
    docker exec --user "$(id -u)" "$CONTAINER" \
        sh -c 'cat /proc/[0-9]*/io 2>/dev/null' 2>/dev/null \
        | awk '/^wchar:/ {s += $2} END {if (NR) print s+0}'
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
    CUR="$(sample_wchar)"

    if [ -n "$CUR" ]; then
        # The first sample only sets a baseline: a container that has been up for a
        # while has a large wchar total that says nothing about activity right now.
        if [ "$PREV" -ge 0 ]; then
            DELTA=$((CUR - PREV))
            [ "$DEBUG" = 1 ] && \
                echo "[sleep-guard] +${DELTA}B this poll (active if ≥${MIN_BYTES}B), inhibit=${INHIBIT_PID:-none}" >&2

            if [ "$DELTA" -ge "$MIN_BYTES" ]; then
                acquire_lock
                LAST_ACTIVE=$NOW
            elif [ "$LAST_ACTIVE" -gt 0 ] && [ $((NOW - LAST_ACTIVE)) -ge "$GRACE" ]; then
                release_lock
            fi
        fi
        PREV="$CUR"
    fi

    sleep "$POLL"
done

release_lock
