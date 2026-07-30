#!/usr/bin/env bash
# `kib sleep-monitor` — one-shot diagnostic for "why won't it idle-suspend?"
#
# The suspect is host/sleep-guard.sh: one daemon per kib terminal, holding a systemd *block*
# sleep inhibitor labelled "claude-code" while it thinks a session is producing output. If it
# never releases, the machine never sleeps.
#
# Each sample reports: the KDE idle clock and KDE idle inhibitors (systemd-invisible); every
# block-sleep lock with PID and WHY; per claude-code lock the guard process (TTY/PPID/elapsed,
# whether ORPHANED, its hook state); phantom input; AC/battery/lid/kernel suspend counter; and
# matching journal lines interleaved.
#
# The verdict line is the point. It RECONSTRUCTS THE GUARD'S OWN METRIC — kib_sleep_state from
# host/sleep-state.sh, reading the same hook markers the guard acts on — and says whether a
# session really is busy (turn in flight, or a background subagent running) or the guard is
# holding with every session idle (stuck/orphaned = the bug).
#
# Usage: kib sleep-monitor [interval_s] [idle_flag_s]    e.g. kib sleep-monitor 10 55
# Set Suspend to "After 1 minute", leave it idle / close the lid, wait. Ctrl-C stops.
# Everything is echoed and saved to the logfile printed at start.

set -uo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # host/core.sh reads it across the source boundary
KIB_ROOT="$(dirname "$HOST_DIR")"
# shellcheck source=SCRIPTDIR/core.sh
. "$HOST_DIR/core.sh" # KIB_LOG_DIR — the log must not land in the project being diagnosed
# shellcheck source=SCRIPTDIR/portable.sh
. "$HOST_DIR/portable.sh" # is_macos — this whole diagnostic is Linux-only

# Every source this samples (systemd-inhibit, KDE qdbus, /proc) is Linux-only, and the verb is
# host-global so it execs before preflight_platform could say so. Without this it ran to
# completion on macOS and wrote an EMPTY log, which reads as "nothing is holding the machine
# awake" rather than "this tool does not apply here".
if is_macos; then
    echo "kib sleep-monitor is Linux-only: it reads systemd inhibitors, the KDE idle clock" >&2
    echo "and /proc, none of which exist on macOS. The sleep guard there is 'caffeinate -is'," >&2
    echo "so the equivalent diagnostic is:  pmset -g assertions" >&2
    exit 2
fi
# shellcheck source=SCRIPTDIR/sleep-state.sh
# The guard's metric — SOURCED, never copied, so this diagnostic cannot drift into judging the
# guard against a different verdict than the one it acts on.
. "$HOST_DIR/sleep-state.sh"

INTERVAL="${1:-10}"                   # seconds between samples (min effective = INPUT_WINDOW)
IDLE_FLAG="${2:-55}"                  # flag if idle exceeds this (s) but still awake (< your 60s suspend)
INPUT_WINDOW=3                        # how long each sample listens on /dev/input for phantom events
GRACE_HINT="${SLEEP_GUARD_GRACE:-30}" # guard's release delay, for the verdict wording only
# Logs land in the state root: a diagnostic must not drop artefacts into the repo it is run in.
mkdir -p "$KIB_LOG_DIR" 2>/dev/null || true
LOG="$KIB_LOG_DIR/sleep-inhibition-$(date +%Y%m%d-%H%M%S).log"

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
# logind's IdleHint is set by kwin/PowerDevil, so it is exactly what the auto-suspend timer
# sees — unlike GetSessionIdleTime, dead on Wayland. Prints "<yes|no|?> <idle_seconds>".
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

# Phantom-input detection: read every readable /dev/input/event* for INPUT_WINDOW, in parallel,
# and name the devices that fired. If you are touching nothing and a device fires, THAT is why
# the machine never goes idle.
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
        (timeout "$INPUT_WINDOW" cat "$e" 2>/dev/null | wc -c >"$INPUT_TMP/$(basename "$e")") &
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

# The two things we need out of a guard's argv, `sleep-guard.sh <container> <tag> <state-root>`.
# Both redirects are wrapped in a group so an unreadable cmdline is silent rather than leaking
# "Permission denied" into the log.
#
# The tag is the LAST kib- token (the container name is the first, and is no longer needed).
# The state root is the last /-leading one — absolute, so the ^kib- filter steps over it.
guard_tag() { # $1 = guard pid
    { tr '\0' '\n' <"/proc/$1/cmdline"; } 2>/dev/null | grep '^kib-' | tail -1
}
guard_state_root() { # $1 = guard pid
    { tr '\0' '\n' <"/proc/$1/cmdline"; } 2>/dev/null | grep '^/' | tail -1
}

# PIDs of claude-code *sleep block* inhibitors. WHO="claude-code" is a single token, so PID is
# 3 fields past it — robust against the space-containing WHO of other holders.
cc_inhibitor_pids() {
    systemd-inhibit --list --mode=block 2>/dev/null \
        | awk '/claude-code/ && /sleep/ { for(i=1;i<=NF;i++) if($i=="claude-code") print $(i+3) }'
}

declare -A FIRSTSEEN # claude-code inhibitor pid -> epoch first seen (lifetime tracking)

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
say "=== kib sleep-monitor — started $(date '+%F %T') ==="
say "log:        $LOG"
say "interval:   ${INTERVAL}s   idle-flag: ${IDLE_FLAG}s   input_window: ${INPUT_WINDOW}s   qdbus: ${QDBUS:-NONE}"
say "session:    logind graphical session=${SESSION_ID:-UNKNOWN}   input_devs=${#INPUT_DEVS[@]} readable"
[ ${#INPUT_DEVS[@]} -eq 0 ] && say "            (no readable /dev/input — phantom-input detection OFF; sudo usermod -aG input $USER then re-login to enable)"
say "reminder:   set Suspend to 'After 1 minute' now, then leave it idle / close the lid."
say "PRIMARY idle signal = logind IdleHint (Wayland-reliable); screensaver clock shown as (ss=) for contrast."
say "-------------------------------------------------------------------------"
say "BASELINE — all sleep-guard.sh processes right now:"
# shellcheck disable=SC2009  # the point is the full ps column set; pgrep prints pids only
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

    cc_pids=$(cc_inhibitor_pids)

    # --- phantom-input capture over INPUT_WINDOW ---
    # This used to also bracket two container-side wchar samples, because the guard's metric was
    # bytes written. It no longer is, and byte volume never held an inhibitor by itself — only a
    # lock does — so the whole sampler went with it. What is left is the one thing here that
    # genuinely keeps a machine awake on its own: a device firing when nobody is touching it.
    input_capture_start # background /dev/input readers for INPUT_WINDOW
    sleep "$INPUT_WINDOW"
    input=$(input_capture_report) # waits on the readers, names any device that fired

    # PRIMARY idle clock = seconds since the last real input event, which is what PowerDevil's
    # timer keys off — ground truth for "should it have suspended?", unlike the D-Bus clocks.
    # Falls back to logind IdleHint only when /dev/input is unreadable.
    if [ ${#INPUT_DEVS[@]} -gt 0 ]; then
        [[ $input == FIRED* ]] && last_input_ts=$now
        is=$((now - last_input_ts))
        isrc="no-input-for"
    else
        is=$hint_idle
        isrc="loginhint"
    fi

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
            gtag=$(guard_tag "${guard:-0}")
            groot=$(guard_state_root "${guard:-0}")
            # THE guard's metric, read from the same markers it acts on.
            ghook=$(kib_sleep_state "${groot:-/nonexistent}" "${gtag:-none}")
            orphan=""
            { [ "${gppid:-1}" = "1" ] || [ -z "$gtty" ] || [ "$gtty" = "?" ]; } && orphan="  <<< ORPHANED (ppid=$gppid tty=${gtty:-?})"
            case "$ghook" in
                busy) verdict="justified (hook state: busy — a turn is in flight, or a subagent is running)" ;;
                idle) verdict="UNJUSTIFIED (hook state: idle) — riding the ${GRACE_HINT}s grace tail, or stuck" ;;
                *) verdict="UNKNOWN hook state — markers missing; the guard treats this as idle, so it is NOT what is holding the lock" ;;
            esac
            say "        cc-lock pid=$ip held=${held}s guard=$guard etime=${getime:-?} tag=${gtag:-?} hook=${ghook}${orphan}"
            say "                guard_sees: ${verdict}"
        done <<<"$cc_pids"
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
            # Judged on the guard's OWN metric — the hook markers. A lock held with every
            # session idle is the guard misbehaving; held with one busy is simply correct,
            # however quiet the terminal is (a background subagent writes almost nothing, which
            # is exactly what the retired byte threshold got wrong).
            anyhook=idle
            while read -r ip; do
                [ -n "$ip" ] || continue
                g=$(awk '{print $4}' "/proc/$ip/stat" 2>/dev/null)
                st=$(kib_sleep_state "$(guard_state_root "${g:-0}")" "$(guard_tag "${g:-0}")")
                if [ "$st" = busy ]; then
                    anyhook=busy
                    break
                fi
                if [ "$st" = unknown ]; then anyhook=unknown; fi
            done <<<"$cc_pids"
            case "$anyhook" in
                busy)
                    say "  >>> no input for ${is}s but a claude-code lock is held and JUSTIFIED — a session's hook state is busy (a turn is in flight, or a background subagent is running). Not a fault."
                    ;;
                unknown)
                    say "  >>> SMOKING GUN: no input for ${is}s, claude-code lock HELD but NO hook markers exist. The guard reads unknown as idle and should have released, so this lock is ORPHANED — check the cc-lock lines. Separately: the managed-settings hooks are not loading, so look for a 'Managed' source in /status inside the box."
                    ;;
                *)
                    say "  >>> SMOKING GUN: no input for ${is}s, claude-code lock HELD with every session's hook state idle. => sleep-guard STUCK/ORPHANED or riding its ${GRACE_HINT}s grace. Check cc-lock lines for held=Ns / ORPHANED."
                    ;;
            esac
        elif [ "$kde" != "(none)" ]; then
            say "  >>> SMOKING GUN: no input for ${is}s, no claude-code lock, but a KDE idle-inhibitor is held: ${kde}"
        else
            say "  >>> SMOKING GUN: no input for ${is}s and NO inhibitor of any kind visible — PowerDevil should be suspending but isn't. Suspect PowerDevil config, not the sandbox (hint=${hint}, ss=${ss}s)."
        fi
    fi

    # sleep the remainder of the interval (we already spent INPUT_WINDOW listening)
    rest=$((INTERVAL - INPUT_WINDOW))
    ((rest > 0)) && sleep "$rest"
done
