#!/usr/bin/env bash
# Docker runs in a Lima VM and the box runs on gVisor inside it, while kib stays on the host: a
# kernel exploit needs a gVisor bug, then a VM kernel bug (docs/vm.md). Same ~/.claude, login and
# broker either way: kib itself never moves. The VM mounts ~ once, so it never restarts for a
# project.
#
# Reads:  KIB_CONFIG KIB_STATE_ROOT KIB_ROOT HOME LIMA_VM_TYPE LIMA_MOUNT_TYPE KIB_NODE_CACHE
# Writes: DOCKER_HOST DOCKER_CONFIG (exported) _KIB_ENGINE_VM KIB_HOST_GATEWAY VM_MOUNTS PATH
#         GVISOR_RUNTIME
# shellcheck disable=SC2034

KIB_VM_NAME="kib-vm"
VM_LOCK="$KIB_STATE_ROOT/.locks/vm.lock"
VM_SPEC="$KIB_STATE_ROOT/vm-spec" # the mount set the VM was last booted with
# ponytail: Lima's user-mode network address; read it from the VM if a network differs.
LIMA_HOST_IP=192.168.5.2

LIMA_VERSION=2.2.1
DOCKER_VERSION=29.9.3
BUILDX_VERSION=v0.38.2
GVISOR_VERSION=20261102.0
# Versioned, so a pin bump installs beside the old one and no running box loses its runtime.
GVISOR_RUNTIME="kib-gvisor-$GVISOR_VERSION"

# ~ at its own path, and any of kib's own dirs that live outside it. Not per project: a mount
# change restarts the VM. Projects outside ~ are refused (vm_project_ok).
_vm_mounts() {
    local p
    VM_MOUNTS=(--mount-only "$HOME:w")
    for p in "$KIB_ROOT" "$KIB_STATE_ROOT:w" "$KIB_NODE_CACHE:w"; do
        case "${p%:w}/" in "$HOME"/*) ;; *) VM_MOUNTS+=(--mount-only "$p") ;; esac
    done
}

vm_project_ok() {
    case "$PWD/" in "$HOME"/?*) return 0 ;; esac
    die "kib opens projects under your home folder only, the one folder its VM mounts:" \
        "  $PWD is outside $HOME."
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
    local status want m
    mkdir -p "$KIB_STATE_ROOT/.locks"
    exec 205>"$VM_LOCK"
    lock_fd -w 120 -s 205 || die "timed out waiting for the VM to stop ($VM_LOCK)."
    exec 206>"$VM_LOCK.boot"
    lock_fd -x 206
    _vm_mounts
    for m in "${VM_MOUNTS[@]}"; do
        case "$m" in --*) ;; *) mkdir -p "${m%:w}" ;; esac
    done
    want="$LIMA_MOUNT_TYPE ${VM_MOUNTS[*]}"
    status="$(limactl list --format '{{.Status}}' "$KIB_VM_NAME" 2>/dev/null || true)"
    if [ -z "$status" ]; then
        _limactl "creating its VM — one time, a few minutes" start --name "$KIB_VM_NAME" \
            --vm-type="$LIMA_VM_TYPE" --mount-type="$LIMA_MOUNT_TYPE" \
            "${VM_MOUNTS[@]}" template:docker-rootful
        printf '%s\n' "$want" >"$VM_SPEC"
        status=Running
    elif [ "$want" != "$(cat "$VM_SPEC" 2>/dev/null)" ]; then
        # A kib upgrade changed the mount set. Never cut a session, never bind what isn't mounted.
        lock_fd -n -x 205 || die "this kib changed the VM's mounts, and other kib sessions use it." \
            "Close them once; the next launch updates the VM (one restart)."
        limactl stop "$KIB_VM_NAME" >/dev/null 2>&1 || true
        # Not `edit --start`: an edit that changes nothing never starts the VM.
        _limactl "updating its VM's mounts" edit \
            --mount-type="$LIMA_MOUNT_TYPE" "${VM_MOUNTS[@]}" "$KIB_VM_NAME"
        printf '%s\n' "$want" >"$VM_SPEC"
        lock_fd -s 205
        status=Stopped
    fi
    [ "$status" = Running ] || _limactl "starting its VM" start "$KIB_VM_NAME"
    unset DOCKER_CONTEXT
    DOCKER_HOST="unix://$(limactl list --format '{{.Dir}}' "$KIB_VM_NAME")/sock/docker.sock"
    export DOCKER_HOST
    _KIB_ENGINE_VM=1
    KIB_HOST_GATEWAY="$LIMA_HOST_IP"
    _vm_owners
    _vm_gvisor
    lock_fd -u 206
    exec 206>&-
}

# Apple's virtiofs reports a file as owned by whoever asks, so gVisor (root) sees kib's private
# dirs as root's and the box user is locked out. bindfs over each reports the host user instead.
# Never over a project, kib's checkout included: under the redaction sidecar it hung `docker run`.
# --multithreaded: single-threaded, bindfs hung on the first stat of a transcript (measured).
_vm_owners() {
    is_macos || return 0
    local log="$KIB_STATE_ROOT/vm.log" d set=("$HOME/.claude" "$KIB_STATE_ROOT")
    for d in "${set[@]}"; do mkdir -p "$d"; done
    # shellcheck disable=SC2016 # the VM's shell expands them
    vm_root sh -c 'u=$1 g=$2 && shift 2
        command -v bindfs >/dev/null || apt-get install -y -q bindfs || exit 1
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

# gVisor into the VM once per pin: the release tarball (runsc needs its gvisor-bin/ beside it),
# checked against the sha512 pinned here, then registered with Docker.
_vm_gvisor() {
    local sha log="$KIB_STATE_ROOT/vm.log"
    ! _vm_has_gvisor || return 0
    case "$(uname -m)" in
        x86_64) sha=2e6671bb2d033b871c5811ab57e16ac570988b0e0054c525f911cfaf191bab3ca4efb08e0a98daa4b9e7d248f9e5776ef2ef2f8a6b82d829646a42924c98bb05 ;;
        arm64 | aarch64) sha=574b5775b4417618f63c8506e6bb237e370df85722832a5d0c3831382155e55e59d4cfa993a1e9bbe1b1cf04346ffd48b20aaa879c6ed9a52c680f762fd19980 ;;
        *) die "no gVisor build for $(uname -m)." ;;
    esac
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
    vm_root grep '^nameserver' /run/systemd/resolve/resolv.conf >"$1" 2>/dev/null || true
    [ -s "$1" ] || die "could not read the VM's DNS servers."
    chmod 644 "$1"
}

# Last kib out leaves the VM up for VM_LINGER, so a quick reopen skips the boot. Only the newest
# close's timer may stop it, and only while no session holds fd 205. A kib starting meanwhile
# waits on its shared acquire, then restarts it.
VM_LINGER=600

vm_down() {
    engine_lima || return 0
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
    limactl stop "$KIB_VM_NAME" >/dev/null 2>&1 || true
}

# <verb>: claude and exec open a project, which must be one the VM can see.
vm_use() {
    PATH="$PATH:$HOME/.local/bin:$HOME/.local/docker" # where _vm_tools installs
    # kib's docker config, plugins beside it. Not ~/.docker: Docker Desktop's `credsStore: desktop`
    # there fails every pull once it is gone.
    export DOCKER_CONFIG="$HOME/.local/docker"
    lima_host_ready || die "kib runs every box in a Lima VM, which needs QEMU, KVM and virtiofsd" \
        "here. Set them up once: $KIB_ROOT/docs/vm.md"
    _vm_tools || die "kib runs every box in a Lima VM." \
        "Run kib in a terminal and answer Y to install it (no sudo, nothing else changes)."
    # A session's cleanup calls vm_down; any other verb arms the stop timer at its own exit.
    case "$1" in claude | exec) vm_project_ok ;; *) trap vm_down EXIT ;; esac
    vm_up
}
