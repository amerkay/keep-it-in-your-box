#!/usr/bin/env bash
# One desktop notification the FIRST time a session writes a shared prompt asset
# (~/.claude/skills|agents|commands), then exits. Those three trees are deliberately writable
# and shared with every project (host/config.sh, "Shared-asset tiers"), so the write is
# legitimate — but it now loads in every other project and in a host `claude`, which is worth
# one alert. First write only: an exit is cheaper and quieter than any throttle.
#
# Its stamp is created HERE, at start, so it reports only this container's writes. Writes made
# while no session ran are the launch report's job (report_shared_asset_writes).
#
# Started via detach_pgrp with fds 200/201 CLOSED (load-bearing — it outlives the kib that
# starts it, and inheriting the project lock would strand teardown); killed by process group.

set -u

# Self-locating: this runs as its own process under setsid, and bin/kib never EXPORTS KIB_ROOT
# (host/_load.sh only sees it by being sourced). Requiring it from the environment made this
# script exit instantly on every launch — and a pidfile naming a dead process is a loaded gun,
# see kill_pgrp.
KIB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# notify_desktop is the only portable notifier, and portable.sh is the only file allowed to
# branch on OS — so source it rather than reimplementing notify-send/osascript here. core.sh
# first: the rest call its warn/die at source time (host/_load.sh).
# shellcheck source=/dev/null
. "$KIB_ROOT/host/core.sh"
# shellcheck source=/dev/null
. "$KIB_ROOT/host/portable.sh"

CLAUDE_HOME="${1:?usage: shared-watch.sh <claude-home> <project> <container> <tree>...}"
NAME="$2"
CNAME="$3"
shift 3

STAMP="$(mktemp "${TMPDIR:-/tmp}/kib-assetwatch.XXXXXX")" || exit 0
trap 'rm -f "$STAMP"' EXIT

while :; do
    sleep 10
    # The container is the session; if it is gone, so is any reason to keep polling. (Teardown
    # kills us by process group — this only covers a kib that died without running it.)
    [ -n "$(docker ps -q -f "name=^${CNAME}$" 2>/dev/null)" ] || exit 0

    hits=""
    for tree in "$@"; do
        [ -d "$CLAUDE_HOME/$tree" ] || continue
        # `sed`, never `head`: head closes the pipe early, and a SIGPIPE'd find is a 141 that
        # `set -o pipefail` turns into an abort. Cheap insurance even without pipefail here.
        hits="$hits$(find "$CLAUDE_HOME/$tree" -type f -newer "$STAMP" 2>/dev/null \
            | sed -n '1,3p' || true)
"
    done
    # Only whitespace means nothing was written yet.
    case "$hits" in *[![:space:]]*) ;; *) continue ;; esac

    body="$NAME wrote a skill/agent/command into ~/.claude — it loads in EVERY project"
    body="$body from now on, and in a host claude. Review it:"
    notify_desktop critical "kib · shared prompt asset written" \
        "$body $(printf '%s' "$hits" | tr '\n' ' ')"
    exit 0
done
