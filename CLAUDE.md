# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Docker-based sandbox for running Claude Code in an isolated container. The `cc` script builds and runs a Docker container that mirrors the host user's UID/GID, mounts the current project directory, and forwards Claude's auth/config.

## Architecture

- **`cc`** — Host-side launcher script. Builds the image if missing, checks for Claude Code updates on each launch, then `docker run` with volume mounts, seccomp profile, and environment forwarding. Run from any project directory: `./cc` (or with args passed through to the container CMD).
- **`build-bg.sh`** — Background image rebuild script. Launched by `cc` when user accepts an update. Uses `flock` on `build.lock` to prevent concurrent builds, runs in its own process group (`setsid`) for clean cancellation. Sends desktop notification on completion.
- **`Dockerfile`** — Debian bookworm image with Node.js 20, Python 3, dev tools, and Claude Code installed via official installer. Supports `CUSTOM_PACKAGES` build arg. Use `CACHE_BUST` arg to force Claude Code reinstall. Stores installed version in `/etc/claude-code-version`.
- **`docker-entrypoint.sh`** — Creates a non-root user matching host UID/GID, fixes ownership of mounted config dirs, sets up Wayland clipboard access, then `exec gosu` to drop privileges.
- **`seccomp.json`** — Docker default seccomp + `clone`/`clone3`/`unshare`/`mount`/`umount2` allowed (no `CLONE_NEWUSER` restriction) so bubblewrap sandbox works inside the container.

## Key Design Decisions

- Project is mounted at the **same absolute path** as on the host so Claude's path-keyed project configs resolve correctly.
- Claude's `.claude/` and `.claude.json` are mounted at both host home and `/home/hostuser/` paths.
- No `CAP_SYS_ADMIN` — mount syscalls only work inside unprivileged user namespaces. AppArmor is set to unconfined for bwrap bind mounts.
- Default CMD runs `claude --dangerously-skip-permissions`.
- **Auto-update check**: On each launch, `cc` compares the installed Claude Code version (from `/etc/claude-code-version` in the image, with fallback to `claude --version`) against the latest npm version. If an update is available, user is prompted to rebuild in the background while continuing to use the current image. A lock file (`build.lock`) prevents concurrent rebuilds.

## Build & Run

```bash
# Build image (happens automatically on first run)
docker build -t claude-code-sandbox .

# Run from any project directory
/path/to/cc                    # default: launches claude
/path/to/cc bash               # override CMD to get a shell
/path/to/cc claude --resume    # pass args through

# Rebuild with custom packages
docker build --build-arg CUSTOM_PACKAGES="golang ruby" -t claude-code-sandbox .

# Force reinstall Claude Code (bust cache)
docker build --build-arg CACHE_BUST=$(date +%s) -t claude-code-sandbox .
```
