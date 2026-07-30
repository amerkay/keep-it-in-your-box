#!/usr/bin/env bash
# Holds a sleep inhibitor while a Claude session is working; releases when it is waiting on the
# user. On Linux, going idle with the lid already shut also suspends the machine — see
# suspend_if_lid_shut(). macOS re-evaluates sleep when caffeinate releases, so needs no such
# re-trigger. (docs/design-notes/sleep-guard.md)
#
# Activity comes from CLAUDE'S OWN STATE MACHINE and from NOTHING ELSE: the hooks in
# guest/policy/managed-settings.json → guest/policy/sleep-hook.py, read by host/sleep-state.sh.
# It replaced a sampler that measured `wchar` (bytes written to the terminal) and inferred
# "working" from the volume. That inference had two holes no threshold could close: a
# BACKGROUND SUBAGENT writes almost nothing to the terminal, so N agents grinding read as idle
# and the machine slept mid-work; and a question waiting on the user looks exactly like a long
# think, so it either pinned the machine awake or slept mid-turn depending on the threshold.
#
# The poll costs one stat of a marker tree — no subprocess, no `docker exec`, no CLI call. That
# is deliberate and load-bearing: byte sampling, transcript mtime and `claude agents --json`
# were each tried and each dropped (sleep-guard.md), and a power-saving daemon that forks every
# 3s is working against itself. There is no fallback: markers or nothing.
#
# Scoped to one terminal's session by KIB_SESSION_TAG, which the hook inherits from the
# session's environ: one container serves every terminal, so a container-wide state would have
# three tabs take three locks for one tab's work.
#
# Usage: sleep-guard.sh <container-name> <session-tag> <state-root>
#   SLEEP_GUARD_GRACE=1        seconds of quiet before releasing the inhibitor
#   SLEEP_GUARD_DEBUG=1         print every sample
#   SLEEP_GUARD_LID_SUSPEND=1   (LINUX) suspend on going idle with the lid shut; 0 disables
#   SLEEP_GUARD_SETTLE=1       (LINUX) seconds after a resume before a re-suspend is allowed;
#                               a tighter cycle wedges AMD s2idle

CONTAINER="${1:?Usage: sleep-guard.sh <container-name> <session-tag> <state-root>}"
TAG="${2:?Usage: sleep-guard.sh <container-name> <session-tag> <state-root>}"
STATE_ROOT="${3:?Usage: sleep-guard.sh <container-name> <session-tag> <state-root>}"
# Names this box in the desktop's "blocking sleep" popup. The guard is backgrounded from
# kib_run_session, so $PWD is the project — the same directory the box is mounted at.
PROJECT_NAME="$(basename "$PWD")"
POLL=3
GRACE="${SLEEP_GUARD_GRACE:-30}"
DEBUG="${SLEEP_GUARD_DEBUG:-0}"
LID_SUSPEND="${SLEEP_GUARD_LID_SUSPEND:-1}"
SETTLE="${SLEEP_GUARD_SETTLE:-15}" # (LINUX) after a resume, stay awake this long before re-suspending
# The guard is launched BEFORE the session it watches, so the markers are legitimately absent
# for the first few seconds of every launch. Warn only once that window has passed, or the
# warning fires on every single launch and means nothing.
UNKNOWN_WARN=90

# KIB_OS / is_macos come from host/portable.sh. Sourced loudly: this used to carry a uname
# fallback "in case the source fails", but portable.sh sets both before its only failure path
# (an unreadable $KIB_CONFIG) can be reached, so the fallback only ever redefined them
# identically — while costing this file an exemption from the all-OS-branching-in-portable.sh
# check. A genuinely missing portable.sh is already fatal everywhere else (host/_load.sh).
HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/portable.sh
# `|| exit 1`: this script has no `set -e`, so an unguarded source of a missing portable.sh
# would carry on with is_macos undefined and die mid-poll instead of at startup.
. "$HOST_DIR/portable.sh" || exit 1
# shellcheck source=SCRIPTDIR/sleep-state.sh
. "$HOST_DIR/sleep-state.sh" || exit 1

INHIBIT_PID=""
LAST_ACTIVE=0
AWAKE_SINCE=0 # epoch of the last resume (or 0 = never suspended since start); gates re-suspend
LAST_LOOP=0   # epoch of the previous loop iteration; a jump >> POLL means we were suspended
STARTED=$(date +%s)
WARNED=0

release_lock() {
    if [ -n "$INHIBIT_PID" ] && kill -0 "$INHIBIT_PID" 2>/dev/null; then
        kill "$INHIBIT_PID" 2>/dev/null
        wait "$INHIBIT_PID" 2>/dev/null || true
        INHIBIT_PID=""
    fi
}

# Linux: a systemd-inhibit block held by a background sleep. macOS: `caffeinate -is`. Both
# release by killing the child; macOS then re-evaluates sleep itself.
#
# WHO stays the bare token `claude-code`, WITH NO SPACES — host/sleep-monitor.sh finds the
# field equal to it and reads the PID three fields further on, so any space here shifts that
# offset and the diagnostic silently stops finding our locks. The identity goes in WHY, which
# is the part desktops render in parentheses ("<who> is blocking sleep. (<why>)") — so the
# popup names the project and the tag, and that tag is the same one `sleep-monitor` prints.
acquire_lock() {
    if [ -z "$INHIBIT_PID" ] || ! kill -0 "$INHIBIT_PID" 2>/dev/null; then
        if is_macos; then
            caffeinate -is &
        else
            systemd-inhibit --what=sleep --who="claude-code" \
                --why="kib sandbox $PROJECT_NAME — session $TAG" \
                sleep infinity &
        fi
        INHIBIT_PID=$!
    fi
}

# A --what=sleep block survives a lid close — the point — but logind fires that suspend
# exactly ONCE and never retries after we release, so a task finishing lid-shut leaves the
# machine awake all night. Re-issue it ourselves on going idle, only where unambiguous:
#   - lid actually shut (open lid + idle is PowerDevil's job, never force it);
#   - no external display (docked lid-shut means "keep working");
#   - no *other* kib session still holding a lock.
# Non-kib block inhibitors are still honoured, and this runs every idle poll, so a blocked
# attempt simply succeeds once the blocker clears. LINUX ONLY.
lid_closed() {
    grep -qi 'closed' /proc/acpi/button/lid/*/state 2>/dev/null
}
external_display() { # any connected output that is not the internal panel
    local f st
    for f in /sys/class/drm/*/status; do
        [ -r "$f" ] || continue
        read -r st <"$f" 2>/dev/null || continue
        [ "$st" = connected ] || continue
        case "$f" in *eDP* | *LVDS* | *DSI*) ;; *) return 0 ;; esac
    done
    return 1
}
other_kib_working() { # a different session's guard still holds a claude-code lock
    systemd-inhibit --list 2>/dev/null | grep -q 'claude-code'
}
suspend_if_lid_shut() {
    is_macos && return
    [ "$LID_SUSPEND" = 1 ] || return
    lid_closed || return
    external_display && return
    other_kib_working && return
    [ "$DEBUG" = 1 ] && echo "[sleep-guard] idle + lid shut, no external display or other session — suspending" >&2
    # Sibling guards can reach here on the same idle tick, each seeing no *other* lock.
    # logind honours the first and answers the rest "Action suspend already in progress,
    # refusing" — expected, so swallow it rather than leak it into the session's terminal.
    if [ "$DEBUG" = 1 ]; then
        systemctl suspend || true
    else
        systemctl suspend 2>/dev/null || true
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
    NOW=$(date +%s)

    # A resume looks like the poll sleep overrunning — the guard is frozen through the
    # machine's suspend. Re-suspending on the first idle poll after a wake wedges AMD s2idle
    # (hard hang, power-cycle to recover), so arm a settle window on any such jump. Suspends
    # we issue ourselves are re-detected here too, so there is no loop.
    if [ "$LAST_LOOP" -gt 0 ] && [ $((NOW - LAST_LOOP)) -gt $((POLL + 5)) ]; then
        AWAKE_SINCE=$NOW
        [ "$DEBUG" = 1 ] && echo "[sleep-guard] resume detected (slept $((NOW - LAST_LOOP))s) — settling ${SETTLE}s before any re-suspend" >&2
    fi
    LAST_LOOP=$NOW

    STATE="$(kib_sleep_state "$STATE_ROOT" "$TAG")"

    # `unknown` reads as idle. There is no fallback and nothing to cross-check by design: a
    # guard that cannot see state must let the machine sleep, never pin it awake on a tree it
    # knows nothing about. It costs nothing at launch, where LAST_ACTIVE is still 0 and the
    # release branch below cannot fire anyway.
    if [ "$STATE" = unknown ]; then
        if [ "$WARNED" = 0 ] && [ $((NOW - STARTED)) -ge "$UNKNOWN_WARN" ]; then
            WARNED=1
            echo "[sleep-guard] still no hook state ${UNKNOWN_WARN}s after launch — the" \
                "managed-settings hooks are not loading, so this machine may sleep while" \
                "Claude is working. Check /status inside the box for a 'Managed' setting" \
                "source, and that /etc/claude-code/managed-settings.json is mounted." >&2
        fi
        STATE=idle
    fi

    [ "$DEBUG" = 1 ] \
        && echo "[sleep-guard] state=${STATE} inhibit=${INHIBIT_PID:-none}" >&2

    if [ "$STATE" = busy ]; then
        acquire_lock
        LAST_ACTIVE=$NOW
    elif [ "$LAST_ACTIVE" -gt 0 ] && [ $((NOW - LAST_ACTIVE)) -ge "$GRACE" ]; then
        release_lock
        # Honour the lid-close we blocked, unless we resumed less than SETTLE ago.
        if [ "$AWAKE_SINCE" -eq 0 ] || [ $((NOW - AWAKE_SINCE)) -ge "$SETTLE" ]; then
            suspend_if_lid_shut
        elif [ "$DEBUG" = 1 ]; then
            echo "[sleep-guard] idle + lid shut, but only $((NOW - AWAKE_SINCE))s since resume (<${SETTLE}s) — deferring suspend" >&2
        fi
    fi

    sleep "$POLL"
done

release_lock
