#!/usr/bin/env bash
# Inhibits system sleep while a Claude session in the container is actively producing
# output; an idle session still lets the machine sleep. On Linux, when the session goes
# idle while the lid is already shut, it also suspends the machine itself — see the note
# above suspend_if_lid_shut() for why that has to be proactive. On macOS the OS re-evaluates
# sleep when the inhibiting assertion is released, so no such re-trigger is needed.
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
# no baseline, so its lifetime total would read as one huge delta. The prev/cur join is an
# awk pass (not a bash associative array) so this stays bash-3.2/macOS clean.
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
#   SLEEP_GUARD_LID_SUSPEND=1   (LINUX ONLY) on going idle with the lid shut, suspend the
#                               machine (0 disables — e.g. if you run lid-shut on purpose).
#                               No-op on macOS, where the OS handles lid-shut sleep itself.

CONTAINER="${1:?Usage: sleep-guard.sh <container-name> <session-tag>}"
TAG="${2:?Usage: sleep-guard.sh <container-name> <session-tag>}"
POLL=3
GRACE="${SLEEP_GUARD_GRACE:-30}"
MIN_BYTES="${SLEEP_GUARD_MIN_BYTES:-1024}"
DEBUG="${SLEEP_GUARD_DEBUG:-0}"
LID_SUSPEND="${SLEEP_GUARD_LID_SUSPEND:-1}"

# CC_OS / is_macos come from cc-portable.sh (the one place OS branching lives). Fall back to
# a local probe if it is somehow unavailable, so the guard never hard-fails at startup.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cc-portable.sh
. "$SCRIPT_DIR/cc-portable.sh" 2>/dev/null || {
    case "$(uname -s)" in Darwin) CC_OS=darwin ;; *) CC_OS=linux ;; esac
    is_macos() { [ "$CC_OS" = darwin ]; }
}

INHIBIT_PID=""
LAST_ACTIVE=0
PREV=""             # previous "<pid> <bytes>" sample, one line per pid

release_lock() {
    if [ -n "$INHIBIT_PID" ] && kill -0 "$INHIBIT_PID" 2>/dev/null; then
        kill "$INHIBIT_PID" 2>/dev/null
        wait "$INHIBIT_PID" 2>/dev/null || true
        INHIBIT_PID=""
    fi
}

# Acquire the platform's "don't sleep" assertion. Linux: a systemd-inhibit block held by a
# background `sleep infinity`. macOS: `caffeinate -is` (inhibit idle + system sleep). Both
# are released by killing the child (release_lock), and macOS then re-evaluates sleep on its
# own — which is why macOS needs no proactive-suspend equivalent to the Linux path below.
acquire_lock() {
    if [ -z "$INHIBIT_PID" ] || ! kill -0 "$INHIBIT_PID" 2>/dev/null; then
        if is_macos; then
            caffeinate -is &
        else
            systemd-inhibit --what=sleep --who="claude-code" \
                --why="Claude Code is producing output" sleep infinity &
        fi
        INHIBIT_PID=$!
    fi
}

# A --what=sleep block inhibitor keeps a task alive across a lid close — which is the
# point — but logind fires the lid-close suspend exactly once, and having blocked it
# while we held the lock, it never retries once we let go. So a task that finishes with
# the lid already shut leaves the machine awake and draining until the lid is reopened
# (the overnight battery-drain bug). We therefore re-issue the suspend ourselves the
# moment we go idle, but only where it is unambiguously wanted:
#   - lid actually shut (open lid + idle is PowerDevil's job, not ours — never force it);
#   - no external display connected (lid-shut-while-docked means "keep working", the same
#     signal KDE's triggerLidActionWhenExternalMonitorPresent uses);
#   - no *other* Claude session still holding a lock (so the machine sleeps only once the
#     last working session on the host has quietened, not while a sibling tab is busy).
# systemctl suspend still honours any non-cc block inhibitor, and this runs every poll
# while idle, so a blocked attempt simply retries and succeeds once the blocker clears.
# LINUX ONLY: on macOS the OS handles lid-shut sleep once caffeinate releases.
lid_closed() {
    grep -qi 'closed' /proc/acpi/button/lid/*/state 2>/dev/null
}
external_display() {   # any connected output that is not the internal panel
    local f st
    for f in /sys/class/drm/*/status; do
        [ -r "$f" ] || continue
        read -r st < "$f" 2>/dev/null || continue
        [ "$st" = connected ] || continue
        case "$f" in *eDP*|*LVDS*|*DSI*) ;; *) return 0 ;; esac
    done
    return 1
}
other_cc_working() {   # a different session's guard still holds a claude-code lock
    systemd-inhibit --list 2>/dev/null | grep -q 'claude-code'
}
suspend_if_lid_shut() {
    is_macos && return
    [ "$LID_SUSPEND" = 1 ] || return
    lid_closed || return
    external_display && return
    other_cc_working && return
    [ "$DEBUG" = 1 ] && echo "[sleep-guard] idle + lid shut, no external display or other session — suspending" >&2
    # Two guards (one per terminal/project) can reach here on the same idle tick once
    # both sessions have released their locks — each sees no *other* claude-code lock and
    # calls suspend. logind honours the first and answers the rest "Action suspend already
    # in progress, refusing" on stderr. That's expected coordination between sibling
    # guards, not a fault, so swallow it — otherwise the refusal leaks into the session's
    # terminal. Under DEBUG the message is kept for diagnosis. (No set -e here, so a
    # non-zero exit never kills the guard, but || true keeps that intentional.)
    if [ "$DEBUG" = 1 ]; then
        systemctl suspend || true
    else
        systemctl suspend 2>/dev/null || true
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
# This runs container-side (GNU grep/sed/xargs) regardless of host OS, via `docker exec`.
sample_wchar() {
    docker exec --user "$(id -u)" -e CC_GUARD_TAG="$TAG" "$CONTAINER" sh -c '
        grep -lz "^CC_SESSION_TAG=$CC_GUARD_TAG$" /proc/[0-9]*/environ 2>/dev/null \
            | sed "s|/environ$|/io|" \
            | xargs -r grep -H "^wchar:" 2>/dev/null
    ' 2>/dev/null | awk -F'[/:]' '{print $3, $NF + 0}'
}

# Largest positive wchar delta across pids present in BOTH samples. An awk join over prev
# (first input) and cur (second) — flat in the number of pids, and no bash-4 associative
# array, so it runs on stock macOS bash 3.2.
busiest_delta() {   # $1 = prev sample, $2 = cur sample
    awk '
        NR==FNR { if ($1 != "") prev[$1] = $2; next }
        ($1 in prev) { d = $2 - prev[$1]; if (d > max) max = d }
        END { print max + 0 }
    ' <(printf '%s\n' "$1") <(printf '%s\n' "$2")
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
    BUSIEST="$(busiest_delta "$PREV" "$CUR")"

    if [ "$DEBUG" = 1 ]; then
        # awk, not `grep -c . || echo 0`: on an empty sample grep prints 0 AND exits 1, so
        # the `|| echo 0` fires too and NPIDS becomes a two-line "0\n0".
        NPIDS="$(printf '%s' "$CUR" | awk 'NF{n++} END{print n+0}')"
        echo "[sleep-guard] busiest process in session +${BUSIEST}B this poll (active if ≥${MIN_BYTES}B, ${NPIDS} pids), inhibit=${INHIBIT_PID:-none}" >&2
    fi

    # No baseline yet (first poll, or the session has not started) leaves BUSIEST at 0,
    # and LAST_ACTIVE at 0 blocks the release branch — so a fresh guard neither inhibits
    # on a stale lifetime total nor releases a lock it never took.
    if [ "$BUSIEST" -ge "$MIN_BYTES" ]; then
        acquire_lock
        LAST_ACTIVE=$NOW
    elif [ "$LAST_ACTIVE" -gt 0 ] && [ $((NOW - LAST_ACTIVE)) -ge "$GRACE" ]; then
        release_lock
        suspend_if_lid_shut     # honour the lid-close we blocked while the task ran (linux)
    fi

    # Carry cur forward as the next baseline. An empty sample (session gone, or docker
    # hiccup) therefore reads as quiet and releases after GRACE — erring towards letting
    # the machine sleep, never towards pinning it awake.
    PREV="$CUR"

    sleep "$POLL"
done

release_lock
