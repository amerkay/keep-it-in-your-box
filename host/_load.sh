#!/usr/bin/env bash
# The one loader for the host-side subsystems. Sourced by bin/kib; nothing else.
#
# Order is fixed and load-bearing: core.sh first (die/warn, called at source time by the rest),
# portable.sh second (all OS branching + the config read), then the rest. Each unit declares
# the globals it reads and writes in its own header. Sourcing them all is cheap, so there is no
# lazy-loading to get wrong.

: "${KIB_ROOT:?host/_load.sh: KIB_ROOT must be set by the caller}"

for _kib_unit in core portable image config redaction gitguard broker mcp desktop net node lifecycle; do
    # shellcheck source=/dev/null
    . "$KIB_ROOT/host/$_kib_unit.sh" || {
        echo "❌ kib: cannot load host/$_kib_unit.sh — the install is incomplete." >&2
        exit 1
    }
done
unset _kib_unit
