#!/usr/bin/env bash
# Host-side developer suite for kib — runs on Linux, no Mac needed, no docker needed.
#
# A thin runner: every check lives in tests/check/<section>.sh and is SOURCED, so all sections
# share one set of counters and one report. Order is explicit rather than glob order, because
# `shims` forces the darwin code paths and must say where in the run that happens.
#
# Builds nothing and starts no container — that is tests/security-test.sh's job.
set -uo pipefail

KIB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$KIB_ROOT" || exit 1

# shellcheck source=lib.sh
. "$KIB_ROOT/tests/lib.sh"

for _unit in syntax portability wiring mcp regressions shims pytest; do
    # shellcheck source=/dev/null
    . "$KIB_ROOT/tests/check/$_unit.sh"
done
unset _unit

report
