#!/usr/bin/env bash
# Inhibits system sleep while a Docker container is actively producing output.
# Polls "docker logs --since" to detect new output — no root needed, works with TTY.
# Usage: sleep-guard.sh <container-name>

CONTAINER="${1:?Usage: sleep-guard.sh <container-name>}"
POLL=3          # seconds between polls
GRACE=30        # seconds of inactivity before releasing lock
INHIBIT_PID=""
LAST_ACTIVE=0

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

trap 'release_lock; exit 0' EXIT INT TERM

# Wait for container to exist (up to 30s)
for _ in $(seq 1 60); do
    docker inspect "$CONTAINER" &>/dev/null && break
    sleep 0.5
done
docker inspect "$CONTAINER" &>/dev/null || exit 1

while docker inspect "$CONTAINER" &>/dev/null; do
    BYTES=$(docker logs --since "${POLL}s" "$CONTAINER" 2>&1 | wc -c)
    NOW=$(date +%s)

    if [ "$BYTES" -gt 0 ]; then
        acquire_lock
        LAST_ACTIVE=$NOW
    elif [ "$LAST_ACTIVE" -gt 0 ] && [ $((NOW - LAST_ACTIVE)) -ge "$GRACE" ]; then
        release_lock
    fi

    sleep "$POLL"
done

release_lock
