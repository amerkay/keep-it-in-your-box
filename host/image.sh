#!/usr/bin/env bash
# Image existence, version lookup and the background-rebuild prompt.
#
# Reads:  KIB_ROOT IMAGE_NAME BUILD_LOCK BUILD_LOG BUILD_PID
# Writes: nothing global

CLAUDE_DIST_URL="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/latest"

latest_claude_version() {
    curl -sf "$CLAUDE_DIST_URL" 2>/dev/null | tr -d '[:space:]' || true
}

build_image_if_missing() {
    docker image inspect "$IMAGE_NAME" &>/dev/null && return 0
    echo "🔨 Building Claude Code image (first time, please wait)..." >&2
    local latest
    latest="$(latest_claude_version)"
    docker build --build-arg CLAUDE_VERSION="${latest:-latest}" -t "$IMAGE_NAME" "$KIB_ROOT"
}

check_for_updates() {
    mkdir -p "$KIB_BUILD_DIR" 2>/dev/null || true
    # Never unlink build.lock (see host/core.sh). Test it in place instead; flock creates
    # the file if it is absent.
    if ! lock_fd -n "$BUILD_LOCK" true 2>/dev/null; then
        local running
        running="$(cat "$BUILD_PID" 2>/dev/null || true)"
        echo "🔨 Background image rebuild in progress... (log: $BUILD_LOG)" >&2
        [ -n "$running" ] && echo "   To cancel: kill -TERM -$running" >&2
        return 0
    fi

    echo "🔍 Checking for Claude Code updates..." >&2
    local installed latest
    installed="$(docker run --rm --entrypoint="" "$IMAGE_NAME" cat /etc/claude-code-version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    # Old images predate /etc/claude-code-version.
    [ -n "$installed" ] || installed="$(docker run --rm --entrypoint="" "$IMAGE_NAME" claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    latest="$(latest_claude_version)"
    echo "   Installed: ${installed:-unknown}" >&2
    echo "   Latest:    ${latest:-unknown}" >&2

    if [ -z "$latest" ] || { [ -n "$installed" ] && [ "$installed" = "$latest" ]; }; then
        echo "   ✓ Up to date" >&2
        return 0
    fi

    echo "⬆️  Claude Code update available: $installed → $latest" >&2
    # `|| answer=""`: read exits 1 on EOF, which under `set -e` would kill a
    # non-interactive run (`kib claude -p '…' < /dev/null`) before the session started.
    local answer=""
    read -rp "Rebuild image in background? [y/N] " answer || answer=""
    [[ "$answer" =~ ^[Yy]$ ]] || return 0
    # Its own process group, so `kill -TERM -PGID` kills the whole build tree. `--background`
    # plus the redirect are belt-and-braces for the same thing: setsid leaves fd 1 on the
    # user's terminal, so without them the build streams its BuildKit UI over the session.
    detach_pgrp "$KIB_ROOT/tools/build-bg.sh" --background >/dev/null 2>&1
    echo $! >"$BUILD_PID"
    disown
    echo "🔨 Starting background rebuild... (log: $BUILD_LOG)" >&2
    echo "   To cancel: kill -TERM -$(cat "$BUILD_PID")" >&2
}
