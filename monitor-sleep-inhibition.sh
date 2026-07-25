#!/usr/bin/env bash
# monitor-sleep-inhibition.sh — one-shot diagnostic for "why won't it idle-suspend?"
#
# The suspect here is sleep-guard.sh: a host daemon (one per cc terminal) that
# holds a systemd *block* sleep inhibitor labelled "claude-code" while it thinks
# a session is producing output. If it never releases, the machine never sleeps.
#
# Every sample this script:
#   - shows KDE idle clock + KDE idle inhibitors (browser audio etc., systemd-invisible)
#   - lists every systemd *block sleep* lock with PID + WHY (not collapsed)
#   - for each claude-code lock: finds the guard (parent) process, its TTY/PPID/
#     elapsed, whether it's ORPHANED (guard reparented to init / lost its TTY),
#     and the SLEEP_GUARD_* / CC_GUARD_TAG tunables from its environ
#   - RECONSTRUCTS THE GUARD'S OWN METRIC: for each guard, samples wchar the way
#     sleep-guard.sh does — via `docker exec` INTO its container, twice 3 s apart
#     (host /proc can't read the container's tagged process) — and reports the
#     *max single-process delta* per tag, exactly what the guard compares against
#     SLEEP_GUARD_MIN_BYTES.
#   - prints the top wchar writers system-wide, so a chatty process is named
#   - AC/battery + lid state + the kernel suspend counter (proves a real suspend)
# and interleaves the relevant journal lines into the same log.
#
# The verdict line is the point: when a claude-code lock is held while idle, it
# says whether a real writer justifies it (names the process + bytes) or whether
# the guard is holding with NO qualifying writer (stuck / orphaned = the bug).
#
# Usage:
#   ./monitor-sleep-inhibition.sh [interval_s] [idle_flag_s]
#   e.g.  ./monitor-sleep-inhibition.sh 10 55
# Set Suspend to "After 1 minute", leave it idle / close the lid, wait.
# Ctrl-C to stop. Everything is echoed AND saved to the logfile printed at start.

set -uo pipefail

INTERVAL="${1:-10}"                        # seconds between samples (min effective = SUBSAMPLE)
IDLE_FLAG="${2:-55}"                       # flag if idle exceeds this (s) but still awake (< your 60s suspend)
SUBSAMPLE=3                                # wchar sampling window — matches sleep-guard.sh's 3s poll
MIN_BYTES="${SLEEP_GUARD_MIN_BYTES:-1024}" # guard's default threshold; overridden per-guard if readable
LOG="./sleep-inhibition-$(date +%Y%m%d-%H%M%S).log"

# ---- locate a qdbus (Plasma 6 = qdbus6) ----------------------------------
QDBUS=""
for c in qdbus6 qdbus-qt6 qdbus; do command -v "$c" >/dev/null 2>&1 && {
    QDBUS="$c"
    break
}; done

say() { printf '%s\n' "$*" | tee -a "$LOG"; }

kde_idle_ms() { # KDE session idle time in ms ("" if unavailable)
    [ -n "$QDBUS" ] || return
    local v
    v=$("$QDBUS" org.freedesktop.ScreenSaver /ScreenSaver GetSessionIdleTime 2>/dev/null)
    [ -n "$v" ] || v=$("$QDBUS" org.kde.screensaver /ScreenSaver GetSessionIdleTime 2>/dev/null)
    printf '%s' "$v"
}
kde_inhibitions() { # apps holding a KDE idle inhibitor (the systemd-invisible kind)
    [ -n "$QDBUS" ] || {
        echo "(no qdbus)"
        return
    }
    "$QDBUS" --literal org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement/PolicyAgent \
        org.kde.Solid.PowerManagement.PolicyAgent.ListInhibitions 2>/dev/null \
        | tr '\n' ' ' | sed 's/\[Argument: aas {//; s/}\]//'
}
ac_online() { cat /sys/class/power_supply/ACAD/online 2>/dev/null || echo '?'; }
lid_state() { cat /proc/acpi/button/lid/*/state 2>/dev/null | awk '{print $2}' | head -1; }
susp_count() { cat /sys/power/suspend_stats/success 2>/dev/null || echo NA; }
batt() { upower -i "$(upower -e 2>/dev/null | grep -m1 battery)" 2>/dev/null \
    | awk -F: '/state|percentage/{gsub(/^ +/,"",$2);printf "%s=%s ",$1,$2}'; }

# The graphical (wayland/x11) logind session — the one PowerDevil auto-suspends.
graphical_session() {
    local sid
    sid=$(loginctl show-user "$USER" -p Display --value 2>/dev/null)
    [ -n "$sid" ] && {
        printf '%s' "$sid"
        return
    }
    loginctl list-sessions --no-legend 2>/dev/null \
        | awk -v u="$USER" '$0 ~ u && ($0 ~ /wayland|x11|seat/){print $1; exit}'
}
# logind's IdleHint is set by kwin/PowerDevil, so it reflects EXACTLY what the
# auto-suspend timer sees — unlike GetSessionIdleTime, which is dead on Wayland.
# prints: "<yes|no|?> <idle_seconds>"
logind_idle() {
    [ -n "$SESSION_ID" ] || {
        echo "? 0"
        return
    }
    local hint since up
    hint=$(loginctl show-session "$SESSION_ID" -p IdleHint --value 2>/dev/null)
    since=$(loginctl show-session "$SESSION_ID" -p IdleSinceHintMonotonic --value 2>/dev/null)
    up=$(awk '{printf "%d", $1*1000000}' /proc/uptime 2>/dev/null) # boot time in µs (CLOCK_MONOTONIC)
    if [ "${hint:-}" = yes ] && [ -n "$since" ] && [ "$since" -gt 0 ] 2>/dev/null; then
        echo "yes $(((up - since) / 1000000))"
    else
        echo "${hint:-?} 0"
    fi
}

# Direct phantom-input detection: read every readable /dev/input/event* for the
# subsample window (in parallel, overlapping the wchar wait) and report which
# devices actually emitted events. If you're not touching anything and a device
# fires, THAT device is why the machine never goes idle.
INPUT_DEVS=()
for _e in /dev/input/event*; do [ -r "$_e" ] && INPUT_DEVS+=("$_e"); done
INPUT_TMP=""
INPUT_PIDS=()
input_capture_start() { # launch background readers; returns immediately
    INPUT_PIDS=()
    [ ${#INPUT_DEVS[@]} -gt 0 ] || return
    INPUT_TMP=$(mktemp -d 2>/dev/null) || {
        INPUT_TMP=""
        return
    }
    local e
    for e in "${INPUT_DEVS[@]}"; do
        (timeout "$SUBSAMPLE" cat "$e" 2>/dev/null | wc -c >"$INPUT_TMP/$(basename "$e")") &
        INPUT_PIDS+=($!) # track only OUR readers — `wait` w/o args would also block on the journal follower
    done
}
input_capture_report() { # wait for readers, name devices that fired
    if [ ${#INPUT_DEVS[@]} -eq 0 ]; then
        echo "n/a (no readable /dev/input — run: sudo usermod -aG input $USER; then re-login)"
        return
    fi
    [ ${#INPUT_PIDS[@]} -gt 0 ] && wait "${INPUT_PIDS[@]}" 2>/dev/null
    local f n nm out=""
    for f in "$INPUT_TMP"/event*; do
        [ -f "$f" ] || continue
        n=$(cat "$f" 2>/dev/null)
        [ "${n:-0}" -gt 0 ] 2>/dev/null || continue
        nm=$(cat "/sys/class/input/$(basename "$f")/device/name" 2>/dev/null)
        out+="[${nm:-$(basename "$f")}]=${n}B "
    done
    rm -rf "$INPUT_TMP" 2>/dev/null
    [ -n "$out" ] && echo "FIRED: $out" || echo "silent"
}

# read a single VAR=... value out of a process's environ (same-uid only). The
# redirect is wrapped in a group so that an unreadable environ (a guard running in
# another terminal whose /proc is ptrace-gated) is silent, not a `line NN: Permission
# denied` leaking to the terminal.
env_val() { # $1=pid $2=VARNAME
    { tr '\0' '\n' <"/proc/$1/environ"; } 2>/dev/null | grep -m1 "^$2=" | cut -d= -f2-
}

# The guard watches processes INSIDE the container, and a host-side /proc scan can't
# read them (a container process reparented under docker-init isn't owned by us on the
# host, so io/environ are ptrace-gated). So reconstruct the guard's metric the way the
# guard itself measures it: `docker exec` into the container and sample there. These
# mirror sleep-guard.sh's sample_wchar exactly, so guard_sees matches what the guard saw.
sample_container_wchar() { # $1=container $2=tag -> "pid bytes" per tagged process
    docker exec --user "$(id -u)" -e CC_GUARD_TAG="$2" "$1" sh -c '
    grep -lz "^CC_SESSION_TAG=$CC_GUARD_TAG$" /proc/[0-9]*/environ 2>/dev/null \
      | sed "s|/environ$|/io|" \
      | xargs -r grep -H "^wchar:" 2>/dev/null
  ' 2>/dev/null | awk -F'[/:]' '{print $3, $NF + 0}'
}
container_cmd() { # $1=container $2=pid -> short cmdline of that in-container pid
    # tr maps BOTH NUL and newline to space: an argv containing literal newlines (a
    # multi-line `bash -c` script) would otherwise wrap the guard_sees line, corrupt
    # the log, and bleed fragments into the terminal after Ctrl-C. cut caps the length.
    docker exec --user "$(id -u)" "$1" sh -c 'tr "\0\n" "  " < /proc/'"$2"'/cmdline 2>/dev/null | cut -c1-70' 2>/dev/null
}
# container name (head) or session tag (tail) from a guard's argv: `sleep-guard.sh
# <container> <tag>`, both starting cc-, container first.
guard_arg() { # $1=guard pid $2=head|tail
    { tr '\0' '\n' <"/proc/$1/cmdline"; } 2>/dev/null | grep '^cc-' | "$2" -1
}

# PIDs of claude-code *sleep block* inhibitors. WHO="claude-code" is a single
# token, so PID is the field 3 past it (UID USER PID); robust against the
# space-containing WHO of other holders ("Screen Locker" etc.).
cc_inhibitor_pids() {
    systemd-inhibit --list --mode=block 2>/dev/null \
        | awk '/claude-code/ && /sleep/ { for(i=1;i<=NF;i++) if($i=="claude-code") print $(i+3) }'
}

# ---- wchar snapshots (reconstruct the guard's own measurement) -------------
declare -A IO1 IO2 PTAG PCMD
declare -A FIRSTSEEN # claude-code inhibitor pid -> epoch first seen (lifetime tracking)

snapshot() { # $1 = target array name (IO1 or IO2). On IO2 also records tag+cmdline.
    local -n _io=$1
    _io=()
    local d pid w
    for d in /proc/[0-9]*; do
        [ -O "$d" ] || continue # same-uid: io/environ are ptrace-gated otherwise
        pid=${d#/proc/}
        w=$(awk '/^wchar:/{print $2; exit}' "$d/io" 2>/dev/null) || continue
        [ -n "$w" ] || continue
        _io[$pid]=$w
        if [ "$1" = IO2 ]; then
            PTAG[$pid]=$(tr '\0' '\n' <"$d/environ" 2>/dev/null | grep -m1 '^CC_SESSION_TAG=' | cut -d= -f2-)
            PCMD[$pid]=$(tr '\0\n' '  ' <"$d/cmdline" 2>/dev/null | cut -c1-70) # NUL+newline -> space, so a multi-line argv can't wrap the line
        fi
    done
}

# ---- background journal follower, tagged into the same log ----------------
(journalctl -f -o short-iso --since now 2>/dev/null \
    | grep --line-buffered -iE 'suspend|resume|lid (open|clos)|powerdevil|inhibit|sleep\.target|PM: (suspend|hibernat)' \
    | sed -u 's/^/    JRNL /' >>"$LOG") &
JPID=$!

cleanup() {
    say ""
    say "=== stopped $(date '+%F %T') ==="
    kill "$JPID" 2>/dev/null
    wait "$JPID" 2>/dev/null
    exit 0
}
trap cleanup INT TERM

# ---- header + baseline ----------------------------------------------------
SESSION_ID="$(graphical_session)"
say "=== monitor-sleep-inhibition — started $(date '+%F %T') ==="
say "log:        $LOG"
say "interval:   ${INTERVAL}s   idle-flag: ${IDLE_FLAG}s   subsample: ${SUBSAMPLE}s   min_bytes: ${MIN_BYTES}   qdbus: ${QDBUS:-NONE}"
say "session:    logind graphical session=${SESSION_ID:-UNKNOWN}   input_devs=${#INPUT_DEVS[@]} readable"
[ ${#INPUT_DEVS[@]} -eq 0 ] && say "            (no readable /dev/input — phantom-input detection OFF; sudo usermod -aG input $USER then re-login to enable)"
say "reminder:   set Suspend to 'After 1 minute' now, then leave it idle / close the lid."
say "PRIMARY idle signal = logind IdleHint (Wayland-reliable); screensaver clock shown as (ss=) for contrast."
say "-------------------------------------------------------------------------"
say "BASELINE — all sleep-guard.sh processes right now:"
ps -eo pid,ppid,tty,etime,user,args 2>/dev/null | grep -E 'sleep-guard\.sh|systemd-inhibit' | grep -v grep \
    | sed 's/^/    /' | tee -a "$LOG"
say "-------------------------------------------------------------------------"

prev_susp="$(susp_count)"
last_input_ts="$(date +%s)" # assume active at launch; raw /dev/input drives the primary clock

while true; do
    ts=$(date '+%F %T')
    now=$(date +%s)
    read -r hint hint_idle <<<"$(logind_idle)" # logind IdleHint (may be unfed on KDE)
    ims=$(kde_idle_ms)
    ims=${ims//[^0-9]/}
    ss=$((10#${ims:-0} / 1000)) # screensaver clock (dead on Wayland)
    kde="$(kde_inhibitions | tr -d '\n' | sed 's/  */ /g')"
    [ -z "${kde// /}" ] && kde="(none)"
    ac=$(ac_online)
    lid=$(lid_state)
    susp=$(susp_count)

    # --- map every live claude-code guard to its (container,tag) so we can sample
    #     inside its container exactly as the guard does ---
    declare -A GTAG_CONT=()
    cc_pids=$(cc_inhibitor_pids)
    while read -r ip; do
        [ -n "$ip" ] || continue
        guard=$(awk '{print $4}' "/proc/$ip/stat" 2>/dev/null) # ppid = the sleep-guard.sh shell
        [ -n "${guard:-}" ] || continue
        ct=$(guard_arg "$guard" head)
        tg=$(guard_arg "$guard" tail)
        [ -n "$ct" ] && [ -n "$tg" ] && GTAG_CONT["$tg"]="$ct"
    done <<<"$cc_pids"

    # container-side wchar sample #1 (mirrors the guard's own sampler)
    declare -A CIO1=()
    for tg in "${!GTAG_CONT[@]}"; do
        while read -r cpid cbytes; do
            [ -n "$cpid" ] && CIO1["$tg,$cpid"]="$cbytes"
        done <<<"$(sample_container_wchar "${GTAG_CONT[$tg]}" "$tg")"
    done

    # --- guard-equivalent wchar measurement + phantom-input capture, both over SUBSAMPLE ---
    snapshot IO1
    input_capture_start # background /dev/input readers for SUBSAMPLE
    sleep "$SUBSAMPLE"
    input=$(input_capture_report) # waits on the readers, names any device that fired
    snapshot IO2

    # container-side wchar sample #2 -> per-tag max single-process delta (== guard's metric)
    declare -A TAGMAX=() TAGPID=()
    for tg in "${!GTAG_CONT[@]}"; do
        while read -r cpid cbytes; do
            [ -n "$cpid" ] || continue
            prev="${CIO1["$tg,$cpid"]:-}"
            [ -n "$prev" ] || continue # only pids in BOTH samples
            d=$((cbytes - prev))
            ((d < 0)) && continue
            if ((d > ${TAGMAX[$tg]:-0})); then
                TAGMAX[$tg]=$d
                TAGPID[$tg]=$cpid
            fi
        done <<<"$(sample_container_wchar "${GTAG_CONT[$tg]}" "$tg")"
    done

    # PRIMARY idle clock = seconds since the last real input event. This is exactly
    # what kwin/PowerDevil's idle timer keys off, so it's the ground truth for "should
    # it have suspended?" — unlike the two D-Bus clocks above. Falls back to logind's
    # IdleHint seconds only when /dev/input isn't readable.
    if [ ${#INPUT_DEVS[@]} -gt 0 ]; then
        [[ $input == FIRED* ]] && last_input_ts=$now
        is=$((now - last_input_ts))
        isrc="no-input-for"
    else
        is=$hint_idle
        isrc="loginhint"
    fi

    # global top writers (host-side): names a chatty process system-wide for context
    tops=""
    for pid in "${!IO2[@]}"; do
        w1=${IO1[$pid]:-}
        [ -n "$w1" ] || continue # only pids in BOTH samples
        d=$((${IO2[$pid]} - w1))
        ((d < 0)) && continue
        ((d > 0)) && tops+="$d $pid"$'\n'
    done

    say "[$ts] idle=${is}s(${isrc}) hint=${hint}/${hint_idle}s ss=${ss}s ac=${ac} lid=${lid:-?} suspend_count=${susp} $(batt)"
    say "        input_events   : ${input:-n/a}$([[ ${input:-} == FIRED* ]] && printf '   <-- if you are NOT touching anything, THIS keeps it awake')"
    say "        kde_inhibitors : ${kde}"

    # --- every systemd block-sleep lock, full lines (PID + WHY preserved) ---
    blk=$(systemd-inhibit --list --mode=block 2>/dev/null | awk 'NR>1 && /sleep/ && NF')
    if [ -n "$blk" ]; then
        say "        block_sleep_locks:"
        printf '%s\n' "$blk" | sed 's/^/          /' | tee -a "$LOG" >/dev/null
        printf '%s\n' "$blk" | sed 's/^/          /'
    else
        say "        block_sleep_locks: (none)"
    fi

    # --- deep-dive each claude-code guard lock ---
    cc_pids=$(cc_inhibitor_pids)
    if [ -n "$cc_pids" ]; then
        while read -r ip; do
            [ -n "$ip" ] || continue
            [ -n "${FIRSTSEEN[$ip]:-}" ] || FIRSTSEEN[$ip]=$now
            held=$((now - FIRSTSEEN[$ip]))
            guard=$(awk '{print $4}' "/proc/$ip/stat" 2>/dev/null) # ppid = the sleep-guard.sh shell
            gtty=$(ps -o tty= -p "${guard:-0}" 2>/dev/null | tr -d ' ')
            gppid=$(awk '{print $4}' "/proc/${guard:-0}/stat" 2>/dev/null)
            getime=$(ps -o etime= -p "${guard:-0}" 2>/dev/null | tr -d ' ')
            # the guard's argv is `sleep-guard.sh <container> <tag>` — container first, tag last
            gtag=$(guard_arg "${guard:-0}" tail)
            gcont=$(guard_arg "${guard:-0}" head)
            gmin=$(env_val "${guard:-0}" SLEEP_GUARD_MIN_BYTES)
            gmin=${gmin:-$MIN_BYTES}
            orphan=""
            { [ "${gppid:-1}" = "1" ] || [ -z "$gtty" ] || [ "$gtty" = "?" ]; } && orphan="  <<< ORPHANED (ppid=$gppid tty=${gtty:-?})"
            # what does THIS guard see? per-tag max measured INSIDE its container (as the guard does)
            mx=0
            mxpid=""
            mxcmd=""
            if [ -n "$gtag" ]; then
                mx=${TAGMAX[$gtag]:-0}
                mxpid=${TAGPID[$gtag]:-}
            fi
            [ -n "$mxpid" ] && [ -n "$gcont" ] && mxcmd=$(container_cmd "$gcont" "$mxpid")
            verdict="justified"
            ((mx < gmin)) && verdict="UNJUSTIFIED (max ${mx} < ${gmin}) — riding 30s grace tail or stuck"
            say "        cc-lock pid=$ip held=${held}s guard=$guard etime=${getime:-?} tag=${gtag:-?} min_bytes=${gmin}${orphan}"
            say "                guard_sees: max_writer=${mx}B/${SUBSAMPLE}s pid=${mxpid:-none} ${mxcmd} => ${verdict}"
        done <<<"$cc_pids"
    fi

    # --- per-tag guard metric summary + top writers ---
    if [ ${#TAGMAX[@]} -gt 0 ]; then
        for tag in "${!TAGMAX[@]}"; do
            _cmd=""
            [ -n "${TAGPID[$tag]:-}" ] && _cmd=$(container_cmd "${GTAG_CONT[$tag]:-}" "${TAGPID[$tag]}")
            say "        tag=${tag} max_writer=${TAGMAX[$tag]}B/${SUBSAMPLE}s pid=${TAGPID[$tag]:-none} ${_cmd}"
        done
    fi
    if [ -n "$tops" ]; then
        say "        top_writers (B/${SUBSAMPLE}s):"
        printf '%s' "$tops" | sort -rn | head -5 | while read -r d pid; do
            say "          d=${d} pid=${pid} tag=${PTAG[$pid]:-} ${PCMD[$pid]:-}"
        done
    fi

    # --- anomaly / event detection ---
    if [ "$susp" != "$prev_susp" ] && [ "$susp" != NA ]; then
        say "  *** SUSPEND FIRED (count ${prev_susp} -> ${susp}) — it went to sleep ***"
        prev_susp="$susp"
    fi

    # Ground truth: no real input for >= IDLE_FLAG, yet still awake => something is
    # blocking the suspend that should have fired. Name the blocker.
    if [ "$is" -ge "$IDLE_FLAG" ]; then
        if [ -n "$cc_pids" ]; then
            biggest=0
            for tag in "${!TAGMAX[@]}"; do ((${TAGMAX[$tag]} > biggest)) && biggest=${TAGMAX[$tag]}; done
            if ((biggest >= MIN_BYTES)); then
                say "  >>> SMOKING GUN: no input for ${is}s but a claude-code lock is held and JUSTIFIED — a process writes ${biggest}B/${SUBSAMPLE}s (>= ${MIN_BYTES}). See top_writers; that process pins sleep."
            else
                say "  >>> SMOKING GUN: no input for ${is}s, claude-code lock HELD with NO qualifying writer (max=${biggest}B < ${MIN_BYTES}). => sleep-guard STUCK/ORPHANED or riding its 30s grace. Check cc-lock lines for held=Ns / ORPHANED."
            fi
        elif [ "$kde" != "(none)" ]; then
            say "  >>> SMOKING GUN: no input for ${is}s, no claude-code lock, but a KDE idle-inhibitor is held: ${kde}"
        else
            say "  >>> SMOKING GUN: no input for ${is}s and NO inhibitor of any kind visible — PowerDevil should be suspending but isn't. Suspect PowerDevil config, not the sandbox (hint=${hint}, ss=${ss}s)."
        fi
    fi

    # sleep the remainder of the interval (we already spent SUBSAMPLE sampling)
    rest=$((INTERVAL - SUBSAMPLE))
    ((rest > 0)) && sleep "$rest"
done
