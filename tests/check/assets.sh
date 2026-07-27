#!/usr/bin/env bash
# Sourced by tests/check.sh — host/config.sh's shared-asset tier logic, against fake dirs.
#
# Never canonical: these functions MOVE files out of a session dir and into $CLAUDE_HOME, so
# every test builds its own throwaway pair (CLAUDE.md: "never aim destructive logic at
# canonical").

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

# THE shadowing bug: a project used before the trees became shared holds real entries in its own
# session dir, and the entrypoint cannot symlink over a non-empty dir — so that one private skill
# hid every shared skill from the project, permanently and silently.
t_fold_out() {
    _a_fixture
    mkdir -p "$SESSION_BASE/skills/audit-rot" "$CLAUDE_HOME/skills/other-skill"
    echo "prompt text" >"$SESSION_BASE/skills/audit-rot/SKILL.md"
    fold_out_project_assets >/dev/null 2>&1

    if [ -f "$CLAUDE_HOME/skills/audit-rot/SKILL.md" ]; then
        pass "fold-out: a per-project skill moves into canonical"
    else
        fail "fold-out lost a per-project skill" "not in $CLAUDE_HOME/skills/audit-rot"
    fi
    # The whole point: the dir must end up removable, or the symlink can never land.
    if [ -e "$SESSION_BASE/skills" ]; then
        fail "fold-out leaves a non-empty session tree" "the entrypoint cannot symlink over it"
    else
        pass "fold-out: the emptied session tree is removed (symlink can land)"
    fi
    is "fold-out: the shared tree is untouched" "text" \
        "$([ -d "$CLAUDE_HOME/skills/other-skill" ] && echo text)"
    rm -rf "$_a_dir"
}

# A name clash must never overwrite the shared copy — that would be a silent, unrecoverable
# clobber of an asset every other project loads.
t_fold_out_clash() {
    _a_fixture
    mkdir -p "$SESSION_BASE/skills/dup" "$CLAUDE_HOME/skills/dup"
    echo mine >"$SESSION_BASE/skills/dup/SKILL.md"
    echo shared >"$CLAUDE_HOME/skills/dup/SKILL.md"
    fold_out_project_assets >/dev/null 2>&1
    is "fold-out: a name clash leaves the shared copy intact" shared \
        "$(cat "$CLAUDE_HOME/skills/dup/SKILL.md")"
    is "fold-out: a clashing project copy stays put" mine \
        "$(cat "$SESSION_BASE/skills/dup/SKILL.md" 2>/dev/null)"
    rm -rf "$_a_dir"
}

# Stale farm symlinks point into a mount that no longer exists; dropping them is what lets the
# tree empty out. An empty session tree must also be a no-op, not an error.
t_fold_out_stale() {
    _a_fixture
    mkdir -p "$SESSION_BASE/skills"
    ln -s /run/kib/shared/skills/gone "$SESSION_BASE/skills/gone"
    fold_out_project_assets >/dev/null 2>&1
    if [ -e "$SESSION_BASE/skills" ] || [ -L "$SESSION_BASE/skills/gone" ]; then
        fail "fold-out keeps a dangling farm symlink" "it still blocks the shared symlink"
    else
        pass "fold-out: a stale farm symlink is dropped, not migrated"
    fi
    mkdir -p "$SESSION_BASE/agents"
    is "fold-out: an empty session tree is a no-op" 0 \
        "$(fold_out_project_assets >/dev/null 2>&1 && echo 0)"
    rm -rf "$_a_dir"
}

# The vetting line is auto-execution, never the exec bit: a skill's bundled helper script only
# runs if someone chooses to, so refusing it would demote skills/ on first contact for nothing.
t_vet_open_trees() {
    _a_fixture
    mkdir -p "$CLAUDE_HOME/skills/helper/scripts"
    printf '#!/usr/bin/env python3\nprint(1)\n' >"$CLAUDE_HOME/skills/helper/scripts/go.py"
    chmod +x "$CLAUDE_HOME/skills/helper/scripts/go.py"
    validate_shared_assets >/dev/null 2>&1
    is "vetting: a bundled helper script does not demote the tree" "" "${KIB_ASSETS_DEMOTED# }"

    printf '{"mcpServers":{"x":{"command":"curl evil"}}}\n' >"$CLAUDE_HOME/skills/helper/x.json"
    validate_shared_assets >/dev/null 2>&1
    case "${KIB_ASSETS_DEMOTED:-}" in
        *skills*) pass "vetting: an mcpServers command demotes the tree to :ro" ;;
        *) fail "vetting missed an auto-running command" "DEMOTED='${KIB_ASSETS_DEMOTED:-}'" ;;
    esac
    rm -rf "$_a_dir"
}

t_fold_out
t_fold_out_clash
t_fold_out_stale
t_vet_open_trees
unset _a_dir
