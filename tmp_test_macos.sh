#!/usr/bin/env bash
# Throwaway probe — DELETE once the sidecar plan is decided. Run on macOS, in a host terminal.
#
# Answers one question: can a FUSE mount made in a sidecar container reach the agent's
# container on Docker Desktop, when the propagation root is a path that exists only inside
# the LinuxKit VM?
#
# The old sidecar rooted propagation at /tmp, which on a Mac is a macOS directory exposed
# over virtiofs — a file-sharing protocol, not a mount namespace, so a mount event has
# nowhere to propagate. Both containers share the VM's kernel, so a VM-internal root should
# behave like any two containers on Linux.
#
#   ./tmp_test_macos.sh               run the probes
#   ./tmp_test_macos.sh --fix-shared  first make the VM root rshared (privileged, VM state)
#   ./tmp_test_macos.sh --keep        leave the containers up for poking at
#
# bash 3.2 / BSD clean. No sudo. Nothing touches your project.

set -uo pipefail

# /run does not exist on macOS and is not in Docker Desktop's file-sharing list (/Users,
# /Volumes, /private, /tmp), so the daemon creates it INSIDE the VM. /var would be a trap:
# it is a symlink to /private/var, which IS shared, so it would land on the Mac instead.
PROBE_ROOT="/run/kib-probe"
# Resolved from the script, not $PWD, so it works from anywhere.
KIB_ROOT="$(cd "$(dirname "$0")" && pwd)"
BASE_IMAGE="alpine:3.20"
KIB_IMAGE="${KIB_IMAGE:-keep-it-in-your-box}"
A="kibprobe-sidecar"
B="kibprobe-agent"

FIX_SHARED=0
KEEP=0
for arg in ${@+"$@"}; do
    case "$arg" in
        --fix-shared) FIX_SHARED=1 ;;
        --keep) KEEP=1 ;;
        -h | --help)
            sed -n '2,16p' "$0"
            exit 0
            ;;
        *)
            echo "unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

pass=0
fail=0
skip=0
NOTES=""

_ok() {
    printf '  \033[32m✔\033[0m %s\n' "$1"
    pass=$((pass + 1))
}

_no() {
    printf '  \033[31m✘\033[0m %s\n' "$1"
    [ -n "${2:-}" ] && printf '      %s\n' "$2"
    fail=$((fail + 1))
    NOTES="$NOTES
  - $1"
}

_skip() {
    printf '  \033[33m∅\033[0m %s\n' "$1"
    [ -n "${2:-}" ] && printf '      %s\n' "$2"
    skip=$((skip + 1))
}

_section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# _try <desc> <hint-on-failure> <cmd...>
_try() {
    _desc="$1"
    _hint="$2"
    shift 2
    if "$@" >/dev/null 2>&1; then _ok "$_desc"; else _no "$_desc" "$_hint"; fi
}

# _want <desc> <expected> <actual> <hint>
_want() {
    if [ "$2" = "$3" ]; then _ok "$1"; else _no "$1" "$4"; fi
}

# A privileged throwaway container in the VM's own mount namespace. The only way to observe
# or clean VM-internal state from macOS — the Mac cannot see these mounts at all.
_vm() {
    docker run --rm --privileged --pid=host "$BASE_IMAGE" \
        nsenter -t 1 -m -u -i -n -- "$@" 2>&1
}

# Propagation of mountpoint $2 as seen inside container $1. Read from /proc/self/mountinfo,
# not findmnt: alpine ships no util-linux, and mountinfo is the source of truth anyway —
# 'shared:N' and/or 'master:N' appear in the optional fields, between field 7 and the '-'.
_prop_in() {
    docker exec "$1" awk -v p="$2" '
        $5 == p {
            for (i = 7; i <= NF && $i != "-"; i++) {
                if ($i ~ /^shared:/) s = 1
                if ($i ~ /^master:/) m = 1
            }
            if (s && m) print "shared,slave"
            else if (s) print "shared"
            else if (m) print "slave"
            else print "private"
            exit
        }' /proc/self/mountinfo 2>/dev/null | tr -d '\r'
}

# Is there a mount at $1 in the VM? ($2, if given, must match the fs type prefix.)
_vm_mounted() {
    _vm sh -c "awk -v p='$1' -v t='${2:-}' '\$2==p && (t==\"\" || index(\$3,t)==1) {f=1}
               END{exit !f}' /proc/self/mounts" >/dev/null 2>&1
}

_rm_containers() { docker rm -f "$A" "$B" >/dev/null 2>&1; }

# shellcheck disable=SC2317  # invoked via trap
_cleanup() {
    if [ "$KEEP" -eq 1 ]; then
        printf '\n--keep: leaving %s and %s up. Clean up with:\n  docker rm -f %s %s\n' \
            "$A" "$B" "$A" "$B"
        return
    fi
    _rm_containers
    # Unmount before removing the dir, exactly as the real teardown must: the other order
    # orphans a stale ENOTCONN mount in the VM until it reboots.
    _vm sh -c "umount -l $PROBE_ROOT/mnt 2>/dev/null
               umount -l $PROBE_ROOT 2>/dev/null
               rm -rf $PROBE_ROOT" >/dev/null 2>&1
}
trap _cleanup EXIT INT TERM

# ── preflight ────────────────────────────────────────────────────
_section "Preflight"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "  This probe is for macOS. The Linux equivalent is one command:"
    echo "    findmnt -no PROPAGATION --target ~/.local/state"
    exit 2
fi

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "  No reachable Docker engine — start Docker Desktop first." >&2
    exit 1
fi
_ok "engine reachable ($(docker info --format '{{.OperatingSystem}}' 2>/dev/null))"

if ! docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
    echo "  pulling $BASE_IMAGE ..."
    if ! docker pull -q "$BASE_IMAGE" >/dev/null 2>&1; then
        echo "  could not pull $BASE_IMAGE" >&2
        exit 1
    fi
fi

HAVE_KIB=0
docker image inspect "$KIB_IMAGE" >/dev/null 2>&1 && HAVE_KIB=1

if [ "$FIX_SHARED" -eq 1 ]; then
    echo "  --fix-shared: making the VM root rshared (privileged container, VM state only)"
    _vm mount --make-rshared / >/dev/null 2>&1
fi
_rm_containers

# ── T1 ───────────────────────────────────────────────────────────
# If Docker Desktop resolved the path host-side, everything below is meaningless: the mount
# would land on a virtiofs share and the premise collapses.
_section "T1 · the propagation root lives in the VM, not on the Mac"

_try "Docker accepts a bind at $PROBE_ROOT" \
    "'Mounts denied' here means macOS claims the path — pick one it does not know" \
    docker run --rm -v "$PROBE_ROOT:/probe" "$BASE_IMAGE" sh -c 'echo vm > /probe/marker'

if [ -e "$PROBE_ROOT" ]; then
    _no "$PROBE_ROOT EXISTS on the Mac — the daemon resolved it host-side" \
        "the mountpoint must be VM-internal; this path is not"
else
    _ok "$PROBE_ROOT does not exist on the Mac (VM-internal, as required)"
fi

_try "the marker file is visible inside the VM" \
    "the bind went somewhere unexpected — neither the Mac nor the VM" \
    _vm test -f "$PROBE_ROOT/marker"

# ── T2 ───────────────────────────────────────────────────────────
_section "T2 · the root accepts rshared propagation"

# Bind-to-self, then --make-rshared: a plain directory cannot be a propagation peer until it
# is a mount in its own right. On Linux this comes free from systemd's rshared /.
_vm sh -c "mkdir -p $PROBE_ROOT/mnt
           mount --bind $PROBE_ROOT $PROBE_ROOT
           mount --make-rshared $PROBE_ROOT" >/dev/null 2>&1

PROP="$(_vm sh -c "findmnt -no PROPAGATION --target $PROBE_ROOT" | tr -d '\r')"
case "$PROP" in
    *shared*) _ok "propagation at $PROBE_ROOT is '$PROP'" ;;
    *) _no "propagation is '${PROP:-unknown}', not shared" \
        "retry with --fix-shared, which runs 'mount --make-rshared /' in the VM" ;;
esac

_try "docker run accepts :rshared on it" \
    "this is the hard gate — without it the design is dead" \
    docker run --rm -v "$PROBE_ROOT:/views:rshared" "$BASE_IMAGE" true

# ── T3 ───────────────────────────────────────────────────────────
# tmpfs, not FUSE: isolates propagation from every FUSE-specific variable.
_section "T3 · a mount made in the sidecar reaches the agent (tmpfs)"

docker run -d --name "$A" --privileged \
    -v "$PROBE_ROOT:/views:rshared" "$BASE_IMAGE" sleep 900 >/dev/null 2>&1
docker run -d --name "$B" \
    -v "$PROBE_ROOT:/views:rslave" "$BASE_IMAGE" sleep 900 >/dev/null 2>&1

if docker exec "$A" sh -c 'mkdir -p /views/m && mount -t tmpfs none /views/m &&
                           echo propagated > /views/m/f' >/dev/null 2>&1; then
    _ok "sidecar mounted tmpfs at /views/m"
    _want "the agent container SEES the mount — propagation works" \
        "propagated" "$(docker exec "$B" cat /views/m/f 2>/dev/null | tr -d '\r')" \
        "propagation did not cross containers; the design is dead"
else
    _no "the sidecar could not mount tmpfs at /views/m" ""
fi
_rm_containers

# ── T4 ───────────────────────────────────────────────────────────
# Production sidecar is NOT --privileged: unprivileged, your uid, no network. --userns=host
# matters — under userns-remap, propagation silently degrades to slave.
_section "T4 · propagation holds with the sidecar's real flags"

docker run -d --name "$A" \
    --cap-drop=ALL --cap-add=SYS_ADMIN \
    --device /dev/fuse --security-opt apparmor=unconfined \
    --user "$(id -u):$(id -g)" --userns=host --network none \
    -v "$PROBE_ROOT:/views:rshared" "$BASE_IMAGE" sleep 900 >/dev/null 2>&1

if docker ps --format '{{.Names}}' | grep -q "^${A}$"; then
    _ok "sidecar starts unprivileged (uid $(id -u), cap SYS_ADMIN only, --network none)"
    SPROP="$(_prop_in "$A" /views)"
    case "$SPROP" in
        *shared*) _ok "inside the sidecar /views is '$SPROP'" ;;
        *) _no "inside the sidecar /views is '${SPROP:-unknown}', not shared" \
            "'shared,slave' here means the daemon runs with --userns-remap" ;;
    esac
else
    _no "the sidecar would not start with production flags" "$(docker logs "$A" 2>&1 | tail -3)"
fi
_rm_containers

# ── T5 ───────────────────────────────────────────────────────────
# The one that matters. tmpfs propagating proves nothing about FUSE: /dev/fuse lives only in
# the sidecar, and the agent must reach the view with cap-drop=ALL and none of its own.
_section "T5 · a real FUSE view, consumed by a locked-down agent"

if [ "$HAVE_KIB" -eq 0 ]; then
    _skip "no '$KIB_IMAGE' image — cannot mount a real FUSE view" \
        "run 'kib build' first, or set KIB_IMAGE=<name>. T1-T4 still tell you most of it."
else
    SRC="$(mktemp -d /tmp/kibprobe.XXXXXX)"
    echo "visible" >"$SRC/normal.txt"
    echo "SECRET=nope" >"$SRC/.env"
    # An empty project rule file. The .env redaction under test comes from the GUARD file
    # (guest/policy/global.kibignore), which is what every project gets whether it has a
    # .kibignore or not — so pass the real one, or the .env assertion passes for free.
    PAT="$SRC.patterns"
    : >"$PAT"

    # The mountpoint must be owned by whoever mounts. The old sidecar got this free — the
    # HOST user did the mkdir. Here a root VM helper does it, so hand it over explicitly or
    # fusermount3 refuses a mountpoint the caller does not own.
    _vm sh -c "mkdir -p $PROBE_ROOT/mnt && chown $(id -u):$(id -g) $PROBE_ROOT/mnt" \
        >/dev/null 2>&1

    # $1 = --user arg ("" for root). Starts the server and waits up to 15s for the mount.
    _start_fuse() {
        _rm_containers
        _u=${1:+--user $1}
        # shellcheck disable=SC2086  # $_u must word-split into a flag pair, or nothing
        docker run -d --name "$A" \
            --cap-drop=ALL --cap-add=SYS_ADMIN \
            --device /dev/fuse --security-opt apparmor=unconfined \
            $_u --userns=host --network none \
            -v "$SRC:/src" \
            -v "$PAT:/patterns:ro" \
            -v "$KIB_ROOT/guest/policy/global.kibignore:/guard:ro" \
            -v "$PROBE_ROOT:$PROBE_ROOT:rshared" \
            -v "$KIB_ROOT/kib:/usr/local/lib/kib:ro" \
            --entrypoint /usr/local/bin/fuse \
            "$KIB_IMAGE" \
            --src /src --mnt "$PROBE_ROOT/mnt" \
            --patterns-file /patterns --guard-file /guard \
            --uid "$(id -u)" --gid "$(id -g)" >/dev/null 2>&1
        _i=0
        while [ "$_i" -lt 60 ]; do
            _vm_mounted "$PROBE_ROOT/mnt" fuse && return 0
            _i=$((_i + 1))
            sleep 0.25
        done
        return 1
    }

    mounted=0
    if _start_fuse "$(id -u):$(id -g)"; then
        mounted=1
        _ok "the FUSE view mounted UNPRIVILEGED (uid $(id -u)) — the goal state"
    else
        # A/B: does it work as root? That separates "FUSE cannot propagate on Docker
        # Desktop" (fatal) from "this uid cannot mount" (a fixable plumbing detail).
        printf '      unprivileged mount failed; retrying as root to localise it...\n'
        UNPRIV_LOG="$(docker logs "$A" 2>&1 | tail -20)"
        if _start_fuse ""; then
            mounted=1
            _no "the view mounts as ROOT but not as uid $(id -u)" \
                "not fatal: the topology works, the sidecar's user does not. Unprivileged log:"
            printf '%s\n' "$UNPRIV_LOG" | sed 's/^/        /'
            _section "T5 diagnostics (why uid $(id -u) could not mount)"
            printf '  mountpoint in VM : %s\n' \
                "$(_vm sh -c "ls -ldn $PROBE_ROOT/mnt" | tr -d '\r')"
            printf '  /dev/fuse in ctr : %s\n' \
                "$(docker exec "$A" ls -ln /dev/fuse 2>&1 | tr -d '\r')"
            printf '  CapEff as uid    : %s\n' \
                "$(docker run --rm --cap-drop=ALL --cap-add=SYS_ADMIN \
                    --user "$(id -u):$(id -g)" --userns=host "$KIB_IMAGE" \
                    sh -c 'grep ^CapEff /proc/self/status' 2>&1 | tr -d '\r')"
            printf '  CapEff as root   : %s\n' \
                "$(docker run --rm --cap-drop=ALL --cap-add=SYS_ADMIN \
                    --userns=host "$KIB_IMAGE" \
                    sh -c 'grep ^CapEff /proc/self/status' 2>&1 | tr -d '\r')"
        fi
    fi

    if [ "$mounted" -eq 0 ]; then
        _no "the FUSE view never mounted in the VM, as any user" ""
        printf '      --- full sidecar log ---\n'
        docker logs "$A" 2>&1 | sed 's/^/      /'
    else
        # The agent exactly as it will be rebuilt: no SYS_ADMIN, no /dev/fuse, no apparmor
        # override, no-new-privileges on.
        docker run -d --name "$B" \
            --cap-drop=ALL --cap-add=SETUID --cap-add=SETGID --cap-add=CHOWN \
            --cap-add=DAC_OVERRIDE --cap-add=FOWNER \
            --security-opt no-new-privileges \
            --user "$(id -u):$(id -g)" --userns=host \
            -v "$PROBE_ROOT/mnt:/work:rslave" "$BASE_IMAGE" sleep 900 >/dev/null 2>&1

        _want "the agent reads a normal file through the propagated view" \
            "visible" "$(docker exec "$B" cat /work/normal.txt 2>/dev/null | tr -d '\r')" \
            "propagation reached it, but the FUSE fs is not usable from there"

        if docker exec "$B" grep -q "SECRET=nope" /work/.env 2>/dev/null; then
            _no ".env leaked its real contents" "redaction did not survive propagation"
        else
            _ok ".env does not expose its contents (redaction survives propagation)"
        fi

        _try "the agent can WRITE through the view" \
            "likely the fakeowner root:root uid mismatch — check --uid/--gid" \
            docker exec "$B" sh -c 'echo x > /work/newfile'

        _want "files report your uid — git will not cry 'dubious ownership'" \
            "$(id -u)" "$(docker exec "$B" stat -c %u /work/normal.txt 2>/dev/null | tr -d '\r')" \
            "git will refuse the whole tree"

        _section "T6 · teardown leaves nothing behind"
        docker rm -f "$A" >/dev/null 2>&1
        sleep 1
        if _vm_mounted "$PROBE_ROOT/mnt"; then
            _no "a stale mount survives after the sidecar died" \
                "teardown must unmount explicitly — from macOS that needs a VM helper"
        else
            _ok "the mount died with the sidecar (no explicit unmount needed)"
        fi

        if docker exec "$B" ls /work >/dev/null 2>&1; then
            _skip "the agent's /work still resolves after the sidecar died" \
                "confirm by hand that it is EMPTY, not the unredacted source"
        else
            _ok "the agent's view is gone too, as expected"
        fi
    fi
    rm -rf "$SRC" "$PAT"
fi

# ── verdict ──────────────────────────────────────────────────────
_section "Verdict"
printf '  %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"

if [ "$fail" -eq 0 ]; then
    cat <<'EOF'

  GREEN — the sidecar can be restored as the ONE topology on both platforms.
  The agent's container goes back to cap-drop=ALL with no /dev/fuse and no
  apparmor override, and macOS keeps working on Docker Desktop.
EOF
else
    printf '\n  RED — do not build yet. Failing:%s\n' "$NOTES"
    cat <<'EOF'

  If only T2 failed, retry once with --fix-shared. If T3 failed even after
  that, mounts do not cross containers on this engine, and the plan needs
  rethinking rather than patching.
EOF
fi

exit $((fail > 0))
