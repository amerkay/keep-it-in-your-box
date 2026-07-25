#!/usr/bin/env bash
set -euo pipefail

# The ONE way to build the image — `kib build`, or run this directly.
#
# A bare `docker build` is wrong: CLAUDE_VERSION stays the literal string `latest` and Docker
# keys its cache on that string, not what it resolves to — so the install layer is reused
# forever and kib prompts for the same upgrade every launch. Resolving the number first busts
# that cache.
#
# Interactive streams the build and exits non-zero on failure; backgrounded, it goes to the log.
# `--background` OVERRIDES the tty test — do not go back to `[ -t 1 ]` alone: setsid drops the
# controlling terminal but leaves fd 1 on the user's terminal, so the test stayed true and
# BuildKit drew its progress UI over the running Claude session.
#
# Remaining arguments pass through to `docker build` (e.g. --no-cache).

KIB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_NAME="keep-it-in-your-box"

# shellcheck source=SCRIPTDIR/../host/core.sh
. "$KIB_ROOT/host/core.sh" # die/warn + the BUILD_* paths
# shellcheck source=SCRIPTDIR/../host/portable.sh
. "$KIB_ROOT/host/portable.sh" # lock_fd + notify_desktop (portable to macOS)
# shellcheck source=SCRIPTDIR/../host/image.sh
. "$KIB_ROOT/host/image.sh" # latest_claude_version — the whole point of this script

# `if`, never `[ -t 1 ] && …`: a bare failing AND-list trips `set -e`, and the
# non-interactive case is exactly the backgrounded one kib relies on.
INTERACTIVE=0
if [ "${1:-}" != --background ] && [ -t 1 ]; then INTERACTIVE=1; fi
[ "${1:-}" = --background ] && shift

mkdir -p "$KIB_BUILD_DIR"
exec 9>"$BUILD_LOCK"
# Non-blocking: a second build would only redo the first one's work, and both would truncate
# the log and race on `docker tag`. Bail instead of queueing.
lock_fd -n 9 || {
    if [ "$INTERACTIVE" = 1 ]; then
        echo "🔨 A build is already running (log: $BUILD_LOG) — nothing to do." >&2
    fi
    exit 0
}

cleanup() {
    rm -f "$BUILD_PID"
}
trap cleanup EXIT

LATEST_VERSION="$(latest_claude_version)"
if [ -z "$LATEST_VERSION" ] && [ "$INTERACTIVE" = 1 ]; then
    # Falling back to the `latest` string is exactly the cache trap described above, so say
    # so rather than hand back a silently stale image.
    echo "⚠️  Could not resolve the current Claude Code version (offline?)." >&2
    echo "   Falling back to CLAUDE_VERSION=latest — Docker may reuse a cached, older install." >&2
fi

build_image() {
    local args=(--build-arg CLAUDE_VERSION="${LATEST_VERSION:-latest}"
        -t "${IMAGE_NAME}:building" "$@" "$KIB_ROOT")
    if [ "$INTERACTIVE" = 1 ]; then
        echo "🔨 Building $IMAGE_NAME with Claude Code ${LATEST_VERSION:-latest}..." >&2
        # Straight to the terminal — no pipe, no redirect. BuildKit only draws its progress
        # UI when stdout is a tty, so even `| tee` demotes it to a scrolling wall of text.
        # The log is there for the backgrounded case, which is when nobody is watching.
        docker build "${args[@]}"
    else
        docker build "${args[@]}" >"$BUILD_LOG" 2>&1
    fi
}

if build_image "$@" \
    && docker tag "${IMAGE_NAME}:building" "${IMAGE_NAME}:latest" \
    && docker rmi "${IMAGE_NAME}:building" >>"$BUILD_LOG" 2>&1; then
    echo "✅ Build complete — new image ready for next launch" >>"$BUILD_LOG"
    notify_desktop normal "Claude Code" "Image rebuild complete — new version ready for next launch"
    if [ "$INTERACTIVE" = 1 ]; then
        echo "✅ Build complete — it is picked up when this project's LAST kib session exits." >&2
    fi
else
    echo "❌ Build failed — see $BUILD_LOG" >>"$BUILD_LOG"
    notify_desktop critical "Claude Code" "Image rebuild failed — check $BUILD_LOG"
    # Surface failure as an exit status too, but only interactively: kib backgrounds this and
    # never reads it, and a non-zero exit there would just be noise.
    if [ "$INTERACTIVE" = 1 ]; then
        echo "❌ Build failed — see $BUILD_LOG" >&2
        exit 1
    fi
fi
