#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="keep-it-in-your-box"
BUILD_LOCK="$SCRIPT_DIR/build.lock"
BUILD_LOG="$SCRIPT_DIR/build.log"
BUILD_PID="$SCRIPT_DIR/build.pid"

# shellcheck source=cc-portable.sh
. "$SCRIPT_DIR/cc-portable.sh" # lock_fd + notify_desktop (portable to macOS)

# Run this directly to rebuild the image by hand — it is the ONLY correct way to do it.
# `docker build` on its own leaves CLAUDE_VERSION at its default, the literal string `latest`,
# and Docker keys its cache on that string rather than on what it resolves to: the install
# layer is reused forever, the image keeps an old Claude, and cc prompts for the same upgrade
# on every launch. Resolving the number first is what busts that cache.
#
# Interactive (stdout is a terminal) streams the build and exits non-zero on failure; when cc
# backgrounds it the output goes quietly to build.log, as before.
# `if`, never `[ -t 1 ] && …`: a bare failing AND-list trips `set -e`, and
# the non-interactive case is exactly the backgrounded one cc relies on.
#
# `--background` is passed by cc and OVERRIDES the tty test — do not go back to `[ -t 1 ]`
# alone. detach_pgrp runs this under setsid, which drops the controlling terminal but leaves
# fd 1 pointing at the user's terminal, so the tty test stayed true and BuildKit drew its
# progress UI straight over the running Claude session (and build.log got nothing).
INTERACTIVE=0
if [ "${1:-}" != --background ] && [ -t 1 ]; then INTERACTIVE=1; fi

exec 9>"$BUILD_LOCK"
# Non-blocking: a second build would only redo the first one's work, and both would
# truncate build.log and race on `docker tag`. Bail instead of queueing.
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

LATEST_VERSION="$(curl -sf https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/latest 2>/dev/null | tr -d '[:space:]' || true)"
if [ -z "$LATEST_VERSION" ] && [ "$INTERACTIVE" = 1 ]; then
    # Falling back to the `latest` string is exactly the cache trap described above, so say so
    # rather than hand back a silently stale image.
    echo "⚠️  Could not resolve the current Claude Code version (offline?)." >&2
    echo "   Falling back to CLAUDE_VERSION=latest — Docker may reuse a cached, older install." >&2
fi

build_image() {
    local args=(--build-arg CLAUDE_VERSION="${LATEST_VERSION:-latest}"
        -t "${IMAGE_NAME}:building" "$SCRIPT_DIR")
    if [ "$INTERACTIVE" = 1 ]; then
        echo "🔨 Building keep-it-in-your-box with Claude Code ${LATEST_VERSION:-latest}..." >&2
        # Straight to the terminal — no pipe, no redirect. BuildKit only draws its progress UI
        # when stdout is a tty, so even `| tee` demotes it to a plain scrolling wall of text.
        # build.log is there for the backgrounded case, which is exactly when nobody is watching.
        docker build "${args[@]}"
    else
        docker build "${args[@]}" >"$BUILD_LOG" 2>&1
    fi
}

if build_image \
    && docker tag "${IMAGE_NAME}:building" "${IMAGE_NAME}:latest" \
    && docker rmi "${IMAGE_NAME}:building" >>"$BUILD_LOG" 2>&1; then
    echo "✅ Build complete — new image ready for next launch" >>"$BUILD_LOG"
    notify_desktop normal "Claude Code" "Image rebuild complete — new version ready for next launch"
    if [ "$INTERACTIVE" = 1 ]; then
        echo "✅ Build complete — it is picked up when this project's LAST cc session exits." >&2
    fi
else
    echo "❌ Build failed — see $BUILD_LOG" >>"$BUILD_LOG"
    notify_desktop critical "Claude Code" "Image rebuild failed — check $BUILD_LOG"
    # Surface failure as an exit status too, but only interactively: cc backgrounds this and
    # never reads it, and a non-zero exit there would just be noise.
    if [ "$INTERACTIVE" = 1 ]; then
        echo "❌ Build failed — see $BUILD_LOG" >&2
        exit 1
    fi
fi
