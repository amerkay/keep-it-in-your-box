#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="claude-code-sandbox"
BUILD_LOCK="$SCRIPT_DIR/build.lock"
BUILD_LOG="$SCRIPT_DIR/build.log"
BUILD_PID="$SCRIPT_DIR/build.pid"

exec 9>"$BUILD_LOCK"
flock 9

cleanup() {
    rm -f "$BUILD_PID"
}
trap cleanup EXIT

if docker build --build-arg CACHE_BUST="$(date +%s)" -t "${IMAGE_NAME}:building" "$SCRIPT_DIR" > "$BUILD_LOG" 2>&1 \
    && docker tag "${IMAGE_NAME}:building" "${IMAGE_NAME}:latest" \
    && docker rmi "${IMAGE_NAME}:building" >> "$BUILD_LOG" 2>&1; then
    echo "✅ Build complete — new image ready for next launch" >> "$BUILD_LOG"
    notify-send -i dialog-information "Claude Code" "Image rebuild complete — new version ready for next launch" 2>/dev/null || true
else
    echo "❌ Build failed — see $BUILD_LOG" >> "$BUILD_LOG"
    notify-send -i dialog-error "Claude Code" "Image rebuild failed — check $BUILD_LOG" 2>/dev/null || true
fi
