#!/usr/bin/env bash
# The audit gate — runs where kib already legitimately runs, instead of from a file written
# into every project's .git/hooks. Called from three places, deliberately NOT on attach (a
# second terminal must stay instant):
#   • cold start   (host/lifecycle.sh) — refuses to launch into a poisoned config
#   • teardown     (host/lifecycle.sh) — reports, and raises a desktop alert
#   • `kib audit`  (bin/kib)           — reports, on demand
#
# Findings and remedies live in kib.host.gitaudit; this file is placement and severity mapping.
#
# Reads:  PWD
# Writes: nothing global

_git_toplevel() { git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true; }

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
    local mode="$1" top rc=0 what="" stamp="${STATE_DIR:-}/${SLUG:-x}.hooks.seen"
    have_python || return 0
    top="$(_git_toplevel)"
    [ -n "$top" ] || return 0 # not a git repo — nothing to audit

    # `.claude/hooks/` is a whole tree with no schema to parse, and git cannot bound it: the box
    # can commit, so a hook it wrote checks out pristine past any dirty-file filter. The stamp is
    # the second opinion. Absent (a first launch) it reports nothing and is created below —
    # hooks already in a fresh clone are the user's own.
    # Capturing stdout only: the findings go to stderr, so the user still reads them as they
    # print. What comes back is one line naming which warn classes fired, for the alert below.
    what="$(kib_py host.gitaudit --top "$top" --mode "$mode" \
        --hooks-stamp "$stamp" --host-claude "$(host_claude_path)")" || rc=$?
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
            # Warn-class only. Named on stderr by kib.host.gitaudit; never fatal. The title is
            # ITS summary, not a fixed string: the two warn classes read nothing alike, and a
            # hardcoded one described the wrong finding whenever the other fired.
            [ "$mode" = launch ] && return 0
            [ "$mode" = teardown ] && notify_desktop normal \
                "kib · ${what:-findings in this repo}" "Run: kib audit"
            ;;
    esac
    [ "$mode" = launch ] && return 0
    return "$rc"
}
