#!/usr/bin/env bash
# Sourced by tests/check.sh — the portability contract.
#
# Host-side scripts must be bash-3.2/BSD-clean (stock macOS, no brew). Two tiers:
#   FATAL    — bash-4isms, and shimmed tools with a drop-in replacement (flock→lock_fd,
#              sha256sum→hash8, grep -P).
#   ADVISORY — setsid / notify-send: shimmed too, but the Wayland and broker notifiers use them
#              raw BY DESIGN (structurally Linux-only), so these report rather than fail.
#
# Comments are stripped naively first; no flagged token appears inside a string in this repo.

section "Portability contract (host-side scripts, bash-3.2/BSD-clean)"

FATAL_RE='(declare[[:space:]]+-A|[[:space:]]mapfile[[:space:]]|[[:space:]]readarray[[:space:]]|\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^|,|\^)[}:/]|(^|[^_.])\bflock\b|\bsha256sum\b|grep[[:space:]]+-[a-zA-Z]*P)'
ADVISORY_RE='(\bsetsid\b|\bnotify-send\b)'

for f in "${HOST_BASH[@]}" "${HOST_SH[@]}"; do
    [ -f "$f" ] || continue
    # host/portable.sh is the shim home; the check suite is a Linux-only dev harness that
    # uses raw flock to *test* lock_fd. Both are exempt from the contract by design.
    case "$f" in host/portable.sh | tests/check.sh | tests/check/*.sh)
        pass "$f (shim home / dev tool — exempt)"
        continue
        ;;
    esac
    code="$(sed 's/#.*$//' "$f")"
    hits="$(printf '%s\n' "$code" | grep -nE "$FATAL_RE" || true)"
    if [ -n "$hits" ]; then
        fail "$f uses a non-portable construct" "$(printf '%s' "$hits" | head -4)"
    else
        pass "$f is bash-3.2/BSD-clean"
    fi
    adv="$(printf '%s\n' "$code" | grep -nE "$ADVISORY_RE" || true)"
    [ -n "$adv" ] && warn "$f uses setsid/notify-send raw (OK only if Linux-only)" \
        "$(printf '%s' "$adv" | head -3)"
done

# All OS branching lives in host/portable.sh. A `uname` or a Darwin case anywhere else on a
# host path means a second, un-shimmed code path has appeared. Exempt: portable.sh itself,
# sleep-guard.sh's documented fallback probe (it must never hard-fail at startup), and this
# suite, whose own grep pattern would otherwise match itself.
stray_os="$(grep -ln 'uname -s\|Darwin)' "${HOST_BASH[@]}" 2>/dev/null \
    | grep -vE '^(host/portable\.sh|host/sleep-guard\.sh|tests/check/.*\.sh)$' || true)"
if [ -n "$stray_os" ]; then
    fail "OS branching outside host/portable.sh" "$(printf '%s' "$stray_os" | tr '\n' ' ')"
else
    pass "all OS branching stays in host/portable.sh (sleep-guard's fallback probe excepted)"
fi
