#!/usr/bin/env bash
# Developer check suite for cc — runs on Linux, no Mac needed. Three things:
#   1. syntax (bash -n / sh -n) + shellcheck on every script  (CLAUDE.md hard rule);
#   2. the portability contract — host-side scripts must be bash-3.2/BSD-clean, so the
#      shimmed GNU tools and bash-4isms may appear ONLY in cc-portable.sh (see its header);
#   3. unit tests for the cc-portable.sh shims and the sleep-guard awk join, forcing the
#      perl/darwin code paths on Linux (perl is identical there) so BOTH OS paths are
#      exercised on this one machine.
#
# Exit non-zero if anything fails. This does NOT build an image or start a container — the
# container-side behaviour is security-test.sh's job, run inside a sandbox.
set -uo pipefail
cd "$(dirname "$0")"

if [ -t 1 ]; then
    G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'
else
    G=""; R=""; Y=""; B=""; D=""; N=""
fi
PASS=0; FAIL=0; WARN=0; FAILURES=()
ok()   { printf '  %s✔%s %s\n' "$G" "$N" "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  %s✘%s %s\n' "$R" "$N" "$1"; [ -n "${2:-}" ] && printf '      %s%s%s\n' "$D" "$2" "$N"; FAIL=$((FAIL + 1)); FAILURES+=("$1"); }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$1"; [ -n "${2:-}" ] && printf '      %s%s%s\n' "$D" "$2" "$N"; WARN=$((WARN + 1)); }
sec()  { printf '\n%s%s%s\n' "$B" "$1" "$N"; }

# Host-side (run on the user's Mac/Linux): must obey the portability contract.
HOST_BASH=(cc cc-lib.sh cc-portable.sh sleep-guard.sh build-bg.sh migrate-sessions.sh check.sh)
# Host-side POSIX sh.
HOST_SH=(clipboard-bridge.sh)
# Container-side (always Linux): linted for syntax only, exempt from the portability contract.
CONT_SH=(docker-entrypoint.sh entrypoint-fuse.sh resolv-sync.sh)
CONT_BASH=(security-test.sh)
PY=(ccignore-fuse.py wayland-guard.py ccignore-precommit.py)

# ── 1. syntax + shellcheck ───────────────────────────────────────
sec "Syntax (bash -n / sh -n)"
for f in "${HOST_BASH[@]}" "${CONT_BASH[@]}"; do
    [ -f "$f" ] || { warn "$f missing"; continue; }
    if err="$(bash -n "$f" 2>&1)"; then ok "bash -n $f"; else bad "bash -n $f" "$err"; fi
done
for f in "${HOST_SH[@]}" "${CONT_SH[@]}"; do
    [ -f "$f" ] || { warn "$f missing"; continue; }
    if err="$(sh -n "$f" 2>&1)"; then ok "sh -n $f"; else bad "sh -n $f" "$err"; fi
done
for f in "${PY[@]}"; do
    [ -f "$f" ] || { warn "$f missing"; continue; }
    if err="$(python3 -m py_compile "$f" 2>&1)"; then ok "py_compile $f"; else bad "py_compile $f" "$err"; fi
done

sec "shellcheck (errors are fatal; style/info advisory)"
if command -v shellcheck >/dev/null 2>&1; then
    for f in "${HOST_BASH[@]}" "${HOST_SH[@]}" "${CONT_SH[@]}" "${CONT_BASH[@]}"; do
        [ -f "$f" ] || continue
        if shellcheck -S error -x "$f" >/dev/null 2>&1; then
            if out="$(shellcheck -S warning -x "$f" 2>&1)" && [ -z "$out" ]; then
                ok "shellcheck $f"
            else
                warn "shellcheck $f (advisory findings)"
            fi
        else
            bad "shellcheck $f" "$(shellcheck -S error -x "$f" 2>&1 | head -8)"
        fi
    done
else
    warn "shellcheck not installed — skipping (install it: apt-get install shellcheck)"
fi

# ── 2. portability contract ──────────────────────────────────────
# Strip comments naively (no flagged token appears inside a code string in this repo), skip
# cc-portable.sh (the one place the shims/tools live). Two tiers:
#   FATAL   — always wrong on a host path: bash-4isms (break macOS bash 3.2) and the shimmed
#             tools that have a drop-in replacement (flock→lock_fd, sha256sum→hash8, grep -P).
#   ADVISORY— setsid / notify-send: shimmed by detach_pgrp / notify_desktop, but the Wayland
#             notifier uses them raw *by design* (it is structurally Linux-only), so these
#             are reported, not failed.
sec "Portability contract (host-side scripts, bash-3.2/BSD-clean)"
FATAL_RE='(declare[[:space:]]+-A|[[:space:]]mapfile[[:space:]]|[[:space:]]readarray[[:space:]]|\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^|,|\^)[}:/]|(^|[^_.])\bflock\b|\bsha256sum\b|grep[[:space:]]+-[a-zA-Z]*P)'
ADVISORY_RE='(\bsetsid\b|\bnotify-send\b)'
for f in "${HOST_BASH[@]}" "${HOST_SH[@]}"; do
    [ -f "$f" ] || continue
    # cc-portable.sh is the shim home; check.sh is a Linux-only dev harness that uses raw
    # flock to *test* lock_fd — both are exempt from the contract by design.
    case "$f" in cc-portable.sh | check.sh) ok "$f (shim home / dev tool — exempt)"; continue ;; esac
    code="$(sed 's/#.*$//' "$f")"
    hits="$(printf '%s\n' "$code" | grep -nE "$FATAL_RE" || true)"
    if [ -n "$hits" ]; then
        bad "$f uses a non-portable construct" "$(printf '%s' "$hits" | head -4)"
    else
        ok "$f is bash-3.2/BSD-clean"
    fi
    adv="$(printf '%s\n' "$code" | grep -nE "$ADVISORY_RE" || true)"
    [ -n "$adv" ] && warn "$f uses setsid/notify-send raw (OK only if Linux-only)" "$(printf '%s' "$adv" | head -3)"
done

# ── 3. shim unit tests (perl/darwin paths forced) ────────────────
sec "Shim unit tests (cc-portable.sh, darwin paths forced)"
# shellcheck source=cc-portable.sh
IMAGE_NAME=unused
die() { printf 'die: %s\n' "$@" >&2; return 1; }
. ./cc-portable.sh
CC_OS=darwin        # force the perl/BSD shims; perl is identical on Linux

t_hash8() {
    local h; h="$(hash8 hello)"
    [ "$h" = 2cf24dba ] && ok "hash8: sha256 first 8" || bad "hash8" "got '$h', want 2cf24dba"
}

t_lockfd() {
    local tmp; tmp="$(mktemp)"
    exec 200>"$tmp"
    if lock_fd -n -x 200; then ok "lock_fd: acquire -n -x"; else bad "lock_fd acquire"; fi
    if flock -n -x "$tmp" -c true 2>/dev/null; then bad "lock_fd: lock did not persist across the shim call"; else ok "lock_fd: lock persists via the held fd (OFD semantics)"; fi
    lock_fd -u 200
    if flock -n -x "$tmp" -c true 2>/dev/null; then ok "lock_fd: -u releases"; else bad "lock_fd -u"; fi
    exec 200>&-

    # timeout: hold it elsewhere, -w1 must fail in ~1s
    local tmp2; tmp2="$(mktemp)"
    flock -x "$tmp2" -c "sleep 3" & local hp=$!
    sleep 0.3
    exec 201>"$tmp2"
    local t0 t1; t0="$(date +%s)"
    if lock_fd -w 1 -s 201; then bad "lock_fd: -w1 acquired a held exclusive lock"; else ok "lock_fd: -w1 -s times out on a held lock"; fi
    t1="$(date +%s)"
    [ "$((t1 - t0))" -le 2 ] || warn "lock_fd -w1 waited $((t1 - t0))s (expected ~1)"
    exec 201>&-; kill "$hp" 2>/dev/null; wait "$hp" 2>/dev/null || true

    # file form: flock -n FILE CMD (the check_for_updates probe)
    local tmp3; tmp3="$(mktemp)"
    if lock_fd -n "$tmp3" true; then ok "lock_fd: file-form succeeds on a free lock"; else bad "lock_fd file-form (free)"; fi
    flock -x "$tmp3" -c "sleep 2" & hp=$!
    sleep 0.3
    if lock_fd -n "$tmp3" true; then bad "lock_fd: file-form succeeded on a held lock"; else ok "lock_fd: file-form fails on a held lock"; fi
    kill "$hp" 2>/dev/null; wait "$hp" 2>/dev/null || true
    rm -f "$tmp" "$tmp2" "$tmp3"
}

t_detach() {
    detach_pgrp sleep 5
    local pid=$! pgid
    sleep 0.3   # let perl load POSIX, setsid, then exec — else ps races a pre-setsid read
    pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
    if [ -n "$pid" ] && [ "$pgid" = "$pid" ]; then
        ok "detach_pgrp: child is its own process-group leader (kill -\$! works)"
    else
        bad "detach_pgrp" "pid=$pid pgid=$pgid (want equal)"
    fi
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
}

t_busiest() {
    # Reuse sleep-guard's exact awk join.
    local bd
    bd() { awk '
        NR==FNR { if ($1 != "") prev[$1] = $2; next }
        ($1 in prev) { d = $2 - prev[$1]; if (d > max) max = d }
        END { print max + 0 }
    ' <(printf '%s\n' "$1") <(printf '%s\n' "$2"); }
    [ "$(bd "$(printf '100 1000\n200 2000\n')" "$(printf '100 1300\n200 2050\n300 9999\n')")" = 300 ] \
        && ok "busiest_delta: max over pids in both samples" || bad "busiest_delta max"
    [ "$(bd "$(printf '100 1000\n')" "$(printf '100 1010\n999 500000\n')")" = 10 ] \
        && ok "busiest_delta: ignores a pid with no baseline" || bad "busiest_delta new-pid"
    [ "$(bd '' '100 5000')" = 0 ] && ok "busiest_delta: empty prev → 0" || bad "busiest_delta empty-prev"
    [ "$(bd '100 5000' '')" = 0 ] && ok "busiest_delta: empty cur → 0" || bad "busiest_delta empty-cur"
}

t_hash8
t_lockfd
t_detach
t_busiest

# ── report ───────────────────────────────────────────────────────
printf '\n%s────────────────────────────────────────%s\n' "$D" "$N"
printf '%s%d passed%s' "$G" "$PASS" "$N"
[ "$WARN" -gt 0 ] && printf ', %s%d warnings%s' "$Y" "$WARN" "$N"
[ "$FAIL" -gt 0 ] && printf ', %s%d FAILED%s' "$R" "$FAIL" "$N"
printf '\n'
if [ "$FAIL" -gt 0 ]; then
    printf '\n%sFailed:%s\n' "$B" "$N"
    printf '  %s\n' "${FAILURES[@]}"
fi
exit $(( FAIL > 0 ? 1 : 0 ))
