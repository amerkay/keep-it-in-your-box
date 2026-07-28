#!/usr/bin/env bash
# Sourced by tests/check.sh — syntax and shellcheck over every script in the tree.
#
# The file lists are derived from the tree, not hand-maintained: a new host unit or guest
# shim is covered the moment it is added, which is exactly how the old hand-written arrays
# fell behind. Only the *classification* is declared here, because it cannot be inferred.

# shellcheck source=SCRIPTDIR/_guard.sh
. "${BASH_SOURCE%/*}/_guard.sh" # sourced by tests/check.sh, never run directly

# Host-side (runs on the user's Mac/Linux): bash, under the portability contract.
HOST_BASH=(bin/kib host/*.sh tools/*.sh dev.sh tests/check.sh tests/lib.sh tests/check/*.sh)
# Host-side POSIX sh.
HOST_SH=(host/clipboard-bridge.sh)
# Host-side but structurally Linux-only (reads /proc, drives systemd): syntax + shellcheck,
# exempt from the portability contract by design — it may use declare -A and friends.
LINUX_BASH=(host/sleep-monitor.sh)
# Container-side (always Linux): syntax only, exempt from the portability contract.
CONT_SH=(guest/entrypoint/*.sh guest/bin/resolv-sync.sh guest/bin/fuse guest/bin/wayland-guard guest/bin/broker)
CONT_BASH=(tests/security-test.sh)

# host/clipboard-bridge.sh is POSIX sh, so drop it from the bash list it globbed into.
_filtered=()
for f in "${HOST_BASH[@]}"; do
    case "$f" in host/clipboard-bridge.sh | host/sleep-monitor.sh) continue ;; esac
    _filtered+=("$f")
done
HOST_BASH=("${_filtered[@]}")
unset _filtered

section "Syntax (bash -n / sh -n / py_compile)"
for f in "${HOST_BASH[@]}" "${LINUX_BASH[@]}" "${CONT_BASH[@]}"; do
    [ -f "$f" ] || {
        warn "$f missing"
        continue
    }
    if err="$(bash -n "$f" 2>&1)"; then pass "bash -n $f"; else fail "bash -n $f" "$err"; fi
done
for f in "${HOST_SH[@]}" "${CONT_SH[@]}"; do
    [ -f "$f" ] || {
        warn "$f missing"
        continue
    }
    if err="$(sh -n "$f" 2>&1)"; then pass "sh -n $f"; else fail "sh -n $f" "$err"; fi
done
# Every tracked .py, discovered — the registry that had to be edited by hand is gone.
while IFS= read -r f; do
    [ -f "$f" ] || continue
    if err="$(python3 -m py_compile "$f" 2>&1)"; then pass "py_compile $f"; else fail "py_compile $f" "$err"; fi
done < <(git ls-files '*.py')

section "Load graph (every kib function an entry point calls is sourced)"
# `kib build` shipped calling latest_claude_version without sourcing host/image.sh: bash -n is
# clean, shellcheck sees a plausible external command, and it dies only at runtime. bin/kib
# loads everything so it cannot hit this; tools/*.sh load a subset, which is where the gap is.
#
# Both sides are derived, never listed — the loaded set by EXECUTING the script's own top-level
# source lines (so _load.sh's loop resolves for free), the called set from command-position
# tokens.
#
# LC_ALL=C on EVERY sort and comm. Function names are full of underscores, which a UTF-8 locale
# collates differently from the byte order `comm` compares in; on mismatch comm silently SKIPS
# entries, so the check would pass while the missing function sat right there.
_kib_fns="$(grep -hoE '^[a-z_][a-z0-9_]*\(\)' "$KIB_ROOT"/host/*.sh | tr -d '()' | LC_ALL=C sort -u)"

_loaded_fns() { # functions defined after running only $1's top-level source lines
    (
        set +eu
        # shellcheck disable=SC2034  # read by the source lines the eval below runs
        HOST_DIR="$KIB_ROOT/host"
        # shellcheck disable=SC2016  # a literal grep pattern matching the source's own $vars
        eval "$(grep -E '^\. "\$(KIB_ROOT|HOST_DIR)/' "$1")"
        declare -F | sed 's/^declare -f //'
    ) 2>/dev/null | LC_ALL=C sort -u
}

_called_fns() { # lowercase tokens at command position, minus comment lines
    sed 's/#.*//' "$1" \
        | grep -oE '(^|[;&|(){}]|\$\()[[:space:]]*[a-z_][a-z0-9_]*' \
        | grep -oE '[a-z_][a-z0-9_]*$' | LC_ALL=C sort -u
}

for f in bin/kib tools/*.sh host/sleep-monitor.sh; do
    [ -f "$f" ] || continue
    # A function the script defines itself is available regardless of what it sources.
    _own="$(grep -hoE '^[a-z_][a-z0-9_]*\(\)' "$f" | tr -d '()' | LC_ALL=C sort -u)"
    _have="$(printf '%s\n%s\n' "$(_loaded_fns "$f")" "$_own" | LC_ALL=C sort -u)"
    _missing="$(LC_ALL=C comm -12 <(_called_fns "$f") <(printf '%s\n' "$_kib_fns") \
        | LC_ALL=C comm -23 - <(printf '%s\n' "$_have") | tr '\n' ' ')"
    _missing="${_missing% }"
    if [ -z "$_missing" ]; then
        pass "$f sources every kib function it calls"
    else
        fail "$f calls kib functions it never sources: $_missing" \
            "add the defining host/*.sh unit to its source list — this dies at runtime, not at lint"
    fi
done
unset _kib_fns _own _have _missing

# Fatal down to the info tier — the same bar `.vscode/settings.json` gives the editor, so a
# finding surfaces where you are typing rather than at commit time. A finding that is wrong
# for this repo gets a targeted `# shellcheck disable=SCxxxx` WITH a reason, never a silence
# here: SC2004 on host/sleep-monitor.sh's nameref would otherwise become a real bug.
section "shellcheck (warnings and info are fatal)"
if command -v shellcheck >/dev/null 2>&1; then
    for f in "${HOST_BASH[@]}" "${HOST_SH[@]}" "${LINUX_BASH[@]}" "${CONT_SH[@]}" "${CONT_BASH[@]}"; do
        [ -f "$f" ] || continue
        if out="$(shellcheck -S info -x "$f" 2>&1)" && [ -z "$out" ]; then
            pass "shellcheck $f"
        else
            fail "shellcheck $f" "$(printf '%s' "$out" | head -8)"
        fi
    done
else
    warn "shellcheck not installed — skipping (install it: apt-get install shellcheck)"
fi

# ── Toolchain pins and the shfmt glob ───────────────────────────────────────
# The Dockerfile owns the shfmt/shellcheck versions (CONVENTIONS.md), but CI cannot read an
# ARG — it must install the binaries before any container exists — so .github/workflows/lint.yml
# restates them. A one-sided bump makes `./dev.sh check` green in the box and red in CI, with
# the diff blamed on the code rather than the toolchain. Asserted, not trusted.
_pin_of() { # <file> <name> — the version string, however that file spells the assignment
    sed -n "s/.*$2[:=][[:space:]]*\(v[0-9][0-9.]*\).*/\1/p" "$1" | head -1
}
_pin_bad=""
for _p in SHFMT_VERSION SHELLCHECK_VERSION; do
    _d="$(_pin_of "$KIB_ROOT/Dockerfile" "$_p")"
    _c="$(_pin_of "$KIB_ROOT/.github/workflows/lint.yml" "$_p")"
    [ -n "$_d" ] || _pin_bad="$_pin_bad $_p(not in Dockerfile)"
    [ "$_d" = "$_c" ] || _pin_bad="$_pin_bad $_p(image=$_d ci=$_c)"
done
if [ -z "$_pin_bad" ]; then
    pass "the shfmt/shellcheck pins agree between the image and CI"
else
    fail "a toolchain pin differs between the Dockerfile and CI:$_pin_bad" \
        "the same code then passes in one environment and fails in the other"
fi
unset _pin_bad _p _d _c
unset -f _pin_of

# shfmt reads .editorconfig, and matches by FILENAME — an extensionless script missing from the
# `[{…}]` glob is silently formatted with the defaults (tabs, no switch_case_indent) by
# `dev.sh format`, and `shfmt -d` then passes on the mangled result. Discovered from the same
# shebang probe dev.sh uses, so a new script is covered the day it is added.
_ec_glob="$(sed -n 's/^\[{\(.*\)}\]$/\1/p' "$KIB_ROOT/.editorconfig" | head -1)"
_ec_missing=""
for _f in "${HOST_BASH[@]}" "${HOST_SH[@]}" "${LINUX_BASH[@]}" "${CONT_SH[@]}" "${CONT_BASH[@]}"; do
    [ -f "$_f" ] || continue
    _b="${_f##*/}"
    case "$_b" in *.*) continue ;; esac # *.sh is covered by the glob's own pattern
    case ",$_ec_glob," in *",$_b,"*) ;; *) _ec_missing="$_ec_missing $_b" ;; esac
done
if [ -z "$_ec_missing" ]; then
    pass "every extensionless script is named in .editorconfig's shfmt glob"
else
    fail "an extensionless script is missing from .editorconfig's glob:$_ec_missing" \
        "shfmt would format it with tabs and shfmt -d would still pass"
fi
unset _ec_glob _ec_missing _f _b
