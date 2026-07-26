#!/bin/sh
# Sourced by docker-entrypoint.sh (root path) — kib's redaction layer, on every platform. Runs
# as root while the container still has CAP_SYS_ADMIN, and:
#
#   1. mounts the redacted view of /kib/real AT $KIB_FUSE_MNT (the project's real host path),
#      so the agent only ever sees the redacted project;
#   2. keeps the real project unreachable except through that view (/kib is root-700);
#   3. sets KIB_EXEC_PREFIX so the final exec drops SYS_ADMIN and SETPCAP from the bounding
#      set — they exist only in this pre-agent window, and the agent tree is capless.
#
# Aborts the container on any failure rather than run unprotected.
# POSIX sh, baked into the image and invoked via `.` — no bash-isms, no `local`.

: "${KIB_FUSE_MNT:?entrypoint-fuse: KIB_FUSE_MNT is unset}"

# The kernel records the RESOLVED mountpoint: the HOST_HOME symlink the main entrypoint just
# created means a mount requested at $KIB_FUSE_MNT is recorded under its realpath, so comparing
# raw would read a live mount as dead and abort. mkdir -p first, so realpath can resolve.
mkdir -p "$KIB_FUSE_MNT" 2>/dev/null || true
KIB_FUSE_MNT_REAL="$(readlink -f "$KIB_FUSE_MNT" 2>/dev/null || echo "$KIB_FUSE_MNT")"

_fuse_live() { # true if a fuse fs is mounted at the (resolved) mountpoint
    awk -v p="$KIB_FUSE_MNT_REAL" '$2==p && $3 ~ /^fuse/ {ok=1} END{exit !ok}' /proc/self/mounts 2>/dev/null
}

_fuse_abort() {
    echo "✗ kib: $1" >&2
    echo "  Refusing to run unprotected — neither .kibignore nor the host-config guard" >&2
    echo "  would be enforced. Aborting the container." >&2
    exit 1
}

# /kib/real is the real project bind; root-700 on its parent stops a non-root uid traversing in,
# so the redacted view is the only way to the project.
chmod 700 /kib 2>/dev/null || true

# The server runs in the foreground internally, hence the background. allow_other lets the agent
# uid read the root-served mount; the server enforces redaction uid-independently.
#
# /usr/local/bin/fuse is the BAKED shim, so its execute bit is the image's. Only the kib package
# is bind-mounted — a host file's execute bit may not survive a :ro bind (EACCES), which is why
# invoking the mounted .py directly needed an explicit `python3`.
#
# --uid/--gid: the ids reported in place of whoever owns the project ROOT, and only them. On
# macOS the project reaches this container over the engine VM's virtiofs, which reports every
# file as root:root — without that git refuses the whole tree ("dubious ownership") and nothing
# that shells out to it works. On Linux the base ids are already the agent's, so the map is
# identity. A file owned by someone else keeps its real ids, so the mount's default_permissions
# still refuses it.
/usr/local/bin/fuse --src /kib/real --mnt "$KIB_FUSE_MNT" \
    --uid "${HOST_UID:-1000}" --gid "${HOST_GID:-1000}" \
    --patterns-file /kib/patterns --guard-file /usr/local/share/global.kibignore &
_KIB_FUSE_PID=$!

# Wait up to ~5s for the mount to appear; give up early if the server has died.
_i=0
while [ "$_i" -lt 100 ]; do
    _fuse_live && break
    kill -0 "$_KIB_FUSE_PID" 2>/dev/null || break
    _i=$((_i + 1))
    sleep 0.05
done
_fuse_live || _fuse_abort "the in-container FUSE redaction mount never came up at $KIB_FUSE_MNT."

# Drop CAP_SYS_ADMIN (needed only to mount) and CAP_SETPCAP (needed only to perform this
# drop) from the bounding set for everything the agent runs. Fail closed if setpriv is
# missing rather than leave the agent SYS_ADMIN-capable.
command -v setpriv >/dev/null 2>&1 \
    || _fuse_abort "setpriv (util-linux) not found; cannot drop CAP_SYS_ADMIN before the agent."
KIB_EXEC_PREFIX="setpriv --bounding-set -sys_admin,-setpcap"
export KIB_EXEC_PREFIX

echo "🛡️  kib: FUSE redaction mounted at $KIB_FUSE_MNT; SYS_ADMIN dropped." >&2
