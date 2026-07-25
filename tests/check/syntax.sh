#!/usr/bin/env bash
# Sourced by tests/check.sh — syntax and shellcheck over every script in the tree.
#
# The file lists are derived from the tree, not hand-maintained: a new host unit or guest
# shim is covered the moment it is added, which is exactly how the old hand-written arrays
# fell behind. Only the *classification* is declared here, because it cannot be inferred.

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

section "shellcheck (errors are fatal; style/info advisory)"
if command -v shellcheck >/dev/null 2>&1; then
    for f in "${HOST_BASH[@]}" "${HOST_SH[@]}" "${LINUX_BASH[@]}" "${CONT_SH[@]}" "${CONT_BASH[@]}"; do
        [ -f "$f" ] || continue
        if shellcheck -S error -x "$f" >/dev/null 2>&1; then
            if out="$(shellcheck -S warning -x "$f" 2>&1)" && [ -z "$out" ]; then
                pass "shellcheck $f"
            else
                warn "shellcheck $f (advisory findings)"
            fi
        else
            fail "shellcheck $f" "$(shellcheck -S error -x "$f" 2>&1 | head -8)"
        fi
    done
else
    warn "shellcheck not installed — skipping (install it: apt-get install shellcheck)"
fi
