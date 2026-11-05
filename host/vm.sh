#!/usr/bin/env bash
# Linux: Docker runs in a Lima VM while kib stays on the host, so a kernel exploit in the box lands
# in the VM's kernel, not yours — the engine-in-a-VM shape macOS gets from Docker Desktop
# (docs/vm.md). Same ~/.claude, login and broker either way: kib itself never moves.
#
# Reads:  KIB_CFG_VM KIB_VM KIB_CONFIG KIB_STATE_ROOT KIB_NODE_CACHE KIB_ROOT HOME
# Writes: DOCKER_HOST (exported) _KIB_ENGINE_VM VM_MOUNTS
# shellcheck disable=SC2034

KIB_VM_NAME="kib-vm"
VM_ROOTS="$KIB_STATE_ROOT/vm-roots" # project roots the VM mounts, one per line
VM_LOCK="$KIB_STATE_ROOT/.locks/vm.lock"

vm_wanted() {
    case "${KIB_VM:-$KIB_CFG_VM}" in on | auto | 1 | true | yes) ;; *) return 1 ;; esac
    ! is_macos && [ "$(docker context show 2>/dev/null)" != desktop-linux ]
}

_vm_covered() { # <dir> [roots-file]
    local r
    [ -f "${2:-$VM_ROOTS}" ] || return 1
    while IFS= read -r r; do
        case "$1/" in "$r"/*) return 0 ;; esac
    done <"${2:-$VM_ROOTS}"
    return 1
}

# A projects root, so siblings need no VM restart: the parent, asked once, never $HOME or a dir
# that holds more than code. No tty or a "n" mounts only the project.
_vm_pick_root() { # <project>
    local parent root="$1" a=""
    case "$1/" in "$KIB_ROOT"/*) root="$KIB_ROOT" ;; esac # one mount for kib, not rw over ro
    parent="$(dirname "$root")"
    case "$parent" in
        "$HOME" | "$HOME"/Desktop | "$HOME"/Documents | "$HOME"/Downloads) ;;
        "$HOME"/*)
            if [ "$root" = "$1" ] && [ -t 0 ]; then
                printf '🛡️  kib: let the VM read and write all of %s (every project in it)? [Y/n] ' \
                    "$parent" >&2
                read -r a || true
                case "$a" in n* | N*) ;; *) root="$parent" ;; esac
            fi
            ;;
    esac
    case "$HOME/" in "$root"/*) die "kib will not let the VM mount $root — it holds your home." ;; esac
    printf '%s' "$root"
}

# Every host path a bind can name, at its own path. Not all of ~/.claude: its credential,
# settings.json and CLAUDE.md are copied into the state dir, so the VM never sees them.
_vm_fixed() {
    local d
    for d in plugins skills agents commands hooks projects; do
        printf '%s/.claude/%s:w\n' "$HOME" "$d"
    done
    printf '%s:w\n%s:w\n%s\n%s\n' "$KIB_STATE_ROOT" "$KIB_NODE_CACHE" "${KIB_CONFIG%/*}" "$KIB_ROOT"
}

_vm_mounts() { # <roots-file> → VM_MOUNTS
    local m
    VM_MOUNTS=()
    while IFS= read -r m; do VM_MOUNTS+=(--mount-only "$m:w"); done <"$1"
    while IFS= read -r m; do
        _vm_covered "${m%:w}" "$1" || VM_MOUNTS+=(--mount-only "$m")
    done <<EOF
$(_vm_fixed)
EOF
}

# Bring the VM up for this kib and hold its session count (fd 205, shared) until exit — the same
# reference count as the project lock. Boot (fd 206) serialises create/start/re-mount.
vm_up() { # [project] — none for host-global verbs, which must never add a mount
    local status m dir root="" new="$VM_ROOTS.new"
    mkdir -p "$KIB_STATE_ROOT/.locks"
    exec 205>"$VM_LOCK"
    lock_fd -w 120 -s 205 || die "timed out waiting for the VM to stop ($VM_LOCK)."
    exec 206>"$VM_LOCK.boot"
    lock_fd -x 206
    status="$(limactl list --format '{{.Status}}' "$KIB_VM_NAME" 2>/dev/null || true)"
    touch "$VM_ROOTS"
    if [ -n "${1:-}" ] && ! _vm_covered "$1"; then
        root="$(_vm_pick_root "$1")" || exit 1
        {
            while IFS= read -r m; do
                case "$m/" in "$root"/*) ;; *) printf '%s\n' "$m" ;; esac
            done <"$VM_ROOTS"
            printf '%s\n' "$root"
        } >"$new"
    else
        cp "$VM_ROOTS" "$new"
    fi
    while IFS= read -r m; do (umask 077 && mkdir -p "${m%:w}"); done <<EOF
$(_vm_fixed)
EOF
    _vm_mounts "$new"
    if [ -z "$status" ]; then
        echo "🛡️  kib: creating its VM — one time, a few minutes." >&2
        limactl start --name "$KIB_VM_NAME" --tty=false --mount-inotify \
            ${VM_MOUNTS[@]+"${VM_MOUNTS[@]}"} template:docker-rootful \
            || die "could not create the Lima VM '$KIB_VM_NAME' — see the output above."
    elif [ -n "$root" ]; then
        lock_fd -n -x 205 || die "the VM must restart to see $root, but other kib sessions" \
            "are using it. Close them, then run kib here again."
        echo "🛡️  kib: restarting the VM so it can see $root." >&2
        limactl stop "$KIB_VM_NAME" >/dev/null 2>&1 || true
        limactl edit --tty=false --start ${VM_MOUNTS[@]+"${VM_MOUNTS[@]}"} "$KIB_VM_NAME" \
            || die "could not re-mount the Lima VM '$KIB_VM_NAME' — see the output above."
        lock_fd -s 205
    elif [ "$status" != Running ]; then
        echo "🛡️  kib: starting its VM." >&2
        limactl start --tty=false "$KIB_VM_NAME" >/dev/null 2>&1 \
            || die "could not start the Lima VM '$KIB_VM_NAME' (limactl start $KIB_VM_NAME)."
    fi
    mv -f "$new" "$VM_ROOTS"
    lock_fd -u 206
    exec 206>&-
    unset DOCKER_CONTEXT
    dir="$(limactl list --format '{{.Dir}}' "$KIB_VM_NAME")"
    export DOCKER_HOST="unix://$dir/sock/docker.sock"
    _KIB_ENGINE_VM=1
    # The engine-VM paths nsenter through a privileged container: only ever into a rootful VM.
    ! is_rootless || die "the Lima VM '$KIB_VM_NAME' runs rootless Docker, which kib cannot use." \
        "Delete it once and kib recreates it: limactl delete -f $KIB_VM_NAME"
}

# Last kib out stops the VM. A kib starting meanwhile waits on its shared acquire, then restarts it.
vm_down() {
    [ "$_KIB_ENGINE_VM" = 1 ] || return 0
    exec 205>&-
    exec 205>"$VM_LOCK"
    if lock_fd -n -x 205; then
        echo "🛡️  kib: last session closed — stopping the VM." >&2
        limactl stop "$KIB_VM_NAME" >/dev/null 2>&1 || true
    fi
    exec 205>&-
}

vm_use() { # <verb>
    if ! vm_wanted; then
        # Native kib driving the VM's engine mounts FUSE in the VM, then waits for it here forever.
        case "${DOCKER_HOST:-}" in *"/$KIB_VM_NAME/sock/"*)
            die "DOCKER_HOST points at kib's VM ($DOCKER_HOST), but VM mode is off." \
                "Run: unset DOCKER_HOST   (or turn VM mode on: vm = on)"
            ;;
        esac
        return 0
    fi
    if ! command -v limactl >/dev/null 2>&1; then
        case "$1" in claude | exec) ;; *) return 0 ;; esac
        echo "⚠️  kib: this box shares your kernel — a kernel exploit inside it owns this machine." >&2
        echo "   Install Lima once and every box runs in a VM: $KIB_ROOT/docs/vm.md" >&2
        echo "   (hide this note: 'vm = off' in $KIB_CONFIG)" >&2
        return 0
    fi
    case "$1" in
        build | broker) vm_up ;;
        *)
            cd -P . || exit 1 # the VM mounts physical paths; a symlinked $PWD would not resolve in it
            vm_up "$PWD"
            ;;
    esac
}
