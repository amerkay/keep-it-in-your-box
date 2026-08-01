#!/usr/bin/env bash
# The audit gate — runs where kib already legitimately runs, instead of from a file written
# into every project's .git/hooks. Called from three places, deliberately NOT on attach (a
# second terminal must stay instant):
#   • cold start   (host/lifecycle.sh) — refuses to launch into a poisoned config
#   • teardown     (host/lifecycle.sh) — reports, and raises a desktop alert
#   • `kib audit`  (bin/kib)           — reports, on demand
#
# Findings and remedies live in kib.host.gitaudit; this file is placement, severity mapping and
# the one-time cleanup of the hook kib used to install.
#
# Reads:  PWD
# Writes: nothing global

# Still spelled `ccignore` on purpose — that is what is sitting in the user's repos, and
# matching it literally is the only way the cleanup below can ever fire.
KIB_LEGACY_HOOK_MARKER="MARKER: ccignore-precommit"

_git_toplevel() { git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true; }

# One-time cleanup: remove ours, and only ours — a hook without the marker is the user's.
kib_remove_legacy_hook() {
    local hook="$1/.git/hooks/pre-commit"
    [ -f "$hook" ] || return 0
    grep -q "$KIB_LEGACY_HOOK_MARKER" "$hook" 2>/dev/null || return 0
    rm -f "$hook" 2>/dev/null \
        && echo "🧹 kib: removed the obsolete auto-installed pre-commit hook from this repo" >&2 \
        && echo "   (its checks now run at launch and teardown — see \`kib audit\`)." >&2
    return 0
}

# $1 = launch | teardown | report.
#
#   launch    a refuse-class finding exits 5, before anything is started
#   teardown  nothing is fatal, but findings ALSO raise a desktop alert — a teardown message
#             on stderr is gone the moment the terminal scrolls
#   report    the same findings on stderr and nothing else: `kib audit` is something the user
#             just typed and is watching, so a popup would only be noise
#
# LAUNCH MODE ALWAYS RETURNS 0 (or exits 5): called as a plain command under `set -e`, so
# returning 1 for a warn-class finding would turn "you are tracking a path you asked kib to
# hide" into "the sandbox will not start". Report mode returns the code, so it is scriptable.
kib_audit_gate() {
    local mode="$1" top rc=0 stamp="${STATE_DIR:-}/${SLUG:-x}.hooks.seen"
    have_python || return 0
    top="$(_git_toplevel)"
    [ -n "$top" ] || return 0 # not a git repo — nothing to audit
    kib_remove_legacy_hook "$top"

    # `.claude/hooks/` is a whole tree with no schema to parse, and git cannot bound it: the box
    # can commit, so a hook it wrote checks out pristine past any dirty-file filter. The stamp is
    # the second opinion. Absent (a first launch) it reports nothing and is created below —
    # hooks already in a fresh clone are the user's own.
    kib_py host.gitaudit --top "$top" --mode "$mode" \
        --hooks-stamp "$stamp" --host-claude "$(host_claude_path)" || rc=$?
    # AFTER the report, never before: refreshed first, the scan above always reads empty.
    if [ "$mode" != report ] && [ -d "${STATE_DIR:-}" ]; then
        : >"$stamp" 2>/dev/null || true
    fi
    case "$rc" in
        0) return 0 ;;
        5)
            if [ "$mode" = launch ]; then
                # kib.host.gitaudit has already printed the offending lines and the
                # `git config --unset` remedy; do not repeat them.
                echo "" >&2
                echo "   Refusing to launch. A sandboxed session can write these, and the host" >&2
                echo "   executes them later — a bare \`git status\` is enough." >&2
                exit 5
            fi
            [ "$mode" = teardown ] && notify_desktop critical "kib · host-executed git config found" \
                "This repo has a git config key the host would execute. Run: kib audit"
            ;;
        *)
            # Warn-class only. Named on stderr by kib.host.gitaudit; never fatal.
            [ "$mode" = launch ] && return 0
            [ "$mode" = teardown ] && notify_desktop normal "kib · tracked paths match $KIB_RULE_FILE" \
                "Paths hidden from the sandbox are tracked in git. Run: kib audit"
            ;;
    esac
    [ "$mode" = launch ] && return 0
    return "$rc"
}
