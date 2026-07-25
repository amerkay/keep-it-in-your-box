#!/usr/bin/env bash
# One harness vocabulary for both bash suites.
#
# tests/check.sh and tests/security-test.sh had differently-named copies of all of this
# (`ok`/`bad`/`sec` vs `pass`/`fail`/`skip`), so the same run read differently depending on
# which suite produced it. Everything here is shared; only the checks differ.
#
# Sourced, never executed. The caller sets KIB_TEST_FILTER to restrict output to matching
# sections, and calls `report` last for totals and a non-zero exit.
#
# No GNU-only tools: the host-side suite reads this too, under the bash-3.2/BSD contract.

if [ -t 1 ]; then
    T_G=$'\033[32m'
    T_R=$'\033[31m'
    T_Y=$'\033[33m'
    T_B=$'\033[1m'
    T_D=$'\033[2m'
    T_N=$'\033[0m'
else
    T_G=""
    T_R=""
    T_Y=""
    T_B=""
    T_D=""
    T_N=""
fi

PASSED=0
FAILED=0
SKIPPED=0
WARNED=0
FAILURES=()
SECTION=""
KIB_TEST_FILTER="${KIB_TEST_FILTER:-}"

# Is the current section selected? Everything is, unless a filter is set.
active() {
    [ -n "$KIB_TEST_FILTER" ] || return 0
    case "$SECTION" in *"$KIB_TEST_FILTER"*) return 0 ;; esac
    return 1
}

section() {
    SECTION="$1"
    active || return 0
    printf '\n%s%s%s\n' "$T_B" "$1" "$T_N"
}

pass() {
    active || return 0
    printf '  %s✔%s %s\n' "$T_G" "$T_N" "$1"
    PASSED=$((PASSED + 1))
}

fail() {
    active || return 0
    printf '  %s✘%s %s\n' "$T_R" "$T_N" "$1"
    [ -n "${2:-}" ] && printf '      %s%s%s\n' "$T_D" "$2" "$T_N"
    FAILED=$((FAILED + 1))
    FAILURES+=("${SECTION:+$SECTION — }$1")
}

# Advisory: reported, never fatal. For findings that are style, or platform-conditional.
warn() {
    active || return 0
    printf '  %s!%s %s\n' "$T_Y" "$T_N" "$1"
    [ -n "${2:-}" ] && printf '      %s%s%s\n' "$T_D" "$2" "$T_N"
    WARNED=$((WARNED + 1))
}

skip() {
    active || return 0
    printf '  %s–%s %s %s(%s)%s\n' "$T_Y" "$T_N" "$1" "$T_D" "${2:-}" "$T_N"
    SKIPPED=$((SKIPPED + 1))
}

# ── assertions ───────────────────────────────────────────────────
is() { # is <description> <expected> <actual>
    active || return 0
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}

# `deny` is the attack half, `allow` the regression half: a guard that also breaks
# legitimate use has not held, so both halves are mandatory for every control.
deny() { # deny <description> <command…>   — must FAIL
    active || return 0
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        fail "$desc" "command SUCCEEDED — it must be refused"
    else
        pass "$desc"
    fi
}

allow() { # allow <description> <command…>  — must SUCCEED
    active || return 0
    local desc="$1"
    shift
    local out
    if out="$("$@" 2>&1)"; then pass "$desc"; else fail "$desc" "${out:-command failed}"; fi
}

# ── totals ───────────────────────────────────────────────────────
report() {
    printf '\n%s────────────────────────────────────────%s\n' "$T_D" "$T_N"
    printf '%s%d passed%s' "$T_G" "$PASSED" "$T_N"
    [ "$SKIPPED" -gt 0 ] && printf ', %s%d skipped%s' "$T_Y" "$SKIPPED" "$T_N"
    [ "$WARNED" -gt 0 ] && printf ', %s%d warnings%s' "$T_Y" "$WARNED" "$T_N"
    [ "$FAILED" -gt 0 ] && printf ', %s%d FAILED%s' "$T_R" "$FAILED" "$T_N"
    printf '\n'
    if [ "$FAILED" -gt 0 ]; then
        printf '\n%sFailed:%s\n' "$T_B" "$T_N"
        printf '  %s\n' ${FAILURES[@]+"${FAILURES[@]}"}
    fi
    return $((FAILED > 0 ? 1 : 0))
}
