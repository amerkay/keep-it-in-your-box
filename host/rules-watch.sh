#!/usr/bin/env bash
# Carries a `.kibignore` edit into the LIVE redaction view, without waiting for the next launch.
# One per container: started by prepare_redaction, killed by teardown_redaction.
#
# TIGHTENING edits only. This has no terminal to ask at, and applying a loosening edit unasked
# would let the box un-redact a file by writing its own `!.env`; those wait for the next attach,
# which prompts. (docs/design-notes/redaction-config-guard.md)
#
# Usage: rules-watch.sh <patterns-state> <fuse-container>, cwd = the PROJECT — inherited through
# detach_pgrp, and where _reload_rules reads the rule file from.

PATTERNS_STATE="${1:?Usage: rules-watch.sh <patterns-state> <fuse-container>, cwd = project}"
FUSE_CNAME="${2:?Usage: rules-watch.sh <patterns-state> <fuse-container>, cwd = project}"
POLL=2

# An EXECUTED host script gets a fresh environment, so KIB_ROOT comes from $0, never from it.
# (container-lifecycle.md)
HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
KIB_ROOT="$(cd "$HOST_DIR/.." && pwd)" || exit 1
# kib_py, lock_fd, and _reload_rules itself — the reload is ONE implementation, shared with the
# attach path. Not _load.sh: that is bin/kib's loader, and drags in the launch path for three
# functions. `|| exit 1` because this script has no `set -e`.
# shellcheck source=SCRIPTDIR/core.sh
. "$HOST_DIR/core.sh" || exit 1
# shellcheck source=SCRIPTDIR/portable.sh
. "$HOST_DIR/portable.sh" || exit 1
# shellcheck source=SCRIPTDIR/redaction.sh
. "$HOST_DIR/redaction.sh" || exit 1

RULE_PATH="$PWD/$KIB_RULE_FILE"

# `$(<f)` is bash's fork-free read — this polls for the container's whole life. Absent = empty.
_rule_text() {
    RULE_TEXT=""
    if [ -f "$RULE_PATH" ]; then RULE_TEXT="$(<"$RULE_PATH")"; fi
}

_rule_text
seen="$RULE_TEXT"
exec >/dev/null 2>&1 # nothing reads a detached daemon; the sidecar logs each reload it does

while sleep "$POLL"; do
    # teardown removes the staged copy last, so its absence means the container is gone.
    [ -e "$PATTERNS_STATE" ] || exit 0
    _rule_text
    [ "$RULE_TEXT" = "$seen" ] && continue
    # Recorded either way: a loosening edit is answered at the next attach, and re-running the
    # gate every 2s would fork python for the life of the container.
    seen="$RULE_TEXT"
    if kib_py shared.rules tightens "$PATTERNS_STATE" "$RULE_PATH" >/dev/null 2>&1; then
        _reload_rules "$PATTERNS_STATE" "it redacts strictly more"
    fi
done
