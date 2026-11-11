#!/usr/bin/env bash
# Docker runs in a Lima VM and the box runs on gVisor inside it, while kib stays on the host: a
# kernel exploit needs a gVisor bug, then a VM kernel bug (docs/vm.md). Same ~/.claude, login and
# broker either way: kib itself never moves. The VM shares ~/.claude and kib's own dirs, a fixed
# set, so it never restarts for a project; projects reach it only as their redacted views, which
# it mounts from the host over NFS (vm_view_mount).
#
# Reads:  KIB_CONFIG KIB_STATE_ROOT KIB_ROOT HOME LIMA_VM_TYPE LIMA_MOUNT_TYPE KIB_NODE_CACHE
# Writes: DOCKER_HOST DOCKER_CONFIG (exported) _KIB_ENGINE_VM KIB_HOST_GATEWAY VM_MOUNTS VM_WANT
#         PATH GVISOR_RUNTIME
# shellcheck disable=SC2034

KIB_VM_NAME="kib-vm"
VM_LOCK="$KIB_STATE_ROOT/.locks/vm.lock"
VM_SPEC="$KIB_STATE_ROOT/vm-spec"   # the mount set the VM was last booted with
VM_GROW="$KIB_STATE_ROOT/vm-memory" # GiB for its next boot, after an out-of-memory kill
# ponytail: Lima's user-mode network address; read it from the VM if a network differs.
LIMA_HOST_IP=192.168.5.2

LIMA_VERSION=2.2.1
DOCKER_VERSION=29.9.3
BUILDX_VERSION=v0.38.2
GVISOR_VERSION=20261102.0
# Versioned, so a pin bump installs beside the old one and no running box loses its runtime.
GVISOR_RUNTIME="kib-gvisor-$GVISOR_VERSION"

# ~/.claude, then kib's own dirs, each at its own path; never ~ itself or a project, so ~/.ssh,
# ~/.aws and every raw project stay out of the VM. A dir inside one already listed shares its mount.
_vm_mounts() {
    local p
    VM_MOUNTS=(--mount-only "$HOME/.claude:w")
    for p in "$KIB_STATE_ROOT:w" "$KIB_NODE_CACHE:w" "$KIB_ROOT"; do _vm_mount "$p"; done
    VM_WANT="$LIMA_MOUNT_TYPE ${VM_MOUNTS[*]}"
}
_vm_mount() { # <dir[:w]>
    _vm_under "${1%:w}" "${VM_MOUNTS[@]}" || VM_MOUNTS+=(--mount-only "$1")
}
_vm_under() { # <path> <dir[:w]…>: the path is one of the dirs, or inside one
    local p="$1/" d
    shift
    for d; do case "$p" in "${d%:w}"/*) return 0 ;; esac done
    return 1
}

# One line and a dot a second, the log only if it fails. Its host agent outlives kib, so it must
# not inherit a lock fd.
_limactl() { # <message> <limactl verb> <args…>
    local pid log="$KIB_STATE_ROOT/vm.log"
    printf '🛡️  kib: %s' "$1" >&2
    limactl "$2" --tty=false "${@:3}" >"$log" 2>&1 200>&- 201>&- 205>&- 206>&- &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        printf '.' >&2
        sleep 1
    done
    echo >&2
    wait "$pid" && return 0
    tail -n 20 "$log" >&2
    die "Lima could not $2 the VM '$KIB_VM_NAME' (full log: $log)."
}

# Bring the VM up and hold its session count (fd 205, shared) until exit — the same reference
# count as the project lock. Boot (fd 206) serialises create, start, re-mount and gVisor.
vm_up() {
    local status
    mkdir -p "$KIB_STATE_ROOT/.locks"
    exec 205>"$VM_LOCK"
    lock_fd -w 120 -s 205 || die "timed out waiting for the VM to stop ($VM_LOCK)."
    exec 206>"$VM_LOCK.boot"
    lock_fd -x 206
    _vm_mounts
    _vm_mkdirs
    status="$(limactl list --format '{{.Status}}' "$KIB_VM_NAME" 2>/dev/null || true)"
    if [ -z "$status" ]; then
        _limactl "creating its VM — one time, a few minutes" start --name "$KIB_VM_NAME" \
            --vm-type="$LIMA_VM_TYPE" --mount-type="$LIMA_MOUNT_TYPE" \
            "${VM_MOUNTS[@]}" template:docker-rootful
        _vm_save
        _vm_booted
        status=Running
    elif [ "$VM_WANT" != "$(cat "$VM_SPEC" 2>/dev/null)" ]; then
        # A kib upgrade changed the mount set. Never cut a session, never bind what isn't mounted.
        lock_fd -n -x 205 || die "this kib changed the VM's mounts, and other kib sessions use it." \
            "Close them once; the next launch updates the VM (one restart)."
        limactl stop "$KIB_VM_NAME" >/dev/null 2>&1 || true
        # Not `edit --start`: an edit that changes nothing never starts the VM.
        _limactl "updating its VM's mounts" edit \
            --mount-type="$LIMA_MOUNT_TYPE" "${VM_MOUNTS[@]}" "$KIB_VM_NAME"
        _vm_save
        lock_fd -s 205
        status=Stopped
    fi
    if [ "$status" != Running ] && [ -s "$VM_GROW" ]; then
        _limactl "giving its VM $(cat "$VM_GROW") GiB of memory" edit \
            --memory "$(cat "$VM_GROW")" "$KIB_VM_NAME"
        rm -f "$VM_GROW"
    fi
    [ "$status" = Running ] || { _limactl "starting its VM" start "$KIB_VM_NAME" && _vm_booted; }
    _vm_docker
    _KIB_ENGINE_VM=1
    KIB_HOST_GATEWAY="$LIMA_HOST_IP"
    _vm_owners
    _vm_gvisor
    lock_fd -u 206
    exec 206>&-
}

_vm_docker() {
    unset DOCKER_CONTEXT
    DOCKER_HOST="unix://$(limactl list --format '{{.Dir}}' "$KIB_VM_NAME")/sock/docker.sock"
    export DOCKER_HOST
}
_vm_mkdirs() {
    local m
    for m in "${VM_MOUNTS[@]}"; do
        case "$m" in --*) ;; *) mkdir -p "${m%:w}" ;; esac
    done
}
_vm_save() { printf '%s\n' "$VM_WANT" >"$VM_SPEC"; } # the mount set the VM now has

# Apple's virtiofs reports a file as owned by whoever asks, so gVisor (root) sees kib's private
# dirs as root's and the box user is locked out. bindfs over each reports the host user instead.
# Never over kib's checkout: it hung `docker run` when kib was the project.
# --multithreaded: single-threaded, bindfs hung on the first stat of a transcript (measured).
# ulimit: it holds an fd per open dir, gVisor keeps one open per cached dir, and 1024 ran out
# on the plugin tree (EMFILE in the box).
_vm_owners() {
    is_macos || return 0
    local log="$KIB_STATE_ROOT/vm.log" d set=("$HOME/.claude" "$KIB_STATE_ROOT")
    for d in "${set[@]}"; do mkdir -p "$d"; done
    # shellcheck disable=SC2016 # the VM's shell expands them
    vm_root sh -c 'u=$1 g=$2 && shift 2
        command -v bindfs >/dev/null || apt-get install -y -q bindfs || exit 1
        ulimit -n 1048576 || ulimit -n "$(ulimit -Hn)"
        for d; do
            grep -q " $d fuse" /proc/self/mounts \
                || bindfs --multithreaded -o allow_other -u "$u" -g "$g" --chown-ignore \
                    --chgrp-ignore "$d" "$d" \
                || exit 1
        done' _ "$(id -u)" "$(id -g)" "${set[@]}" >"$log" 2>&1 || {
        tail -n 20 "$log" >&2
        die "could not give the VM your file owners (bindfs; full log: $log)."
    }
}

_vm_booted() { _vm_zram && _vm_classic_store; } # nothing runs in it yet

# Compressed swap in the VM's own RAM, each boot: a spike slows a box instead of the kernel
# killing it. gVisor holds box memory as shmem, which nothing else can move out. Best effort.
_vm_zram() {
    # shellcheck disable=SC2016 # the VM's shell expands them
    vm_root sh -c 'grep -q zram /proc/swaps && exit; m=$(grep MemTotal /proc/meminfo | tr -dc 0-9)
        modprobe zram && d=$(zramctl -f -a zstd -s $((m / 2))K) && mkswap "$d" && swapon "$d"' \
        >>"$KIB_STATE_ROOT/vm.log" 2>&1 || true
}

# Docker's classic storage, set once: containerd's keeps a compressed copy of every image (+3 GB)
# and cannot read an image's inline build cache, which fast rebuilds rely on (microvm.md).
_vm_classic_store() {
    local log="$KIB_STATE_ROOT/vm.log" py='import json, os, sys
p = "/etc/docker/daemon.json"
d = json.load(open(p)) if os.path.exists(p) else {}
if d.get("features", {}).get("containerd-snapshotter") is False: sys.exit(1)
if sys.argv[1] == "set":
    d.setdefault("features", {})["containerd-snapshotter"] = False
    json.dump(d, open(p, "w"), indent=2)'
    vm_root python3 -c "$py" check >>"$log" 2>&1 || return 0
    echo "🛡️  kib: moving the VM's Docker to its classic storage (one time); the image rebuilds once." >&2
    # Pruned first: the switch hides containerd's images, which would then hold their disk forever.
    # shellcheck disable=SC2016 # the VM's shell expands them
    vm_root sh -c 'docker system prune -af && python3 -c "$1" set && systemctl restart docker' \
        _ "$py" >>"$log" 2>&1 || die "could not move the VM's Docker to classic storage (log: $log)."
}

# gVisor into the VM once per pin: the release tarball (runsc needs its gvisor-bin/ beside it),
# checked against the sha512 pinned here, then registered with Docker.
_vm_gvisor() {
    local sha log="$KIB_STATE_ROOT/vm.log"
    ! _vm_has_gvisor || return 0
    sha="$(_gvisor_sha)"
    echo "🛡️  kib: installing gVisor $GVISOR_VERSION into its VM (one time)…" >&2
    # The VM has no bzip2; python3 unpacks it. No && chains: set -e stops at the first failure.
    # shellcheck disable=SC2016 # the VM's shell expands them
    vm_root sh -c 'set -e
        d=/opt/kib-gvisor/$1
        rm -rf "$d" && mkdir -p "$d" && cd "$d"
        curl -fsSLO "https://storage.googleapis.com/gvisor/releases/release/$1/$(uname -m)/gvisor.tar.bz2"
        echo "$2  gvisor.tar.bz2" | sha512sum -c --quiet
        python3 -c "import tarfile; tarfile.open(\"gvisor.tar.bz2\").extractall(filter=\"data\")"
        rm gvisor.tar.bz2
        ./runsc install --runtime="$3" -- --oci-seccomp
        systemctl reload docker' _ "$GVISOR_VERSION" "$sha" "$GVISOR_RUNTIME" >"$log" 2>&1 || {
        tail -n 20 "$log" >&2
        die "could not install gVisor into the VM (full log: $log)."
    }
    wait_until 50 0.2 _vm_has_gvisor \
        || die "Docker in the VM never listed gVisor (runtime $GVISOR_RUNTIME)."
}
_gvisor_sha() {
    case "$(uname -m)" in
        x86_64) echo 2e6671bb2d033b871c5811ab57e16ac570988b0e0054c525f911cfaf191bab3ca4efb08e0a98daa4b9e7d248f9e5776ef2ef2f8a6b82d829646a42924c98bb05 ;;
        arm64 | aarch64) echo 574b5775b4417618f63c8506e6bb237e370df85722832a5d0c3831382155e55e59d4cfa993a1e9bbe1b1cf04346ffd48b20aaa879c6ed9a52c680f762fd19980 ;;
        *) die "no gVisor build for $(uname -m)." ;;
    esac
}
_vm_has_gvisor() {
    docker info --format '{{range $k, $v := .Runtimes}}{{$k}} {{end}}' 2>/dev/null \
        | grep -qw -- "$GVISOR_RUNTIME"
}

# Pinned, not read off a release: a SHA256SUMS beside the tarball vouches for nothing. Docker
# publishes none for its static CLI; those were hashed at the pin.
_tool() { # <command> → "<sha256> <url> <dir under ~> [tar members…]"; nothing if no build
    local lima="https://github.com/lima-vm/lima/releases/download/v$LIMA_VERSION/lima-$LIMA_VERSION"
    local dk="https://download.docker.com"
    local bx="https://github.com/docker/buildx/releases/download/$BUILDX_VERSION/buildx-$BUILDX_VERSION"
    local p=".local/docker/cli-plugins docker-buildx"
    case "$1 $KIB_OS-$(uname -m)" in
        "limactl linux-x86_64") echo "b391ac7fcac2b2a5a1628107756463188ded4d18d3104a40a66a8bb6fec01bcb $lima-Linux-x86_64.tar.gz .local" ;;
        "limactl linux-aarch64") echo "fbcf4d127936666aa2cf6013b663c250431f2a59394757b404070f8d6a160e10 $lima-Linux-aarch64.tar.gz .local" ;;
        "limactl darwin-x86_64") echo "6b776e4bc41f358e6ee01fefcc78e2eb26f11635a0fcff632234af77a566c6c4 $lima-Darwin-x86_64.tar.gz .local" ;;
        "limactl darwin-arm64") echo "9e9eacce88f37e185c346bad73aa6136f738d8cdf8c3bb23cd42b071824bc66e $lima-Darwin-arm64.tar.gz .local" ;;
        "docker linux-x86_64") echo "3fb5d1f13014c18cc54945bc177c58a9056a482dada031e17d12cf2e6922c973 $dk/linux/static/stable/x86_64/docker-$DOCKER_VERSION.tgz .local docker/docker" ;;
        "docker linux-aarch64") echo "1b27fd739378ef938401e81ce5afb73b7ad7432d4f598814a9ff5f826bb464d2 $dk/linux/static/stable/aarch64/docker-$DOCKER_VERSION.tgz .local docker/docker" ;;
        "docker darwin-x86_64") echo "f7d8f835391cd0a8c676d9a8d2547f909da6a2d029595943b0ce8d5f169abe47 $dk/mac/static/stable/x86_64/docker-$DOCKER_VERSION.tgz .local docker/docker" ;;
        "docker darwin-arm64") echo "79145e169bca0b9571d02de8e1cd311a36e0e8fdb4599b6661a87b1bb3afbe13 $dk/mac/static/stable/aarch64/docker-$DOCKER_VERSION.tgz .local docker/docker" ;;
        "buildx linux-x86_64") echo "7992ec09413b80ff57ba4e081f56fc833d7bac1d5e71143c6c809e7e6065f6d6 $bx.linux-amd64 $p" ;;
        "buildx linux-aarch64") echo "46c0f334772de3cb0b341cc415caf7339fb5cfc8b8438ebcb5a10e7f23800d36 $bx.linux-arm64 $p" ;;
        "buildx darwin-x86_64") echo "ad2418546e6d168a3e3b59fdf2a24997bc84263abeb4a5d9d0422cfe782743fc $bx.darwin-amd64 $p" ;;
        "buildx darwin-arm64") echo "81702e18713cfd495bfe594943fa57f470eda16c0653ae3de15cd411df273c41 $bx.darwin-arm64 $p" ;;
    esac
}

# What the VM lacks, installed after one prompt. 1 = still missing: declined, or not possible.
_vm_tools() {
    local t miss=""
    for t in limactl docker; do
        command -v "$t" >/dev/null 2>&1 || miss="$miss $t"
    done
    # Without buildx, docker falls back to its legacy builder: every line, and no BuildKit cache.
    docker buildx version >/dev/null 2>&1 || miss="$miss buildx"
    [ -z "$miss" ] || { [ -t 0 ] && _vm_install "$miss"; }
}

_vm_install() { # <commands>
    local t a list=""
    for t in $1; do
        [ -n "$(_tool "$t")" ] || return 1
        case "$t" in
            limactl) t=Lima ;;
            docker) t="the docker command (not Docker Desktop)" ;;
            buildx) t="docker buildx" ;;
        esac
        list="$list${list:+, }$t"
    done
    printf '🛡️  kib runs every box in a Lima VM, so a kernel exploit stays in it.\n' >&2
    printf '   Install %s into ~/.local? [Y/n] ' "$list" >&2
    read -r a || true
    case "$a" in [nN]*) return 1 ;; esac
    # shellcheck disable=SC2046 # _tool's fields
    for t in $1; do _install $(_tool "$t"); done
}

_install() { # <sha256> <url> <dir under ~> [tar members…, or the name of a bare binary]
    local tmp
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/t.tgz" "$2" || die "could not download $2 (curl, above)."
    [ "$(sha256_file "$tmp/t.tgz")" = "$1" ] || die "$2 failed its checksum."
    # Via tmp, and cp not tar into place: a tarball's ./ would rewrite the target dir's mode.
    {
        mkdir -p "$tmp/x" "$HOME/$3" && case "$2" in
            *gz) tar -xzf "$tmp/t.tgz" -C "$tmp/x" "${@:4}" ;;
            *) mv "$tmp/t.tgz" "$tmp/x/$4" && chmod +x "$tmp/x/$4" ;;
        esac && cp -R "$tmp/x/." "$HOME/$3/"
    } || die "could not install into ~/$3."
    rm -rf "$tmp"
}

# The box's resolv.conf: the VM's own resolvers. Under gVisor Docker's embedded DNS
# (127.0.0.11) is unreachable, so the broker is a host entry instead (add_broker_env_args).
vm_resolv() { # <file>
    _in_engine grep '^nameserver' /run/systemd/resolve/resolv.conf >"$1" 2>/dev/null || true
    [ -s "$1" ] || die "could not read the engine's DNS servers (/run/systemd/resolve/resolv.conf)."
    chmod 644 "$1"
}

# A project's redacted view, mounted by VM root from the host's loopback (Lima's address for it).
# sync: a refused write fails the write(2), not a later flush whose error gVisor may drop. soft: a
# dead view errors in the box instead of hanging it. actimeo=1: an edit is seen at the next open
# anyway (close-to-open), a stat-only watcher within a second. nolock: locks stay in the VM,
# which serves one box per project. nfs-common once, like bindfs. Boxes reach the host's loopback
# too, so a raw PREROUTING drop keeps every box off the view's port (go-xdr allocates a declared
# length before reading it); VM root's own traffic never passes PREROUTING.
VIEW_NFS_OPTS="vers=3,proto=tcp,mountproto=tcp,nolock,sync,actimeo=1,soft,timeo=10,retrans=2"
vm_view_mount() { # <mountpoint> <port> <secret>
    # shellcheck disable=SC2016 # the VM's shell expands them
    vm_root sh -c 'i="apt-get install -y -q nfs-common"
        command -v mount.nfs >/dev/null || $i || { apt-get update -q && $i; } || exit 1
        umount -l "$1" 2>/dev/null
        iptables -t raw -I PREROUTING -d "$4" -p tcp --dport "$3" -j DROP || exit 1
        mkdir -p "$1" && mount -t nfs -o "$2,port=$3,mountport=$3" "$4:/$5" "$1"' \
        _ "$1" "$VIEW_NFS_OPTS" "$2" "$LIMA_HOST_IP" "$3" >>"$KIB_STATE_ROOT/vm.log" 2>&1
}
vm_view_unmount() { # <mountpoint>: the VM's NFS mount, or rootless's FUSE one
    # shellcheck disable=SC2016 # the engine's shell expands it
    _in_engine sh -c 'p=$(sed -n "s|^[^ ]* $1 nfs [^ ]*,port=\([0-9]*\).*|\1|p" /proc/mounts)
        [ -z "$p" ] || iptables -t raw -D PREROUTING -d "$2" -p tcp --dport "$p" -j DROP
        umount -l "$1" 2>/dev/null || fusermount3 -u -z "$1" 2>/dev/null
        rmdir "$1" 2>/dev/null; true' _ "$1" "$LIMA_HOST_IP" >/dev/null 2>&1 || true
}
vm_view_has() { # <mountpoint> <./a/b…>: those whose parent the view shows, without the ./
    # shellcheck disable=SC2016 # the engine's shell expands them
    _in_engine sh -c 'm=$1 && shift; for d; do [ -d "$m/${d%/*}" ] && printf "%s\n" "${d#./}"; done; true' \
        _ "$@" 2>/dev/null
}

# Runs a command where the engine's mounts are: as VM root, or here under rootless.
_in_engine() { if engine_lima; then vm_root "$@"; else "$@"; fi; }

# ── No-VM mode (Linux, `engine = rootless`) ─────────────────────
# The box runs on gVisor under the user's rootless Docker, as root inside, which is this user
# outside. One barrier, not two: a gVisor bug alone reaches the host, as this user. And runsc
# runs with --ignore-cgroups, rootless Docker's only way to run it, so boxes have no memory or
# CPU limits. The view is a host FUSE mount, since rootless Docker cannot mount NFS.
# (PLAN_NFS_VIEW.md Tests 11–12)
GVISOR_HOST_DIR="$KIB_HOST_ONLY/gvisor/$GVISOR_VERSION"
rootless_use() {
    is_macos && die "engine = rootless is Linux only: a Mac needs kib's VM."
    docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless \
        || die "engine = rootless needs rootless Docker running (docs/vm.md, \"No-VM mode\")."
    _KIB_ROOTLESS=1
    KIB_HOST_GATEWAY=10.0.2.2 # RootlessKit's host loopback; Docker 29 writes `invalid IP` for host-gateway
    _vm_has_gvisor || _rootless_gvisor
}

# gVisor into rootless Docker once per pin, after one prompt: it edits the user's Docker config.
# HUP to dockerd alone; signalling the whole user unit takes containerd down with it.
_rootless_gvisor() {
    local a pid cfg="$HOME/.config/docker/daemon.json" tgz="$GVISOR_HOST_DIR/gvisor.tar.bz2"
    printf '🛡️  kib: no-VM mode adds gVisor (%s) to %s and reloads Docker. Go ahead? [y/N] ' \
        "$GVISOR_RUNTIME" "$cfg" >&2
    { [ -t 0 ] && read -r a; } || true
    case "$a" in [yY]*) ;; *) die "gVisor is not set up for rootless Docker." ;; esac
    mkdir -p "$GVISOR_HOST_DIR" "${cfg%/*}"
    if ! curl -fsSL -o "$tgz" "https://storage.googleapis.com/gvisor/releases/release/$GVISOR_VERSION/$(uname -m)/gvisor.tar.bz2" \
        || [ "$(sha512_file "$tgz")" != "$(_gvisor_sha)" ] || ! tar -xjf "$tgz" -C "$GVISOR_HOST_DIR" \
        || ! "$GVISOR_HOST_DIR/runsc" install --config_file="$cfg" --runtime="$GVISOR_RUNTIME" \
            -- --oci-seccomp --ignore-cgroups >/dev/null; then
        die "could not install gVisor $GVISOR_VERSION for rootless Docker."
    fi
    rm -f "$tgz"
    pid="$(pgrep -u "$(id -u)" -x dockerd)" || die "no rootless dockerd to reload; restart it, then retry."
    kill -HUP "$pid"
    wait_until 50 0.2 _vm_has_gvisor || die "rootless Docker never listed gVisor ($GVISOR_RUNTIME)."
}

# Last kib out leaves the VM up for VM_LINGER, so a quick reopen skips the boot. Only the newest
# close's timer may stop it, and only while no session holds fd 205. A kib starting meanwhile
# waits on its shared acquire, then restarts it.
VM_LINGER=600

vm_down() {
    engine_lima || return 0
    _vm_oom
    exec 205>&-
    exec 205>"$VM_LOCK"
    if lock_fd -n -x 205; then
        # shellcheck disable=SC2016 # the detached shell's own $1, $2
        detach_pgrp bash -c '. "$1/host/core.sh" && . "$1/host/portable.sh" && . "$1/host/vm.sh" \
            && sleep "$2" && _vm_linger_end' _ "$KIB_ROOT" "$VM_LINGER" \
            >/dev/null 2>&1 200>&- 201>&- 202>&- 205>&- 206>&-
        echo "$!" >"$VM_LOCK.linger" # the timer's own pid: unique, and the newest wins
        echo "🛡️  kib: last session closed — the VM stops in $((VM_LINGER / 60)) min unless one opens." >&2
    fi
    exec 205>&-
}

_vm_linger_end() {
    [ "$(cat "$VM_LOCK.linger" 2>/dev/null)" = "$$" ] || return 0 # a later close took over
    exec 205>"$VM_LOCK"
    lock_fd -n -x 205 || return 0
    # Docker updates only here: its restart cuts every `docker exec`, so every session, even
    # with live-restore (measured). Time-boxed: a launch waits on this lock for 120 s at most.
    # shellcheck disable=SC2016 # the VM's shell expands them
    vm_root sh -c 'p="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
        a="-y -qq --only-upgrade -o Dpkg::Options::=--force-confold"
        export DEBIAN_FRONTEND=noninteractive
        timeout 45 apt-get update -qq && timeout 45 apt-get install $a --download-only $p \
            && apt-get install $a --no-download $p' >/dev/null 2>&1 || true
    # The trim catches what the last cleanup's lazy frees left.
    vm_root sh -c 'apt-get clean; journalctl -q --vacuum-size=100M; fstrim -a' \
        >/dev/null 2>&1 || true
    limactl stop "$KIB_VM_NAME" >/dev/null 2>&1 || true
}

# Lima's 4 GiB until the VM's kernel kills for memory, then double from its next boot, up to
# half the host's RAM. Not a bigger default: the VM keeps what it used until it stops.
_vm_oom() {
    local cur want max
    [ ! -e "$VM_GROW" ] || return 0 # already said, this boot
    vm_root grep -q '^oom_kill [1-9]' /proc/vmstat 2>/dev/null || return 0
    cur="$(limactl list --format '{{.Memory}}' "$KIB_VM_NAME" 2>/dev/null)"
    max="$(host_mem_kib)"
    [ "$cur" -gt 0 ] 2>/dev/null && [ "$max" -gt 0 ] 2>/dev/null || return 0
    cur=$((cur >> 30)) want=$((cur * 2)) max=$((max >> 21))
    [ "$want" -le "$max" ] || want=$max
    [ "$want" -ge "$cur" ] || want=$cur # never shrink a size set by hand
    echo "$want" >"$VM_GROW"
    notify_desktop normal "kib: the VM ran out of memory" "It had $cur GiB and stopped its biggest process, usually a whole project's box."
    if [ "$want" -gt "$cur" ]; then
        warn "the VM ran out of memory ($cur GiB) and stopped its biggest process," \
            "usually a whole project's box, with every session in it." \
            "It gets $want GiB from its next start. To restart it now, close every session, then:" \
            "  limactl stop $KIB_VM_NAME" \
            "For up to $max GiB, half your RAM:" \
            "  limactl stop $KIB_VM_NAME && limactl edit $KIB_VM_NAME --memory $max"
    else
        warn "the VM ran out of memory ($cur GiB, kib's most: half your RAM) and stopped its biggest process."
    fi
}

# ── Disk cleanup ────────────────────────────────────────────────
# Once a day, at a project's last exit: what only grows otherwise. A project's volumes go once it
# has been closed for `cleanup_days`; Docker refuses one in use, so an open project keeps its own.
KIB_USED="$KIB_STATE_ROOT/.used" # one stamp per project, touched at each last exit
DISK_CLEANED="$KIB_STATE_ROOT/disk-cleanup"

disk_cleanup() {
    mkdir -p "$KIB_USED" && touch "$KIB_USED/$CNAME"
    [ -z "$(find "$DISK_CLEANED" -mmin -1440 2>/dev/null)" ] || return 0
    touch "$DISK_CLEANED"
    echo "🧹 kib: daily disk cleanup" >&2
    # until=: a box between create and start reads as stopped.
    ! engine_lima || _disk_step "stopped containers" container prune -f --filter until=1h
    _disk_step "old kib images" image prune -f --filter label=keep-it-in-your-box
    # The VM's Docker is kib's alone: an unused base image (golang) just re-pulls when needed.
    ! engine_lima || _disk_step "other images" image prune -af --filter label!=keep-it-in-your-box
    # The image carries its own cache (tools/build-image.sh), so this one may go whole.
    ! engine_lima || _disk_step "build cache" builder prune -af
    _disk_projects
    engine_lima || return 0
    # Docker frees pruned layers lazily, so this trim misses some; the idle stop trims again.
    vm_root fstrim -a >/dev/null 2>&1 || true
    printf '   %-20s%s (drops a bit more when the VM stops)\n' "VM disk" "$(_vm_disk_size)" >&2
}
_disk_step() { # <label> <docker args…>: runs it, says what it freed
    local out
    printf '   %-20s' "$1" >&2
    shift
    out="$(docker "$@" 2>&1 | grep '^Total' | grep -oE '[0-9.]+[kMGT]?B' | tail -n 1)"
    echo "${out:-0B} freed" >&2
}
_disk_projects() { # every project closed longer than cleanup_days loses its volumes
    local vols projects p gone=""
    [ "$KIB_CFG_CLEANUP_DAYS" -gt 0 ] 2>/dev/null || return 0
    vols="$(docker volume ls -q 2>/dev/null)"
    projects="$(printf '%s\n' "$vols" | sed -nE 's/^(kib-.*)-(cache|src|local-[0-9a-f]{8})$/\1/p')"
    for p in $(printf '%s\n' "$projects" | sort -u); do
        [ -e "$KIB_USED/$p" ] || touch "$KIB_USED/$p" # first seen: its clock starts now
        [ -n "$(find "$KIB_USED/$p" -mtime +"$KIB_CFG_CLEANUP_DAYS")" ] || continue
        # shellcheck disable=SC2046 # one volume name per word
        docker volume rm $(printf '%s\n' "$vols" | grep "^$p-") >/dev/null 2>&1 \
            && gone="${gone:+$gone, }$(printf '%s' "$p" | sed 's/^kib-//; s/-[0-9a-f]\{8\}$//')"
        rm -f "$KIB_USED/$p" # an open one is stamped again at its own exit
    done
    printf '   %-20s%s (closed over %s days)\n' "unused projects" "${gone:-none}" \
        "$KIB_CFG_CLEANUP_DAYS" >&2
}
_vm_disk_size() {
    du -k "$(limactl list --format '{{.Dir}}' "$KIB_VM_NAME" 2>/dev/null)/disk" 2>/dev/null \
        | awk '{ printf "%.1f GB", $1 / 1048576 }'
}

vm_use() { # <verb>
    if [ "$KIB_CFG_ENGINE" = rootless ]; then
        rootless_use
        return 0
    fi
    PATH="$PATH:$HOME/.local/bin:$HOME/.local/docker" # where _vm_tools installs
    # kib's docker config, plugins beside it. Not ~/.docker: Docker Desktop's `credsStore: desktop`
    # there fails every pull once it is gone.
    export DOCKER_CONFIG="$HOME/.local/docker"
    lima_host_ready || die "kib runs every box in a Lima VM, which needs QEMU, KVM and virtiofsd" \
        "here. Set them up once: $KIB_ROOT/docs/vm.md"
    _vm_tools || die "kib runs every box in a Lima VM." \
        "Run kib in a terminal and answer Y to install it (no sudo, nothing else changes)."
    # A session's cleanup calls vm_down; any other verb arms the stop timer at its own exit.
    case "$1" in claude | exec) ;; *) trap vm_down EXIT ;; esac
    vm_up
}
