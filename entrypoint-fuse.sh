#!/bin/sh
# Sourced by docker-entrypoint.sh (root path) when CC_FUSE_INTERNAL=1 — the single-
# container FUSE redaction mode used on macOS (and on Linux under CC_SINGLE_CONTAINER=1,
# the test vehicle). Runs as root while the container still has CAP_SYS_ADMIN, and:
#
#   1. mounts ccignore-fuse.py's redacted view of /cc/real AT $CC_FUSE_MNT — the project's
#      real host path — so the agent only ever sees the redacted project;
#   2. keeps the real project unreachable except through that view (/cc is root-700);
#   3. sets CC_EXEC_PREFIX so docker-entrypoint.sh's final exec drops CAP_SYS_ADMIN (and
#      SETPCAP) from the bounding set before the agent runs. The caps exist only in this
#      pre-agent window; the agent tree is capless (gosu → uid 1000, no-new-privileges).
#
# On any failure it aborts the container rather than run unprotected — the same
# never-run-unprotected rule the sidecar enforces on the host side.
#
# POSIX sh (baked into the image, invoked via `.` — no bash-isms, no `local`).

: "${CC_FUSE_MNT:?entrypoint-fuse: CC_FUSE_MNT is unset}"

# The mountpoint the kernel records is the *resolved* path: the HOST_HOME symlink the main
# entrypoint just created (e.g. /Users/kay → /home/hostuser) means a mount requested at
# $CC_FUSE_MNT is recorded under its realpath. Compare against that, or a successful mount
# would read as "not live" and we would wrongly abort. mkdir -p runs first so realpath resolves.
mkdir -p "$CC_FUSE_MNT" 2>/dev/null || true
CC_FUSE_MNT_REAL="$(readlink -f "$CC_FUSE_MNT" 2>/dev/null || echo "$CC_FUSE_MNT")"

_fuse_live() { # true if a fuse fs is mounted at the (resolved) mountpoint
    awk -v p="$CC_FUSE_MNT_REAL" '$2==p && $3 ~ /^fuse/ {ok=1} END{exit !ok}' /proc/self/mounts 2>/dev/null
}

_fuse_abort() {
    echo "✗ cc: $1" >&2
    echo "  Refusing to run unprotected — neither .ccignore nor the host-config guard" >&2
    echo "  would be enforced. Aborting the container." >&2
    exit 1
}

# The agent must reach the real project ONLY through the redacted view. /cc/real is the
# real project bind; locking its parent to root-700 stops a non-root uid traversing in.
# (The mountpoint itself was created above, before resolving CC_FUSE_MNT_REAL.)
chmod 700 /cc 2>/dev/null || true

# The redacting server runs in the foreground internally, so background the process.
# allow_other (baked default in ccignore-fuse.py) lets the agent uid read the root-served
# mount; the server enforces redaction and the host-config guard uid-independently.
# Invoked via python3 (like the sidecar's --entrypoint python3), NOT as an executable: the
# :ro bind mount shadows the baked chmod+x copy with the host file, whose execute bit may
# not survive, so relying on it fails with EACCES.
python3 /usr/local/bin/ccignore-fuse.py --src /cc/real --mnt "$CC_FUSE_MNT" \
    --patterns-file /cc/patterns --guard-file /usr/local/share/global.ccignore &
_CC_FUSE_PID=$!

# Wait up to ~5s for the mount to appear; give up early if the server has died.
_i=0
while [ "$_i" -lt 100 ]; do
    _fuse_live && break
    kill -0 "$_CC_FUSE_PID" 2>/dev/null || break
    _i=$((_i + 1))
    sleep 0.05
done
_fuse_live || _fuse_abort "the in-container FUSE redaction mount never came up at $CC_FUSE_MNT."

# Drop CAP_SYS_ADMIN (needed only to mount) and CAP_SETPCAP (needed only to perform this
# drop) from the bounding set for everything the agent runs. Fail closed if setpriv is
# missing rather than leave the agent SYS_ADMIN-capable.
command -v setpriv >/dev/null 2>&1 \
    || _fuse_abort "setpriv (util-linux) not found; cannot drop CAP_SYS_ADMIN before the agent."
CC_EXEC_PREFIX="setpriv --bounding-set -sys_admin,-setpcap"
export CC_EXEC_PREFIX

echo "🛡️  cc: single-container FUSE redaction mounted at $CC_FUSE_MNT; SYS_ADMIN dropped." >&2
