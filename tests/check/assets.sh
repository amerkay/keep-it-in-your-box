#!/usr/bin/env bash
# Sourced by tests/check.sh — host/config.sh's shared-asset vetting, against fake dirs.
#
# Never canonical: every test builds its own throwaway pair, so a bug here can never reach the
# real ~/.claude (CLAUDE.md: "never aim destructive logic at canonical").

# shellcheck source=SCRIPTDIR/_guard.sh
. "${BASH_SOURCE%/*}/_guard.sh" # sourced by tests/check.sh, never run directly

section "Shared-asset tiers (host/config.sh)"

# shellcheck source=SCRIPTDIR/../../host/core.sh
. "$KIB_ROOT/host/core.sh"
# shellcheck source=SCRIPTDIR/../../host/portable.sh
. "$KIB_ROOT/host/portable.sh"
# shellcheck source=SCRIPTDIR/../../host/config.sh
. "$KIB_ROOT/host/config.sh"

# A fake canonical + session pair. Sets the globals the functions read; warn() output is
# swallowed by the caller so a legitimate warning does not look like test noise.
_a_fixture() {
    _a_dir="$(mktemp -d)"
    CLAUDE_HOME="$_a_dir/canonical"
    SESSION_BASE="$_a_dir/session"
    STATE_DIR="$_a_dir/state"
    mkdir -p "$CLAUDE_HOME/skills" "$SESSION_BASE" "$STATE_DIR"
}

# A subshell so the notifier stub is local: unsetting the real notify_desktop here would strand
# the shims section, which tests it.
_a_vet() { (
    notify_desktop() { :; }
    validate_shared_assets "$@" 2>&1
); }

# The vetting line is auto-execution, never the exec bit: a skill's bundled helper script only
# runs if someone chooses to, so refusing it would flag skills/ on first contact for nothing.
# Nothing is demoted any more — one open tier, and the finding is a report.
t_vet_open_trees() {
    _a_fixture
    mkdir -p "$CLAUDE_HOME/skills/helper/scripts"
    printf '#!/usr/bin/env python3\nprint(1)\n' >"$CLAUDE_HOME/skills/helper/scripts/go.py"
    chmod +x "$CLAUDE_HOME/skills/helper/scripts/go.py"
    is "vetting: a bundled helper script is not a finding" "" \
        "$(_a_vet 1)"

    printf '{"mcpServers":{"x":{"command":"curl evil"}}}\n' >"$CLAUDE_HOME/skills/helper/x.json"
    case "$(_a_vet 1)" in
        *"curl evil"*) pass "vetting: an mcpServers command is named in the report" ;;
        *) fail "vetting missed an auto-running command" "$(_a_vet 1)" ;;
    esac

    # Both halves are mandatory: the gate must also stay SILENT with no unsandboxed reader —
    # warning about a program the user has not installed is what makes a warning stop being read.
    is "vetting: silent when no native claude is installed" "" \
        "$(KIB_HOST_CLAUDE="" _a_vet)"
    case "$(KIB_HOST_CLAUDE=/usr/bin/claude _a_vet)" in
        *"curl evil"*) pass "vetting: reported when a native claude IS installed" ;;
        *) fail "vetting stayed silent with a host claude present" "the gate is inverted" ;;
    esac

    # The teardown scan is delta-scoped against a stamp the scan itself refreshes — the payload
    # above has now been reported once, so a second exit with nothing new must be silent.
    is "vetting: the teardown scan is scoped to what changed since the last one" "" \
        "$(KIB_HOST_CLAUDE=/usr/bin/claude _a_vet)"
    # …but `kib audit` is a look the user just asked for, so it must NOT be delta-scoped. Handing
    # it that stamp answers "nothing changed since your last launch" to "what is in my trees".
    case "$(_a_vet 1)" in
        *"curl evil"*) pass "vetting: kib audit scans whole, not just the delta" ;;
        *) fail "kib audit is delta-scoped" "a payload written before the last launch is invisible" ;;
    esac
    rm -rf "$_a_dir"
}

t_vet_open_trees

# `#` memory written in a box used to be clobbered by the next cold start's re-copy. Newest wins:
# a host edit made during the session must never be reverted by a staged copy the box never wrote.
t_user_memory_roundtrip() {
    _a_fixture
    printf 'canonical\n' >"$CLAUDE_HOME/CLAUDE.md"
    place_user_claude_md
    is "user memory: staged in from canonical" "canonical" "$(cat "$SESSION_BASE/CLAUDE.md")"

    printf 'canonical\nremembered in the box\n' >"$SESSION_BASE/CLAUDE.md"
    merge_out_user_claude_md >/dev/null 2>&1
    case "$(cat "$CLAUDE_HOME/CLAUDE.md")" in
        *"remembered in the box"*) pass "user memory: an in-box edit folds back to canonical" ;;
        *) fail "in-box CLAUDE.md edit was lost" "$(cat "$CLAUDE_HOME/CLAUDE.md")" ;;
    esac

    # Host edit mid-session: canonical is newer, so it stands.
    printf 'edited on the host\n' >"$SESSION_BASE/CLAUDE.md"
    sleep 1 # 1s filesystem timestamp granularity — `find -newer` is not sub-second everywhere
    printf 'host wins\n' >"$CLAUDE_HOME/CLAUDE.md"
    merge_out_user_claude_md >/dev/null 2>&1
    is "user memory: a host edit during the session is not reverted" \
        "host wins" "$(cat "$CLAUDE_HOME/CLAUDE.md")"

    # Write-if-present: an in-box delete must never delete the user's memory.
    rm -f "$SESSION_BASE/CLAUDE.md"
    merge_out_user_claude_md >/dev/null 2>&1
    is "user memory: an in-box delete does not delete canonical" \
        "host wins" "$(cat "$CLAUDE_HOME/CLAUDE.md")"
    rm -rf "$_a_dir"
}

t_user_memory_roundtrip
unset _a_dir
