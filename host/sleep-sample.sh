#!/usr/bin/env bash
# The sleep guard's activity metric. SOURCED by both host/sleep-guard.sh and the diagnostic
# host/sleep-monitor.sh — never copied: the diagnostic can only judge the guard by computing
# the identical number, and the copy it used to keep drifted. bash-3.2/BSD-clean.

# "<pid> <bytes-written>" per process in one terminal's session; empty if none or if the
# container is unreachable.
#
# The tag goes in via -e (no quoting to get wrong) and is read back under a *different* name,
# so the sampling shell's own environ cannot match and count itself as activity. grep -z makes
# each NUL-terminated entry a line so ^...$ is an exact match, never a prefix of another
# terminal's tag; -H forces the filename prefix even for a single match, so the parse cannot
# shift. Runs as the *host uid*: /proc/<pid>/{io,environ} are gated by ptrace_may_access,
# which root-without-CAP_SYS_PTRACE fails against a uid-1000 process but a same-uid reader
# passes.
kib_sample_wchar() { # $1 = container, $2 = session tag
    docker exec --user "$(id -u)" -e KIB_GUARD_TAG="$2" "$1" sh -c '
        grep -lz "^KIB_SESSION_TAG=$KIB_GUARD_TAG$" /proc/[0-9]*/environ 2>/dev/null \
            | sed "s|/environ$|/io|" \
            | xargs -r grep -H "^wchar:" 2>/dev/null
    ' 2>/dev/null | awk -F'[/:]' '{print $3, $NF + 0}'
}

# Largest positive wchar delta across pids present in BOTH samples.
#
# BUSIEST, NEVER THE SUM: a sum over a growing set (subagents, container pids) crosses any
# fixed threshold once the set is big enough however idle each member is — that is what pinned
# sleep overnight. The max is flat in N. ONLY PIDS IN BOTH SAMPLES: one appearing mid-interval
# has no baseline, so its lifetime total would read as one huge delta. The join is awk, not a
# bash associative array, to stay bash-3.2 clean.
kib_busiest_delta() { # $1 = prev sample, $2 = cur sample
    awk '
        NR==FNR { if ($1 != "") prev[$1] = $2; next }
        ($1 in prev) { d = $2 - prev[$1]; if (d > max) max = d }
        END { print max + 0 }
    ' <(printf '%s\n' "$1") <(printf '%s\n' "$2")
}
