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

_docker_build() { # <args…>
    if [ "$INTERACTIVE" = 1 ]; then
        # Straight to the terminal — no pipe, no redirect. BuildKit only draws its progress
        # UI when stdout is a tty, so even `| tee` demotes it to a scrolling wall of text.
        # The log is there for the backgrounded case, which is when nobody is watching.
        docker build "$@"
    else
        docker build "$@" >>"$BUILD_LOG" 2>&1
    fi
}

build_image() {
    : >"$BUILD_LOG"
    [ "$INTERACTIVE" = 0 ] \
        || echo "🔨 Building $IMAGE_NAME with Claude Code ${LATEST_VERSION:-latest}..." >&2
    # The cache rides in the image, so the VM's daily cleanup may drop the build cache whole.
    _docker_build --build-arg CLAUDE_VERSION="${LATEST_VERSION:-latest}" \
        --build-arg BUILDKIT_INLINE_CACHE=1 --cache-from "${IMAGE_NAME}:latest" \
        -t "${IMAGE_NAME}:building" "$@" "$KIB_ROOT"
}

# The redaction view runs on THIS host, so it is built for it and taken out of the build, never
# into the image. Renamed into place: a running view keeps its own inode.
build_view() {
    local arch tmp src="host/view guest/policy/global.kibignore tests/fixtures/redaction Dockerfile"
    # Built only when its sources changed: it has no build cache to make a rebuild cheap.
    # shellcheck disable=SC2086 # one path per word
    [ -x "$KIB_VIEW" ] && [ -z "$(cd "$KIB_ROOT" && find $src -newer "$KIB_VIEW" | head -n 1)" ] \
        && return 0
    arch="$(uname -m)"
    case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
    mkdir -p "$KIB_HOST_ONLY" && chmod 700 "$KIB_HOST_ONLY"
    tmp="$(mktemp -d "$KIB_HOST_ONLY/.build.XXXXXX")" || return 1
    _docker_build --target view --build-arg VIEW_OS="$KIB_OS" --build-arg VIEW_ARCH="$arch" \
        --output "type=local,dest=$tmp" "$KIB_ROOT" && mv -f "$tmp/kib-view" "$KIB_VIEW" \
        && touch "$KIB_VIEW" # a cached build exports its old mtime
    local rc=$?
    rm -rf "$tmp"
    return "$rc"
}

if build_image "$@" && build_view \
    && docker tag "${IMAGE_NAME}:building" "${IMAGE_NAME}:latest" \
    && docker rmi "${IMAGE_NAME}:building" >>"$BUILD_LOG" 2>&1; then
    echo "✅ Build complete — new image ready for next launch" >>"$BUILD_LOG"
    # The old :latest is now dangling. Label-scoped; Docker skips any a container still uses.
    docker image prune -f --filter label=keep-it-in-your-box >>"$BUILD_LOG" 2>&1 || true
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
