#!/usr/bin/env bash
# sleep-postmortem.sh — READ-ONLY forensic dump: "why didn't this machine sleep last night?"
#
# Unlike `kib sleep-monitor` (a live sampler, useless after the fact), this reconstructs what
# already happened from the journal, /sys, /proc and the desktop's config — across EVERY boot in
# the window, so a battery-death reboot is visible rather than hiding the evidence.
#
# It writes exactly ONE file: the report, into this script's own directory (the kib project, which
# is shared with the sandbox) so Claude can read it without you pasting anything. It runs no
# command that changes state: no systemctl start/stop, no suspend, no config write, no sudo.
#
# Usage:  ./sleep-postmortem.sh [hours_back]        # default 14
#         sudo ./sleep-postmortem.sh 14             # only if the journal check below says so
#
# Linux/systemd only.

set -uo pipefail

HOURS="${1:-14}"
USER="${USER:-$(id -un)}" # set -u + a login shell that never exported it (cron, sudo -E) would abort
MAXLINES=120              # per-command output cap, so one chatty source can't bury the rest
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$SELF_DIR/sleep-postmortem-$(date +%Y%m%d-%H%M%S).txt"
SINCE="$(date -d "-${HOURS} hours" '+%Y-%m-%d %H:%M:%S')"
SINCE_EPOCH="$(date -d "-${HOURS} hours" +%s)"

command -v journalctl >/dev/null 2>&1 || {
    echo "no journalctl — this script is systemd-only" >&2
    exit 2
}

FINDINGS=() # verdict lines, printed as the last section
note() { FINDINGS+=("$1"); }

sec() {
    printf '\n\n=================================================================\n'
    printf '== %s\n' "$1"
    printf '=================================================================\n'
}

# Print a command and its (capped, indented) output. The command is a shell string so pipelines
# and globs work; every string here is a literal from this file, never user input.
run() {
    local cmd="$1" max="${2:-$MAXLINES}" out rc n
    printf '\n$ %s\n' "$cmd"
    out="$(eval "$cmd" 2>&1)"
    rc=$?
    if [ -z "$out" ]; then
        printf '   (no output, exit %s)\n' "$rc"
        return
    fi
    n="$(printf '%s\n' "$out" | wc -l)"
    printf '%s\n' "$out" | head -n "$max" | sed 's/^/   /'
    [ "$n" -gt "$max" ] && printf '   ... [%s more lines truncated]\n' "$((n - max))"
}

# The power-relevant journal vocabulary. Curated rather than broad: a bare /sleep/ matches half of
# userspace and buries the three lines that matter.
# systemd 257+ dropped the old "Suspending system..." wording; logind says "The system will
# suspend now!" and systemd-sleep says "Performing sleep operation". Matching only the old
# string reads a machine that suspended fine as one that never tried.
SUSPEND_RE='Suspending system|The system will suspend now|Performing sleep operation|PM: suspend entry'
PAT='Suspending system|Suspended system|System returned from sleep|Entering sleep state|Performing sleep operation|The system will suspend now'
PAT="$PAT|PM: suspend|PM: Preparing|PM: Finishing|PM: hibernation|ACPI: (PM|Waking|Low-level)"
PAT="$PAT|[Ll]id (closed|opened)|Lid Switch|handle-lid-switch|lidAction|LidSwitch"
PAT="$PAT|[Ii]nhibit|Delay lock|Block lock|[Rr]efusing to|Operation .* is inhibited"
PAT="$PAT|sleep\.target|suspend\.target|systemd-suspend|Failed to (suspend|hibernate|start)"
PAT="$PAT|powerdevil|PowerDevil|org_kde_powerdevil|upowerd|[Ii]dle action|IdleHint|idle timeout"
PAT="$PAT|[Ww]akeup|rtcwake|Wake-?up|battery (critical|low)|discharg"
PAT="$PAT|s2idle|s0ix|Low-power S0|amd_pmc|hw_sleep|SMU|[Aa]borting suspend"

main() {
    printf '=== kib sleep post-mortem — generated %s ===\n' "$(date '+%F %T %Z')"
    printf 'window : last %sh  (since %s)\n' "$HOURS" "$SINCE"
    printf 'report : %s\n' "$REPORT"
    printf 'user   : %s (uid %s)   groups: %s\n' "$USER" "$(id -u)" "$(id -nG)"

    # ---------------------------------------------------------------- 1. host
    sec "1. HOST / CURRENT STATE"
    run 'uname -a'
    run 'grep PRETTY_NAME /etc/os-release'
    run 'hostnamectl 2>/dev/null | grep -viE "machine id|boot id"'
    run 'uptime'
    run 'systemctl --version | head -1'
    run 'plasmashell --version 2>/dev/null; kwin_wayland --version 2>/dev/null'
    run 'echo "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-?} XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-?}"'
    run 'cat /proc/acpi/button/lid/*/state 2>/dev/null || echo "NO LID SWITCH EXPOSED"'
    run 'for f in /sys/class/drm/*/status; do [ -r "$f" ] && echo "$(basename "$(dirname "$f")") = $(cat "$f")"; done'
    run 'for f in /sys/class/power_supply/*/; do echo "-- $f"; for k in type online status capacity power_now energy_now energy_full; do [ -r "$f$k" ] && echo "   $k=$(cat "$f$k" 2>/dev/null)"; done; done'

    # ------------------------------------------------------- 2. journal access
    sec "2. JOURNAL ACCESS + BOOT TABLE  (can we even see last night?)"
    if [ -d /var/log/journal ] && [ -n "$(ls -A /var/log/journal 2>/dev/null)" ]; then
        echo "persistent journal: YES (/var/log/journal)"
    else
        echo "persistent journal: NO — /var/log/journal empty or missing."
        note "WARN: journal is volatile; any boot before the last reboot is GONE. Evidence may be lost."
    fi
    if journalctl -b -n1 --no-pager >/dev/null 2>&1; then
        echo "system journal readable by this user: YES"
    else
        echo "system journal readable by this user: NO"
        note "ACTION: re-run with sudo — the system journal is unreadable, so the timeline below is empty."
    fi
    run 'journalctl --list-boots --no-pager' 40
    run 'last -x -F 2>/dev/null | head -30' 30
    run 'journalctl --since "'"$SINCE"'" --no-pager -p err -o short-iso | head -60' 60

    # ------------------------------------------------------------ 3. timeline
    # No -b filter: journalctl spans boots in time order, which is exactly the ask.
    sec "3. MASTER SLEEP/WAKE/LID TIMELINE — all boots, last ${HOURS}h"
    echo "(if this section is empty and the journal is readable, the machine genuinely never"
    echo " attempted a suspend and logind never saw a lid event.)"
    run 'journalctl --since "'"$SINCE"'" --no-pager -o short-iso | grep -aiE "'"$PAT"'"' 400
    sec "3b. KERNEL-ONLY PM LINES (suspend entry/exit, failures, wake source)"
    run 'journalctl -k --since "'"$SINCE"'" --no-pager -o short-iso | grep -aiE "PM:|ACPI|s2idle|wakeup|thermal"' 200
    sec "3c. POWERDEVIL (user service) — the process that implements the lid action on Plasma 6"
    run 'journalctl --user --since "'"$SINCE"'" --no-pager -o short-iso -u plasma-powerdevil.service' 150
    run 'journalctl --since "'"$SINCE"'" --no-pager -o short-iso | grep -aiE "powerdevil|kded|kwin.*(crash|segv)|Segmentation fault|dumped core"' 80

    # A machine that is asleep or off writes NO journal. So a gap is hard evidence of sleep, and
    # an unbroken stream across the night is hard evidence it stayed awake — independent of
    # whether any subsystem bothered to log a lid event or a suspend.
    sec "3d. JOURNAL GAPS > 5 min — where the machine was actually asleep or off"
    echo "(no gap between lid-close and morning = it never slept, whatever the config says)"
    # The `-- Boot <id> --` separator is not a timestamped line: parsing it as one zeroes `prev`
    # and swallows the single most important gap there is — the one that ENDS at a reboot.
    journalctl --since "$SINCE" -o short-unix --no-pager 2>/dev/null \
        | awk '$1 ~ /^[0-9]+(\.[0-9]+)?$/ {t=int($1); if(prev>0 && t-prev>300) print prev, t, t-prev; prev=t}' \
        | while read -r a b d; do
            printf '   GAP %6s min : %s  ->  %s\n' "$((d / 60))" \
                "$(date -d "@$a" '+%F %H:%M:%S')" "$(date -d "@$b" '+%F %H:%M:%S')"
        done | head -40
    echo "   (no GAP lines above = the journal ran continuously = the machine was awake the whole window)"

    # Pair every kernel suspend entry with its exit. This is the ledger that says whether a
    # suspend held or bounced, and a resume followed within seconds by another entry is the
    # re-suspend-after-wake pattern that wedges AMD s2idle.
    sec "3e. SUSPEND LEDGER — each s2idle entry paired with its exit"
    journalctl -k --since "$SINCE" -o short-unix --no-pager 2>/dev/null \
        | awk '$1 ~ /^[0-9]+(\.[0-9]+)?$/ {
                 if (/PM: suspend entry/) { entry=int($1) }
                 else if (/PM: suspend exit/ && entry) { print entry, int($1), int($1)-entry; entry=0 }
               }
               END { if (entry) print entry, 0, -1 }' \
        | while read -r a b d; do
            if [ "$d" -lt 0 ]; then
                printf '   %s  ENTER s2idle  ->  NEVER EXITED (no resume was ever logged)\n' \
                    "$(date -d "@$a" '+%F %H:%M:%S')"
            else
                printf '   %s  ->  %s   slept %sm %ss\n' "$(date -d "@$a" '+%F %H:%M:%S')" \
                    "$(date -d "@$b" '+%H:%M:%S')" "$((d / 60))" "$((d % 60))"
            fi
        done | head -60
    echo "   (an ENTER within a second or two of the previous EXIT = re-suspended before the"
    echo "    hardware settled; that is the documented AMD s2idle wedge.)"

    sec "3f. HIBERNATE READINESS (the reliable answer to overnight s2idle drain)"
    run 'swapon --show'
    run 'free -h | head -3'
    run 'cat /sys/power/disk 2>/dev/null; cat /sys/power/resume 2>/dev/null'
    run 'grep -c . /sys/kernel/debug/amd_pmc/s0ix_stats 2>/dev/null || echo "(s0ix_stats needs root: sudo cat /sys/kernel/debug/amd_pmc/s0ix_stats)"'

    # ---------------------------------------------- 4. lid-close correlation
    sec "4. LID-CLOSE EVENTS — and what the machine did in the 3 minutes after each"
    local lidts n=0
    lidts="$(journalctl --since "$SINCE" --no-pager -o short-iso 2>/dev/null \
        | grep -aiE 'lid closed|lid switch.*close' | awk '{print $1}' | head -12)"
    if [ -z "$lidts" ]; then
        echo "NO lid-close event in the journal for this window."
        note "Lid: journal shows no lid-close event at all — either logind never saw the switch, or it does not log it. Check section 8 (/proc/acpi/button/lid) and section 6 (who holds handle-lid-switch)."
    else
        while read -r ts; do
            [ -n "$ts" ] || continue
            local t0
            t0="$(date -d "$ts" +%s 2>/dev/null)" || continue
            n=$((n + 1))
            printf '\n--- lid event #%s at %s -------------------------------------\n' "$n" "$ts"
            run 'journalctl --since "@'"$((t0 - 10))"'" --until "@'"$((t0 + 180))"'" --no-pager -o short-iso' 60
        done <<<"$lidts"
        # Did any suspend follow a lid close at all? Counted, never `grep -q`: -q exits on the
        # first match, journalctl takes SIGPIPE, and `set -o pipefail` turns that success into a
        # non-zero pipeline — so the negation fires on a machine that suspended perfectly.
        if [ "$(journalctl --since "$SINCE" --no-pager 2>/dev/null | grep -acE "$SUSPEND_RE")" = 0 ]; then
            note "SMOKING GUN: lid-close events exist in the window but no suspend line follows them — the suspend was never even attempted."
        fi
    fi

    # ------------------------------------------------------- 5. suspend stats
    sec "5. SUSPEND ATTEMPTS + FAILURES (kernel counters — reset at each boot!)"
    echo "last_failed_errno -16 = EBUSY: a wakeup source fired while suspending, so the kernel"
    echo "aborted. last_hw_sleep/total_hw_sleep are microseconds of REAL hardware sleep (s0ix) —"
    echo "on this AMD box a suspend that logs success but banks ~0 hw_sleep drains like being awake."
    run 'for f in /sys/power/suspend_stats/*; do [ -f "$f" ] && echo "$(basename "$f") = $(cat "$f" 2>/dev/null)"; done'
    run 'cat /sys/power/state /sys/power/mem_sleep 2>/dev/null'
    run 'cat /sys/power/wakeup_count 2>/dev/null; cat /sys/power/wake_lock 2>/dev/null'
    local sfail
    sfail="$(cat /sys/power/suspend_stats/fail 2>/dev/null)"
    [ "${sfail:-0}" -gt 0 ] 2>/dev/null \
        && note "Suspend FAILED ${sfail}x since this boot — see /sys/power/suspend_stats/last_failed_dev above."

    # ------------------------------------------------------- 6. who inhibited
    sec "6. INHIBITORS — right now (a leaked one from a dead session survives its owner)"
    run 'systemd-inhibit --list --no-pager' 60
    run 'systemd-inhibit --list --mode=block --no-pager' 40
    echo
    echo "-- KDE PolicyAgent inhibitions (invisible to systemd; a browser video or Plasma"
    echo "   'presentation mode' lands here and blocks PowerDevil's suspend) --"
    local qd=""
    for c in qdbus6 qdbus-qt6 qdbus; do command -v "$c" >/dev/null 2>&1 && {
        qd="$c"
        break
    }; done
    if [ -n "$qd" ]; then
        run "$qd"' --literal org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement/PolicyAgent org.kde.Solid.PowerManagement.PolicyAgent.ListInhibitions'
        run "$qd"' org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement currentProfile'
    else
        echo "   (no qdbus binary — install qdbus-qt6 for this one)"
    fi
    echo
    echo "-- long-lived processes that hold power assertions (lstart = when it started; anything"
    echo "   started BEFORE last night and still alive is the prime suspect) --"
    run 'ps -eo pid,ppid,lstart,etime,tty,user,args | grep -aiE "systemd-inhibit|sleep-guard|caffeinate|inhibit" | grep -v grep' 40

    # ------------------------------------------------------------- 7. config
    sec "7. LOGIND / SYSTEMD SLEEP CONFIG (effective, drop-ins included)"
    run 'systemd-analyze cat-config systemd/logind.conf 2>/dev/null | grep -vE "^\s*$"' 120
    run 'systemd-analyze cat-config systemd/sleep.conf 2>/dev/null | grep -vE "^\s*$"' 60
    run 'systemctl list-unit-files --state=masked --no-pager | grep -iE "sleep|suspend|hibernat"'
    run 'systemctl status systemd-logind --no-pager -n 5 2>/dev/null | head -20'
    run 'loginctl list-sessions --no-pager'
    run 'loginctl show-user "$USER" 2>/dev/null | grep -iE "idle|display|state|linger"'
    local sid
    sid="$(loginctl show-user "$USER" -p Display --value 2>/dev/null)"
    [ -n "$sid" ] && run 'loginctl show-session "'"$sid"'" | grep -iE "idle|type|active|state|remote|class|lock"'

    # ------------------------------------------------- 8. powerdevil settings
    sec "8. KDE POWER SETTINGS ON DISK (Plasma 6 — what the GUI actually wrote)"
    echo "Key rows: [Battery][HandleButtonEvents] lidAction  (1 = sleep)"
    echo "          [Battery][SuspendSession] idleTime (ms) / suspendType"
    echo "          powerdevilrc: RefreshMouseJiggler / pausePlayersOnSuspend /"
    echo "          'Even when an external monitor is connected' = inhibitLidActionWhenExternalMonitorPresent"
    run 'cat "$HOME/.config/powermanagementprofilesrc" 2>/dev/null' 80
    run 'cat "$HOME/.config/powerdevilrc" 2>/dev/null' 40
    run 'cat "$HOME/.config/kded5rc" 2>/dev/null | grep -iA2 -E "powerdevil|screenlock"' 20
    run 'cat "$HOME/.config/kscreenlockerrc" 2>/dev/null' 30

    # -------------------------------------------------------- 9. wake sources
    sec "9. WAKE SOURCES (if it DID suspend and something woke it straight back up)"
    run 'for d in /sys/class/wakeup/*; do [ -d "$d" ] || continue; printf "%s\t%s\tactive=%s\texpire=%s\t%s\n" "$(cat "$d/event_count" 2>/dev/null || echo 0)" "$(basename "$d")" "$(cat "$d/active_count" 2>/dev/null)" "$(cat "$d/expire_count" 2>/dev/null)" "$(cat "$d/name" 2>/dev/null)"; done | sort -rn | head -25' 30
    run 'grep -v "\*disabled" /proc/acpi/wakeup 2>/dev/null' 40
    run 'cat /sys/class/rtc/rtc0/wakealarm 2>/dev/null; echo "(empty = no RTC wake alarm armed)"'

    # ------------------------------------------------------- 10. battery data
    sec "10. BATTERY DRAIN CURVE (upower history — the overnight shape)"
    run 'upower --dump 2>/dev/null | grep -aiE "native-path|state|percentage|energy-rate|time to|online|warning" ' 60
    local h
    for h in "$HOME"/.cache/upower/history-charge-*.dat "$HOME"/.cache/upower/history-rate-*.dat; do
        [ -r "$h" ] || continue
        printf '\n-- %s (window only; cols: epoch value state) --\n' "$h"
        awk -v s="$SINCE_EPOCH" '$1>=s' "$h" 2>/dev/null | awk 'NR%3==1' | while read -r ts val st; do
            printf '   %s  %s  %s\n' "$(date -d "@$ts" '+%F %H:%M:%S' 2>/dev/null)" "$val" "$st"
        done | head -120
    done

    # --------------------------------------------------------------- 11. kib
    sec "11. WAS KIB INVOLVED AT ALL?"
    run 'command -v docker >/dev/null && docker ps -a --format "{{.Names}}\t{{.Status}}\t{{.CreatedAt}}" 2>&1 | head -20 || echo "(no docker binary)"'
    run 'pgrep -af "sleep-guard.sh" || echo "(no sleep-guard daemon running)"'
    run 'systemd-inhibit --list --no-pager 2>/dev/null | grep -a claude-code || echo "(no claude-code inhibitor held right now)"'
    local sr="${KIB_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/keep-it-in-your-box}"
    run 'ls -la "'"$sr"'" 2>/dev/null | head -20'
    run 'find "'"$sr"'" -maxdepth 4 -name live -o -maxdepth 4 -name turn -o -maxdepth 4 -name wait 2>/dev/null | head -20; echo "(any marker listed above = a session tree that still claims to be alive)"'
    run 'ls -lt "'"$sr"'/logs" 2>/dev/null | head -15'
    run 'tail -60 "'"$sr"'"/logs/daemon.log 2>/dev/null' 60
    if pgrep -f "sleep-guard.sh" >/dev/null 2>&1; then
        note "A kib sleep-guard daemon IS running right now — check its lstart in section 6 against last night."
    fi
    if systemd-inhibit --list --no-pager 2>/dev/null | grep -qa claude-code; then
        note "SMOKING GUN CANDIDATE: a 'claude-code' block inhibitor is held RIGHT NOW. If no kib session is open, it is orphaned and has been blocking sleep since it leaked."
    fi

    # ------------------------------------------------- 12. what ran overnight
    sec "12. WHAT ELSE WAS AWAKE — units started / heavy processes during the window"
    run 'journalctl --since "'"$SINCE"'" --no-pager -o short-iso | grep -aE "Starting |Started " | awk "{print \$1, \$5, \$6, \$7, \$8}" | sort | uniq -c | sort -rn | head -40' 40
    run 'systemctl list-timers --all --no-pager | head -25' 25
    run 'ps -eo pid,etime,pcpu,pmem,args --sort=-pcpu | head -15'

    # ------------------------------------------------------------ 13. verdict
    sec "13. AUTOMATED CHECKS"

    local lid drm_ext=no f st
    lid="$(cat /proc/acpi/button/lid/*/state 2>/dev/null | awk '{print $2}' | head -1)"
    echo "lid right now            : ${lid:-unknown}"
    for f in /sys/class/drm/*/status; do
        [ -r "$f" ] || continue
        read -r st <"$f" 2>/dev/null || continue
        [ "$st" = connected ] || continue
        case "$f" in *eDP* | *LVDS* | *DSI*) ;; *) drm_ext=yes ;; esac
    done
    echo "external display now     : $drm_ext"
    [ "$drm_ext" = yes ] && note "An EXTERNAL DISPLAY is connected now. Your Battery profile has 'Even when an external monitor is connected' UNCHECKED, so PowerDevil deliberately does nothing on lid close while one is attached. If it was plugged in overnight, that alone explains it."

    local hl li ia
    hl="$(systemd-analyze cat-config systemd/logind.conf 2>/dev/null | grep -iE '^\s*HandleLidSwitch=' | tail -1)"
    li="$(systemd-analyze cat-config systemd/logind.conf 2>/dev/null | grep -iE '^\s*LidSwitchIgnoreInhibited=' | tail -1)"
    ia="$(systemd-analyze cat-config systemd/logind.conf 2>/dev/null | grep -iE '^\s*IdleAction=' | tail -1)"
    echo "logind HandleLidSwitch   : ${hl:-(default: suspend)}"
    echo "logind LidSwitchIgnore.. : ${li:-(default: yes)}"
    echo "logind IdleAction        : ${ia:-(default: ignore)}"
    case "$hl" in *ignore*) note "logind HandleLidSwitch=ignore — logind will NEVER suspend on lid close; the action depends entirely on PowerDevil being alive and willing." ;; esac
    case "$li" in *=no*) note "LidSwitchIgnoreInhibited=no — any block inhibitor (incl. a leaked kib one) fully suppresses the lid-close suspend. With the default 'yes', lid close overrides block inhibitors." ;; esac

    # NOT pgrep -x: comm is truncated to 15 chars ("org_kde_powerde"), so an exact-name match
    # reports the live daemon as dead.
    if pgrep -f org_kde_powerdevil >/dev/null 2>&1; then
        echo "powerdevil process       : running"
    else
        echo "powerdevil process       : NOT RUNNING"
        note "SMOKING GUN: PowerDevil is not running. On Plasma 6 it owns the lid action, so with it dead (crashed / not started) nothing suspends on lid close, whatever the GUI says."
    fi

    # Every /sys counter above is per-boot. If the box rebooted since the incident (battery death
    # or a morning power-on), they describe TODAY and the evidence is in a previous boot's journal.
    local upsec
    upsec="$(awk '{print int($1)}' /proc/uptime 2>/dev/null)"
    printf 'uptime                   : %sh %sm (booted %s)\n' \
        "$((upsec / 3600))" "$(((upsec % 3600) / 60))" "$(date -d "@$(($(date +%s) - upsec))" '+%F %H:%M')"
    if [ "${upsec:-0}" -lt "$((HOURS * 3600))" ]; then
        note "The machine REBOOTED inside the window (up ${upsec}s). Every /sys counter in sections 5 and 9 describes only the current boot — the overnight evidence is in the PREVIOUS boot, see the boot table in section 2 and the timeline in section 3."
    fi

    # s2idle-only hardware: a "successful" suspend that banks no s0ix residency still drains.
    local ms hw ok
    ms="$(cat /sys/power/mem_sleep 2>/dev/null)"
    hw="$(cat /sys/power/suspend_stats/total_hw_sleep 2>/dev/null)"
    ok="$(cat /sys/power/suspend_stats/success 2>/dev/null)"
    echo "mem_sleep                : ${ms:-?}"
    echo "total_hw_sleep (this boot): ${hw:-?} us   successes: ${ok:-?}"
    case "$ms" in
        *deep*) ;;
        *) note "This machine only has s2idle (no 'deep' in mem_sleep). A suspend here is a software idle state: if s0ix does not engage, the battery drains at close to awake rate WHILE it reports itself asleep. Compare total_hw_sleep against how long it was actually suspended (section 3d gaps)." ;;
    esac
    # THE number: seconds actually spent suspended this boot vs seconds of real hardware sleep.
    # Anything well under ~90% means the SoC sat awake behind a closed lid, burning watts.
    local susp_total pct
    susp_total="$(journalctl -k -b -o short-unix --no-pager 2>/dev/null \
        | awk '$1 ~ /^[0-9]+(\.[0-9]+)?$/ {
                 if (/PM: suspend entry/) { e=int($1) }
                 else if (/PM: suspend exit/ && e) { s += int($1)-e; e=0 }
               } END { print s+0 }')"
    if [ "${susp_total:-0}" -gt 0 ] 2>/dev/null; then
        pct=$(((${hw:-0} / 1000000) * 100 / susp_total))
        printf 's0ix residency this boot: %s%% (%ss hardware sleep out of %ss suspended)\n' \
            "$pct" "$((${hw:-0} / 1000000))" "$susp_total"
        if [ "$pct" -lt 90 ]; then
            note "s0ix residency is only ${pct}%: of ${susp_total}s spent 'asleep' this boot, just $((${hw:-0} / 1000000))s was real hardware sleep. The rest was the SoC awake behind a closed lid. THIS is what drains a battery overnight — no wedge or spurious resume required."
        fi

        # The cumulative figure above is poisoned by every suspend since boot, so a fix applied
        # mid-boot stays buried under its own history. last_hw_sleep against the last ledger pair
        # is the one number that reflects the CURRENT configuration.
        local lhw last_dur pct_last
        lhw="$(cat /sys/power/suspend_stats/last_hw_sleep 2>/dev/null)"
        last_dur="$(journalctl -k -b -o short-unix --no-pager 2>/dev/null \
            | awk '$1 ~ /^[0-9]+(\.[0-9]+)?$/ {
                     if (/PM: suspend entry/) { e=int($1) }
                     else if (/PM: suspend exit/ && e) { d=int($1)-e; e=0 }
                   } END { print d+0 }')"
        if [ "${last_dur:-0}" -gt 0 ] 2>/dev/null && [ -n "${lhw:-}" ]; then
            pct_last=$(((lhw / 1000000) * 100 / last_dur))
            printf 's0ix residency, LAST suspend: %s%% (%ss of %ss)  <- judge a change by this\n' \
                "$pct_last" "$((lhw / 1000000))" "$last_dur"
            [ "$pct_last" -lt 90 ] && note "The most recent suspend banked only ${pct_last}% hardware sleep (${lhw} us over ${last_dur}s). Whatever is holding the SoC awake is still active NOW, not just earlier in this boot."
        fi
    fi

    # Rank by expire_count, not event_count: an expiring wakeup is one that asserted and had to
    # time out, which is what blocks s0ix entry. event_count on an input device just counts
    # ordinary typing while awake and names the touchpad on every healthy laptop.
    local expw
    expw="$(for d in /sys/class/wakeup/*; do
        [ -d "$d" ] || continue
        printf '%s %s\n' "$(cat "$d/expire_count" 2>/dev/null || echo 0)" "$(cat "$d/name" 2>/dev/null)"
    done | sort -rn | awk '$1 > 0' | head -6 | tr '\n' ';')"
    echo "wakeup sources that EXPIRED: ${expw:-none}"
    [ -n "$expw" ] && note "These wakeup sources asserted and timed out during suspend: ${expw}. A device holding the bus active is what keeps the SoC out of s0ix. Counts are cumulative for the whole boot, so compare against the previous run before blaming a device — a count that did not move is history, not a live offender. (0000:c3:00.* are this board's USB4/USB-C controllers; a device whose wakeup you disable disappears from this list entirely.)"

    # One line per suspend: logind, systemd-sleep and the kernel each announce it, so counting
    # $SUSPEND_RE reports 3x the real number.
    local nsusp
    nsusp="$(journalctl -k --since "$SINCE" --no-pager 2>/dev/null | grep -ac 'PM: suspend entry')"
    echo "suspend attempts in window: ${nsusp:-0}"
    [ "${nsusp:-0}" = 0 ] && note "Zero 'Suspending system' lines in the last ${HOURS}h — the machine never even tried to sleep. This is a 'nobody asked for a suspend' bug, not a 'suspend failed' bug."

    if [ -n "$qd" ]; then
        local kdeinh
        kdeinh="$("$qd" --literal org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement/PolicyAgent \
            org.kde.Solid.PowerManagement.PolicyAgent.ListInhibitions 2>/dev/null | tr -d '\n')"
        case "$kdeinh" in
            *"{}"* | "") echo "KDE inhibitions now      : none" ;;
            *)
                echo "KDE inhibitions now      : $kdeinh"
                note "A KDE PolicyAgent inhibition is held: $kdeinh — these are invisible to systemd-inhibit and suppress PowerDevil's suspend."
                ;;
        esac
    fi

    sec "14. FINDINGS"
    if [ ${#FINDINGS[@]} -eq 0 ]; then
        echo "No automated finding fired. Read section 3 (timeline) and section 4 (lid correlation)"
        echo "by hand — the answer is in what did NOT happen after the lid closed."
    else
        local i=1 fnd
        for fnd in "${FINDINGS[@]}"; do
            printf '%2s. %s\n\n' "$i" "$fnd"
            i=$((i + 1))
        done
    fi
    printf '\n=== end of report — %s ===\n' "$(date '+%F %T')"
}

main 2>&1 | tee "$REPORT"
printf '\nReport written to:\n  %s\n' "$REPORT"
printf 'It is inside the kib project, so Claude can read it directly — no pasting needed.\n'
