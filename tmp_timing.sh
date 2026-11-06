#!/usr/bin/env bash
# TMP (delete when merged): time every step of one kib launch and close. Linux (bash 5) only.
# Usage, in a project:  ~/keep-it-in-your-box/tmp_timing.sh claude   then quit Claude at once.
set -u
trace="$(mktemp)" # 0600; holds expanded commands, so it is deleted below and never printed
trap 'rm -f "$trace"' EXIT
bash -c 'BASH_XTRACEFD=99
    PS4="+ \$EPOCHREALTIME \$BASHPID/\$\$ \${BASH_SOURCE[0]:-trap}:\$LINENO \${FUNCNAME[0]:-main} "
    set -x; . "$0" "$@"' "$(dirname "$0")/bin/kib" "$@" 99>"$trace"
echo "+ $EPOCHREALTIME 0/0 exit:0 main exit" >>"$trace" # times the last step

echo
echo "⏱  kib timing — paste everything below back to Claude"
# Each gap between two lines of kib's own shell is the first line's cost. The longest is Claude.
awk '$1 ~ /^\++$/ && $2 ~ /^[0-9]+\.[0-9]+$/ {
    split($3, p, "/"); if (p[1] != p[2]) next
    sub(/.*\//, "", $4); cmd = $6; sub(/=.*/, "=", cmd)
    if (n) { d[n] = $2 - t; if (d[n] > d[m]) m = n }
    k[++n] = $4 " " $5 " " substr(cmd, 1, 24); t = $2
}
END {
    for (i = 1; i < n; i++) {
        ph = i < m ? "start" : i > m ? "close" : "claude"
        tot[ph] += d[i]; s[ph "|" k[i]] += d[i]; c[ph "|" k[i]]++
    }
    printf "0 start %.1f s, Claude %.1f s, close %.1f s\n", tot["start"], tot["claude"], tot["close"]
    for (x in s) if (s[x] >= 0.1 && x !~ /^claude/) {
        split(x, q, "|"); printf "%d %s %6.2f  ×%-3d %s\n", q[1] == "close" ? 2 : 1, q[1], s[x], c[x], q[2]
    }
}' "$trace" | sort -k1,1n -k3,3rn | cut -d' ' -f2-
