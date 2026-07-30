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
kib_sleep_state() { # $1 = state root, $2 = session tag
    local d="$1/$2" f
    { [ -n "$2" ] && [ ! -L "$d" ] && [ -d "$d" ]; } || {
        printf 'unknown'
        return
    }
    [ -f "$d/live" ] || {
        printf 'unknown'
        return
    }

    # Any live subagent pins the machine awake on its own — checked BEFORE `wait`, because a
    # background subagent keeps working while a question sits unanswered, and 2.1.198 made
    # background the default for subagents. This is the case the byte sampler could not see.
    for f in "$d"/agents/*; do
        [ -e "$f" ] || continue
        printf 'busy'
        return
    done

    # `wait` suppresses only the turn: blocked on a human (question tool, permission prompt)
    # with nothing else running means sleep is correct, however recently the turn started.
    if [ -e "$d/turn" ] && [ ! -e "$d/wait" ]; then
        printf 'busy'
        return
    fi
    printf 'idle'
}

# NOTHING ELSE LIVES HERE. The markers are the only input: no byte sampling, no transcript
# mtime, no `claude agents --json`, no `docker exec` of any kind. Each of those was tried and
# is a documented dead end (sleep-guard.md), and every one of them costs a subprocess per poll
# in a daemon whose entire job is to save power.
#
# A stale `turn` outliving a `kill -9` needs no liveness probe either: kib_cleanup kills the
# guard when the session exits, so a guard cannot outlive the session whose markers it reads.
