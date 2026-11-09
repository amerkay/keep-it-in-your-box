#!/usr/bin/env bash
# Docker runs in a Lima VM and the box runs on gVisor inside it, while kib stays on the host: a
# kernel exploit needs a gVisor bug, then a VM kernel bug (docs/vm.md). Same ~/.claude, login and
# broker either way: kib itself never moves. The VM shares kib's own dirs and the folders projects
# opened, never ~ itself; a new one restarts it, and every session cut resumes on its own.
#
# Reads:  KIB_CONFIG KIB_STATE_ROOT KIB_ROOT HOME LIMA_VM_TYPE LIMA_MOUNT_TYPE KIB_NODE_CACHE
#         STATE_DIR, and at a session's exit VERB CMD SLEEP_STATE SESSION_TAG EPHEMERAL
# Writes: DOCKER_HOST DOCKER_CONFIG (exported) _KIB_ENGINE_VM KIB_HOST_GATEWAY VM_MOUNTS VM_WANT
#         VM_NEW_ROOT _VM_RESUME RESUME_ARGS PATH GVISOR_RUNTIME
# shellcheck disable=SC2034

KIB_VM_NAME="kib-vm"
VM_LOCK="$KIB_STATE_ROOT/.locks/vm.lock"
VM_SPEC="$KIB_STATE_ROOT/vm-spec"       # the mount set the VM was last booted with
VM_GROW="$KIB_STATE_ROOT/vm-memory"     # GiB for its next boot, after an out-of-memory kill
VM_ROOTS="$KIB_STATE_ROOT/vm-roots"     # the projects it shares, one per line
VM_RESTART="$KIB_STATE_ROOT/vm-restart" # the pid of a kib restarting it under open sessions
VM_EVICT_WAIT=120                       # seconds those sessions get to close
# ponytail: Lima's user-mode network address; read it from the VM if a network differs.
LIMA_HOST_IP=192.168.5.2

LIMA_VERSION=2.2.1
DOCKER_VERSION=29.9.3
BUILDX_VERSION=v0.38.2
GVISOR_VERSION=20261102.0
# Versioned, so a pin bump installs beside the old one and no running box loses its runtime.
GVISOR_RUNTIME="kib-gvisor-$GVISOR_VERSION"

# ~/.claude, the projects opened, then kib's own dirs, each at its own path; never ~ itself, so
# ~/.ssh, ~/.aws and the rest stay out of the VM. A dir inside one already listed shares its mount.
_vm_mounts() {
    local p
    VM_MOUNTS=(--mount-only "$HOME/.claude:w")
    while IFS= read -r p; do _vm_mount "$p:w"; done < <(_vm_roots)
    for p in "$KIB_STATE_ROOT:w" "$KIB_NODE_CACHE:w" "$KIB_ROOT"; do _vm_mount "$p"; done
    VM_WANT="$LIMA_MOUNT_TYPE ${VM_MOUNTS[*]}"
}
_vm_mount() { # <dir[:w]>
    _vm_under "${1%:w}" "${VM_MOUNTS[@]}" || VM_MOUNTS+=(--mount-only "$1")
}
_vm_roots() { # sorted, so a folder comes before any inside it
    {
        cat "$VM_ROOTS" 2>/dev/null || true
        [ -z "${VM_NEW_ROOT:-}" ] || echo "$VM_NEW_ROOT"
    } | LC_ALL=C sort -u
}
_vm_under() { # <path> <dir[:w]…>: the path is one of the dirs, or inside one
    local p="$1/" d
    shift
    for d; do case "$p" in "${d%:w}"/*) return 0 ;; esac done
    return 1
}

# A project not yet shared joins the list. Never ~ or above it, which would share ~/.ssh again.
vm_project_ok() {
    local r
    while IFS= read -r r; do _vm_under "$PWD" "$r" && return 0; done < <(_vm_roots)
    VM_NEW_ROOT="$(_vm_root_of "$PWD")"
    if _vm_private "$VM_NEW_ROOT"; then
        die "kib won't share $VM_NEW_ROOT with its VM: your home folder is in it."
    fi
}
_vm_root_of() { # <dir>: its whole repo, which the launch's git audit reads
    local d
    d="$(_git_toplevel "$1")"
    ! _vm_private "$d" || d=$1
    echo "$d"
}
_vm_private() { [ -z "$1" ] || _vm_under "$HOME" "$1"; } # none (/), ~, or a folder holding ~

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
# count as the project lock. Boot (fd 206) serialises create, start, re-mount and gVisor, and
# comes first: a kib waiting out another's restart must hold no share of 205.
vm_up() {
    local status
    mkdir -p "$KIB_STATE_ROOT/.locks"
    exec 206>"$VM_LOCK.boot"
    lock_fd -x 206
    exec 205>"$VM_LOCK"
    lock_fd -w 120 -s 205 || die "timed out waiting for the VM to stop ($VM_LOCK)."
    _vm_mounts
    _vm_mkdirs
    status="$(limactl list --format '{{.Status}}' "$KIB_VM_NAME" 2>/dev/null || true)"
    if [ -z "$status" ]; then
        _limactl "creating its VM — one time, a few minutes" start --name "$KIB_VM_NAME" \
            --vm-type="$LIMA_VM_TYPE" --mount-type="$LIMA_MOUNT_TYPE" \
            "${VM_MOUNTS[@]}" template:docker-rootful
        _vm_save
        _vm_zram
        status=Running
    elif [ "$VM_WANT" != "$(cat "$VM_SPEC" 2>/dev/null)" ]; then
        # A new project folder or a kib upgrade. Never bind what isn't mounted.
        lock_fd -n -x 205 || { _vm_evict && _vm_mounts; }
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
    [ "$status" = Running ] || { _limactl "starting its VM" start "$KIB_VM_NAME" && _vm_zram; }
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
_vm_save() { # the mount set the VM now has
    printf '%s\n' "$VM_WANT" >"$VM_SPEC"
    _vm_roots >"$VM_ROOTS.tmp" && mv "$VM_ROOTS.tmp" "$VM_ROOTS"
}

# Restarting the VM ends every session in it, so ask first if one is mid-work. Each running box's
# project stays shared, and each session cut comes back with --resume (vm_down, vm_resume).
_vm_evict() {
    local v n=0 busy=0 a="" ids
    for v in $(kib_sessions "$STATE_DIR"); do
        n=$((n + 1))
        [ "$v" = idle ] || busy=$((busy + 1))
    done
    if [ "$busy" -gt 0 ]; then
        printf '🛡️  kib: sharing a new project restarts the VM, and %s of its sessions are mid-work.\n' \
            "$busy" >&2
        printf '   They stop, then resume where they left off. Restart now? [y/N] ' >&2
        { [ -t 0 ] && read -r a; } || true
        case "$a" in [yY]*) ;; *) die "left the VM as it is: open this project again once they finish." ;; esac
    elif [ "$n" -gt 0 ]; then
        echo "🛡️  kib: restarting the VM to share a new project; its $n idle session(s) resume after." >&2
    fi
    echo "$$" >"$VM_RESTART"
    _vm_docker
    ids="$(docker ps -q 2>/dev/null || true)"
    if [ -n "$ids" ]; then
        # The FUSE sidecar binds its project at /src (host/redaction.sh).
        # shellcheck disable=SC2086 # one id per word
        docker inspect --format '{{range .Mounts}}{{if eq .Destination "/src"}}{{.Source}}{{end}}{{end}}' \
            $ids 2>/dev/null | while IFS= read -r v; do [ -z "$v" ] || _vm_root_of "$v"; done >>"$VM_ROOTS"
        # shellcheck disable=SC2086
        docker stop $ids >/dev/null 2>&1 || true
    fi
    lock_fd -w "$VM_EVICT_WAIT" -x 205 || {
        rm -f "$VM_RESTART"
        die "other kib sessions still use the VM after $VM_EVICT_WAIT s; close them, then retry."
    }
    rm -f "$VM_RESTART"
}
_vm_restarting() { kill -0 "$(cat "$VM_RESTART" 2>/dev/null)" 2>/dev/null; }

# Apple's virtiofs reports a file as owned by whoever asks, so gVisor (root) sees kib's private
# dirs as root's and the box user is locked out. bindfs over each reports the host user instead.
# Never over a project, kib's checkout included: under the redaction sidecar it hung `docker run`.
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

# Compressed swap in the VM's own RAM, each boot: a spike slows a box instead of the kernel
# killing it. gVisor holds box memory as shmem, which nothing else can move out. Best effort.
_vm_zram() {
    # shellcheck disable=SC2016 # the VM's shell expands them
    vm_root sh -c 'grep -q zram /proc/swaps && exit; m=$(grep MemTotal /proc/meminfo | tr -dc 0-9)
        modprobe zram && d=$(zramctl -f -a zstd -s $((m / 2))K) && mkswap "$d" && swapon "$d"' \
        >>"$KIB_STATE_ROOT/vm.log" 2>&1 || true
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
    _vm_oom
    # Cut by another kib's restart: decided while fd 205 still holds it back, and no stop timer.
    if _vm_restarting; then
        { [ "${EPHEMERAL:-0}" != 1 ] && [ "${VERB:-}" = claude ] \
            && _VM_RESUME="$(kib_session_id "${SLEEP_STATE:-}" "${SESSION_TAG:-}")"; } || _VM_RESUME=-
    else
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
    fi
    exec 205>&-
}

# The session another kib's restart cut comes back as itself, once the VM is up again.
vm_resume() {
    case "${_VM_RESUME:-}" in
        "") return 0 ;;
        -)
            echo "🛡️  kib: the VM restarted to share a new project, which ended this session." >&2
            return 0
            ;;
    esac
    echo "🛡️  kib: the VM is restarting to share a new project; this session resumes after it." >&2
    rm -rf "${SLEEP_STATE:?}/${SESSION_TAG:?}" # its markers would count as a live session
    trap - INT HUP TERM                        # kib_cleanup's ignore would outlive the exec
    _vm_resume_args ${CMD[@]+"${CMD[@]:2}"}    # CMD: claude --dangerously-skip-permissions …
    exec "$KIB_ROOT/bin/kib" claude ${RESUME_ARGS[@]+"${RESUME_ARGS[@]}"} --resume "$_VM_RESUME" \
        200>&- 201>&- 202>&- 205>&- 206>&-
}

# The session's own claude flags, for its relaunch: never a prompt, which would be sent again, nor
# a session pick. Lists from `claude --help` (2.1). A flag not listed is kept only when no word
# follows it, which may be its value or a prompt: the worst case loses a flag, never replays one.
_vm_resume_args() { # <claude args…> → RESUME_ARGS
    local a next=prompt odd=""
    RESUME_ARGS=()
    for a; do
        case "$a" in
            --) break ;;
            -*)
                [ -z "$odd" ] || RESUME_ARGS+=("$odd")
                odd="" next=prompt
                case "${a%%=*}" in
                    -c | --continue | -p | --print | -r | --resume | --session-id | --fork-session | \
                        --from-pr | --teleport | --cloud | --environment | --bg | --background | \
                        --desktop | -w | --worktree | --tmux) continue ;;
                    --add-dir | --allowedTools | --allowed-tools | --disallowedTools | \
                        --disallowed-tools | --betas | --file | --mcp-config | --tools) next=many ;;
                    --agent | --agents | --append-system-prompt | --append-system-prompt-file | \
                        --autocompact | -d | --debug | --debug-file | --effort | --fallback-model | \
                        --input-format | --json-schema | --max-budget-usd | --model | -n | --name | \
                        --output-format | --permission-mode | --permission-prompts | --plugin-dir | \
                        --plugin-url | --prompt-suggestions | --remote-control | \
                        --remote-control-session-name-prefix | --setting-sources | --settings | \
                        --system-prompt | --system-prompt-file | --system-prompt-snapshot) next=one ;;
                    *) case "$a" in *=*) ;; *) odd=$a && continue ;; esac ;;
                esac
                case "$a" in *=*) next=prompt ;; esac
                RESUME_ARGS+=("$a")
                ;;
            *)
                if [ -n "$odd" ]; then
                    odd="" # an unknown flag's value, or a prompt: neither is kept
                elif [ "$next" != prompt ]; then
                    RESUME_ARGS+=("$a")
                    [ "$next" = many ] || next=prompt
                fi
                ;;
        esac
    done
    [ -z "$odd" ] || RESUME_ARGS+=("$odd")
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
    case "$1" in claude | exec | audit) vm_project_ok ;; esac
    # A session's cleanup calls vm_down; any other verb arms the stop timer at its own exit.
    case "$1" in claude | exec) ;; *) trap vm_down EXIT ;; esac
    vm_up
}
