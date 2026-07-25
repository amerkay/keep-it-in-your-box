#!/usr/bin/env bash
# Sourced by tests/check.sh — the Python suites, run once through pytest.
#
# HARD-FAILS if pytest is missing rather than skipping: a skipped suite reading as a pass is
# how a broken redaction matcher ships. It is pinned in requirements-dev.txt, baked into the
# image and installed by CI, so "not found" means the environment is wrong.

# shellcheck source=SCRIPTDIR/_guard.sh
. "${BASH_SOURCE%/*}/_guard.sh" # sourced by tests/check.sh, never run directly

section "Python suites (pytest)"

# The project venv first (it pins the versions this checkout expects), then PATH, then the
# image's own venv by absolute path — the dev tools live in /opt/dev-tools and only the
# symlinked ones reach PATH, so an image built before pytest was symlinked still runs the
# suite here instead of hard-failing over a missing link.
_pytest_bin=""
for _c in "$KIB_ROOT/.venv/bin/pytest" pytest /opt/dev-tools/bin/pytest; do
    if command -v "$_c" >/dev/null 2>&1 && "$_c" --version >/dev/null 2>&1; then
        _pytest_bin="$_c"
        break
    fi
done
unset _c

if [ -z "$_pytest_bin" ]; then
    fail "pytest not found" \
        "install it: pip install -r requirements-dev.txt (or rebuild the image — see CONVENTIONS.md)"
else
    if out="$("$_pytest_bin" -q "$KIB_ROOT/tests" 2>&1)"; then
        pass "pytest — $(printf '%s' "$out" | tail -1)"
    else
        fail "pytest" "$(printf '%s\n' "$out" | tail -25)"
    fi
fi
unset _pytest_bin
