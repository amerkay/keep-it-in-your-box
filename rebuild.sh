#!/usr/bin/env bash
# Rebuild the keep-it-in-your-box image on the host.
# Use after editing baked-in files (Dockerfile, ccignore-fuse.py,
# docker-entrypoint.sh). Layer caching keeps it fast unless an early
# layer changed. Any extra args are passed through to `docker build`.
set -euo pipefail

IMAGE_NAME="keep-it-in-your-box"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pin the latest Claude Code release so the rebuild doesn't drift.
LATEST_VERSION="$(curl -sf https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/latest 2>/dev/null | tr -d '[:space:]' || true)"

echo "🔨 Rebuilding $IMAGE_NAME (Claude Code ${LATEST_VERSION:-latest})..." >&2
docker build \
    --build-arg CLAUDE_VERSION="${LATEST_VERSION:-latest}" \
    -t "$IMAGE_NAME" "$@" "$SCRIPT_DIR"
echo "✅ Done. Start cc again to use the rebuilt image." >&2
