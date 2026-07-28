#!/usr/bin/env bash
# Messaging, the Python bridge, and the one polling helper. Loaded first — everything
# else calls die/warn, including at source time. Desktop alerts are notify_desktop
# (host/portable.sh) — the only portable notifier, called directly.
#
# Reads:  KIB_ROOT
# Writes: the KIB_STATE_ROOT / BUILD_* paths below, read by the other host units and by
#         tools/build-image.sh (which sources this file directly)
# shellcheck disable=SC2034

# ── Messaging ────────────────────────────────────────────────────
# One argument per line, so a multi-line explanation stays readable at the call site.
# The `[ $# -gt 0 ]` guard matters: `printf '   %s\n'` with no arguments would still
# print the format once, adding a stray blank line to every single-line message.
die() {
    printf '❌ kib: %s\n' "$1" >&2
    shift
    [ $# -gt 0 ] && printf '   %s\n' "$@" >&2
    exit 1
}

warn() {
    printf '⚠️  kib: %s\n' "$1" >&2
    shift
    [ $# -gt 0 ] && printf '   %s\n' "$@" >&2
    return 0
}

# ── Python bridge ────────────────────────────────────────────────
# The single way bash reaches the kib package. PYTHONPATH is per-invocation, NEVER exported —
# an exported one would ride into every process the agent later runs. Parameters go in argv,
# never env vars or shell-assembled JSON.
#
#   kib_py host.mcp adopt --name foo …      →  python3 -m kib.host.mcp adopt --name foo …
kib_py() {
    local module="$1"
    shift
    PYTHONPATH="$KIB_ROOT${PYTHONPATH:+:$PYTHONPATH}" python3 -m "kib.$module" "$@"
}

have_python() { command -v python3 >/dev/null 2>&1; }

# Refuse rather than degrade: the credential paths cannot be done in bash at all.
need_python() {
    have_python && return 0
    die "python3 is required host-side and is not on PATH." \
        "On macOS: xcode-select --install"
}

# ── Host-only state root ─────────────────────────────────────────
# kib-owned scratch and logs, separate from canonical ~/.claude and from the never-mounted
# ~/.keep-it-in-your-box/. Deliberately OUTSIDE the checkout — inside the repo root,
# build.log/lock/pid would show up in `git status` and in the sandbox's view of the project.
KIB_STATE_ROOT="${KIB_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/keep-it-in-your-box}"
KIB_BUILD_DIR="$KIB_STATE_ROOT/build"
KIB_LOG_DIR="$KIB_STATE_ROOT/logs"

# Never unlink BUILD_LOCK: tools/build-image.sh holds flock on that *inode*, so removing it
# would let the next build lock a fresh one — two concurrent builds, both truncating
# build.log and racing on `docker tag`.
BUILD_LOCK="$KIB_BUILD_DIR/build.lock"
BUILD_LOG="$KIB_BUILD_DIR/build.log"
BUILD_PID="$KIB_BUILD_DIR/build.pid"

# ── Polling ──────────────────────────────────────────────────────
#   wait_until <tries> <interval-seconds> <predicate> [args…]
#
# 0 as soon as the predicate succeeds, 1 if it never does. Callers that must also give up when
# the thing has DIED pass a predicate true in either case and then check which happened, so the
# abort condition stays next to what it describes rather than in here.
wait_until() {
    local tries="$1" interval="$2"
    shift 2
    local i=0
    while [ "$i" -lt "$tries" ]; do
        "$@" && return 0
        i=$((i + 1))
        sleep "$interval"
    done
    return 1
}
