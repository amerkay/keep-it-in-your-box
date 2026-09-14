#!/usr/bin/env bash
# The sleep guard's activity verdict, read from the marker tree guest/policy/sleep-hook.py
# writes. SOURCED by both host/sleep-guard.sh and the diagnostic host/sleep-monitor.sh — never
# copied: a copy drifts, and then the diagnostic judges the guard against a different verdict
# than the one it acts on. bash-3.2/BSD-clean.
#
# Replaced the `wchar` TUI-byte sampler. That measured bytes written to the terminal, so a
# background subagent — which writes almost nothing there — read as idle and let the machine
# sleep mid-work, and a question waiting on the user was indistinguishable from a long think.
# Hooks report Claude's own state machine, so neither case is a guess. (sleep-guard.md)

# `busy` | `idle` | `unknown`. `unknown` means the hooks have not proven themselves for this
# session (no SessionStart marker) — the caller falls back rather than trusting a silent tree.
#
# $1 is bind-mounted rw INTO the box, so every path below is one the session can choose. Only
# EXISTENCE is ever tested, never content, and the session dir is rejected outright if it is a
# symlink — that keeps a planted link from redirecting the walk at the one place it would
# matter. A hostile tree can at worst make its own session look idle, which costs it its own
# inhibitor and nothing of the host's.
# A marker counts only while something keeps touching it. Stop clears `turn` and SubagentStop an
# agent's file, but AN INTERRUPTED TURN FIRES NOTHING AND WRITES NOTHING — the hook runner's first
# act is `if (signal?.aborted) return`, and the transcript stops at the user's own prompt
# (measured). Nor is `wait` a backstop: Claude's idle_prompt notification is cancelled by any
# keystroke after Esc. The leftover marker pinned the machine awake for the rest of the session —
# the laptop-on-all-night. So the rule is time, per marker (see the calls below).
#
# `find -mmin` is the one mtime test spelled identically on GNU and BSD, so no OS branch; -P stats
# the LINK, so a planted symlink reads stale, never fresh. A find that cannot answer prints
# nothing and the marker counts as live — never a box asleep mid-work.
_kib_marker_stale() { # $1 = marker, $2 = minutes it may go untouched
    [ -n "$(find "$1" -mmin "+$2" 2>/dev/null)" ]
}

kib_sleep_state() { # $1 = state root, $2 = session tag
    local d="$1/$2" f w
    { [ -n "$2" ] && [ ! -L "$d" ] && [ -d "$d" ]; } || {
        printf 'unknown'
        return
    }
    [ -f "$d/live" ] || {
        printf 'unknown'
        return
    }

    # Work in flight pins the machine awake on its own — checked BEFORE `wait`, because a
    # background subagent keeps working while a question sits unanswered (2.1.198 made background
    # the default), and so does a tool call started before a permission prompt.
    #
    # A tool holds for its own timeout, the minutes being in its name: that is what a silent
    # ten-minute build looks like from out here, and having it is why `turn` below need not assume
    # every quiet turn might be one. A subagent gets 15 — its own events refresh the marker, but
    # one of ITS tool calls can be silent for a whole timeout.
    for f in "$d"/agents/* "$d"/tools/*; do
        [ -e "$f" ] || continue
        case "$f" in */tools/*) w="${f##*.}" ;; *) w=15 ;; esac
        _kib_marker_stale "$f" "$w" && continue
        printf 'busy'
        return
    done

    # `wait` suppresses only the turn: blocked on a human (question tool, permission prompt)
    # with nothing else running means sleep is correct, however recently the turn started.
    #
    # 2 min where the others get 15, because between events a live turn is quiet only while the
    # model thinks and streams. This number IS the delay before an interrupted session lets the
    # machine sleep, so it is as short as live work can bear rather than as long as it could get
    # away with; whole-minute granularity and GRACE put the real release at ~2.5–3 min.
    if [ -e "$d/turn" ] && [ ! -e "$d/wait" ] && ! _kib_marker_stale "$d/turn" 2; then
        printf 'busy'
        return
    fi
    printf 'idle'
}

# NOTHING ELSE LIVES HERE. The markers are the only input: no byte sampling, no transcript
# mtime, no `claude agents --json`, no `docker exec` of any kind. Each of those was tried and
# is a documented dead end (sleep-guard.md), and every one of them costs a subprocess per poll
# in a daemon whose entire job is to save power. The one `find` above is the exception that
# proves it: it runs only while a subagent marker exists, and only until the first live one.
#
# A marker outliving a `kill -9` needs no liveness probe of the SESSION: kib_cleanup kills the
# guard when the session exits, so a guard cannot outlive the markers it reads. The staleness
# rule above is about the other half — a marker outliving the WORK, inside a session that is
# still very much alive.
