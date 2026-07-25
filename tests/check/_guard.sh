#!/usr/bin/env bash
# Sourced first by every tests/check/*.sh section — refuses a standalone run.
#
# A section is sourced by tests/check.sh, which supplies both the harness vocabulary
# (section/pass/fail/is, from tests/lib.sh) and KIB_ROOT. Run one directly and it died on an
# opaque `section: command not found`; say what to run instead. Leading underscore keeps it out
# of the runner's unit list.
command -v section >/dev/null 2>&1 || {
    echo "tests/check/${BASH_SOURCE[1]##*/}: sourced by tests/check.sh, not run directly." >&2
    echo "  run: ./tests/check.sh          (all sections)" >&2
    echo "  or:  KIB_TEST_FILTER=<name> ./tests/check.sh" >&2
    exit 2
}
