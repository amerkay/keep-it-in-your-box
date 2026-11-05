#!/usr/bin/env bash
# Docker runs in a Lima VM while kib stays on the host, so a kernel exploit in the box lands in
# the VM's kernel, not yours (docs/vm.md). Same ~/.claude, login and broker either way: kib
# itself never moves. The VM mounts a fixed set and never a project, so it never restarts for one.
#
# Reads:  KIB_CFG_VM KIB_VM KIB_CONFIG KIB_STATE_ROOT KIB_ROOT HOME LIMA_VM_TYPE LIMA_MOUNT_TYPE
#         CNAME SYNC_CNAME PATTERNS_STATE KIB_GUARD_FILE_HOST IMAGE_NAME
# Writes: DOCKER_HOST (exported) _KIB_ENGINE_VM KIB_NODE_CACHE KIB_HOST_GATEWAY VM_MOUNTS
#         MUTAGEN_BIN
# shellcheck disable=SC2034

KIB_VM_NAME="kib-vm"
VM_LOCK="$KIB_STATE_ROOT/.locks/vm.lock"
VM_SPEC="$KIB_STATE_ROOT/vm-spec" # the mount set the VM was last booted with
# ponytail: Lima's user-mode network address; read it from the VM if a network differs.
LIMA_HOST_IP=192.168.5.2

# Pinned, not read off the release: a SHA256SUMS beside the tarball vouches for nothing.
MUTAGEN_VERSION=v0.18.1
# Not under $KIB_STATE_ROOT: the VM mounts that, and these files steer the host's daemon.
MUTAGEN_DATA="${XDG_STATE_HOME:-$HOME/.local/state}/kib-mutagen"

vm_wanted() {
    case "${KIB_VM:-$KIB_CFG_VM}" in on | auto | 1 | true | yes) ;; *) return 1 ;; esac
    is_macos || [ "$(docker context show 2>/dev/null)" != desktop-linux ]
}

# Every host path a bind names, at its own path. Not ~/.claude itself: its credential,
# settings.json and CLAUDE.md are copied into the state dir.
_vm_mounts() {
    local d
    VM_MOUNTS=(--mount-only "$KIB_ROOT" --mount-only "$KIB_NODE_CACHE:w")
    for d in plugins skills agents commands hooks; do
        VM_MOUNTS+=(--mount-only "$HOME/.claude/$d:w")
    done
    # ponytail: until phase 3 of PLAN_VM_SECURITY.md syncs only the open project's slices.
    VM_MOUNTS+=(--mount-only "$HOME/.claude/projects:w" --mount-only "$KIB_STATE_ROOT:w"
        --mount-only "${KIB_CONFIG%/*}")
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
# count as the project lock. Boot (fd 206) serialises create, start and re-mount.
vm_up() {
    local status want m
    mkdir -p "$KIB_STATE_ROOT/.locks"
    exec 205>"$VM_LOCK"
    lock_fd -w 120 -s 205 || die "timed out waiting for the VM to stop ($VM_LOCK)."
    exec 206>"$VM_LOCK.boot"
    lock_fd -x 206
    KIB_NODE_CACHE="$KIB_NODE_CACHE-vm" # VM root can rewrite it, so native boxes never run it
    _vm_mounts
    for m in "${VM_MOUNTS[@]}"; do
        case "$m" in --*) ;; *) (umask 077 && mkdir -p "${m%:w}") ;; esac
    done
    want="$LIMA_MOUNT_TYPE ${VM_MOUNTS[*]}"
    status="$(limactl list --format '{{.Status}}' "$KIB_VM_NAME" 2>/dev/null || true)"
    if [ -z "$status" ]; then
        _limactl "creating its VM — one time, a few minutes" start --name "$KIB_VM_NAME" \
            --mount-inotify --vm-type="$LIMA_VM_TYPE" --mount-type="$LIMA_MOUNT_TYPE" \
            "${VM_MOUNTS[@]}" template:docker-rootful
        printf '%s\n' "$want" >"$VM_SPEC"
    elif [ "$want" != "$(cat "$VM_SPEC" 2>/dev/null)" ] && lock_fd -n -x 205; then
        # A kib upgrade changed the mount set. Only with nobody else in it: never cut a session.
        limactl stop "$KIB_VM_NAME" >/dev/null 2>&1 || true
        _limactl "updating its VM's mounts (one restart)" edit --start \
            --mount-type="$LIMA_MOUNT_TYPE" "${VM_MOUNTS[@]}" "$KIB_VM_NAME"
        printf '%s\n' "$want" >"$VM_SPEC"
        lock_fd -s 205
    elif [ "$status" != Running ]; then
        _limactl "starting its VM" start "$KIB_VM_NAME"
    fi
    lock_fd -u 206
    exec 206>&-
    unset DOCKER_CONTEXT
    DOCKER_HOST="unix://$(limactl list --format '{{.Dir}}' "$KIB_VM_NAME")/sock/docker.sock"
    export DOCKER_HOST
    _KIB_ENGINE_VM=1
    KIB_HOST_GATEWAY="$LIMA_HOST_IP"
    # The engine-VM paths nsenter through a privileged container: only ever into a rootful VM.
    ! is_rootless || die "the Lima VM '$KIB_VM_NAME' runs rootless Docker, which kib cannot use." \
        "Delete it once and kib recreates it: limactl delete -f $KIB_VM_NAME"
}

# Any call may start Mutagen's daemon, which outlives kib: it must never hold a lock fd, or no kib
# is ever the last one out (container-lifecycle.md). Same for limactl's host agent.
_mutagen() {
    MUTAGEN_DATA_DIRECTORY="$MUTAGEN_DATA" "$MUTAGEN_BIN" "$@" 200>&- 201>&- 202>&- 205>&- 206>&-
}

_mutagen_ensure() {
    local a arch sum tmp bin="$HOME/.local/bin"
    MUTAGEN_BIN="$(command -v mutagen || echo "$bin/mutagen")"
    [ -x "$MUTAGEN_BIN" ] && return 0
    [ -t 0 ] || die "VM mode syncs projects with Mutagen, which is not installed." \
        "Run kib in a terminal once to install it, or turn VM mode off: vm = off in $KIB_CONFIG"
    printf '🛡️  kib: VM mode syncs open projects with Mutagen (MIT, by Docker).\n' >&2
    printf '   Install Mutagen %s into %s? [Y/n] ' "$MUTAGEN_VERSION" "$bin" >&2
    read -r a || true
    case "$a" in n* | N*) die "VM mode needs Mutagen. Or turn VM mode off: vm = off in $KIB_CONFIG" ;; esac
    case "$KIB_OS-$(uname -m)" in
        linux-x86_64) arch=linux_amd64 sum=7735286c778cc438418209f24d03a64f3a0151c8065ef0fe079cfaf093af6f8f ;;
        linux-aarch64) arch=linux_arm64 sum=bcba735aebf8cbc11da9b3742118a665599ac697fa06bc5751cac8dcd540db8a ;;
        darwin-x86_64) arch=darwin_amd64 sum=7d06f7d8fcfe90bc7e55cc834a2f2f20c2e0af9ea9bc35911fc4341ad56a9bbf ;;
        darwin-arm64) arch=darwin_arm64 sum=6f810416d9e5fc4fd5e18431146f8b3c5a2056ba5a24f76c1e66da86eb3257e2 ;;
        *) die "no Mutagen build for $KIB_OS-$(uname -m). Turn VM mode off: vm = off in $KIB_CONFIG" ;;
    esac
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/m.tgz" "https://github.com/mutagen-io/mutagen/releases/download/$MUTAGEN_VERSION/mutagen_${arch}_$MUTAGEN_VERSION.tar.gz" \
        || die "could not download Mutagen (curl, above)."
    [ "$(sha256_file "$tmp/m.tgz")" = "$sum" ] || die "the Mutagen download failed its checksum."
    {
        tar -xzf "$tmp/m.tgz" -C "$tmp" mutagen mutagen-agents.tar.gz && mkdir -p "$bin" \
            && mv "$tmp/mutagen" "$tmp/mutagen-agents.tar.gz" "$bin/"
    } || die "could not install Mutagen into $bin."
    rm -rf "$tmp"
    MUTAGEN_BIN="$bin/mutagen"
}

# The project's copy in the VM: a volume, a capless endpoint holding it, and a Mutagen session from
# the host. The host wins conflicts. Ignores drop every guarded path (kib/shared/rules.py).
vm_sync_start() {
    local uid gid cfg="$PATTERNS_STATE.sync.yml"
    uid="$(box_uid)" gid="$(box_gid)"
    kib_py shared.rules sync-config "$KIB_GUARD_FILE_HOST" "$PATTERNS_STATE" >"$cfg"
    # A volume a failed close kept is reused: the new session carries its edits back.
    _mutagen sync terminate "$CNAME" >/dev/null 2>&1 || true
    docker rm -f "$SYNC_CNAME" >/dev/null 2>&1 || true
    docker volume create --label kib-src=1 "$CNAME-src" >/dev/null
    # CHOWN: Mutagen chowns the agent it injects. The passwd entry: it looks up its own user. No
    # host binds: `docker start` at the next cold start would make a missing source a directory.
    {
        docker run -d --name "$SYNC_CNAME" --network none --cap-drop=ALL --cap-add=CHOWN \
            --security-opt no-new-privileges --user "$uid:$gid" -e HOME=/tmp \
            -v "$CNAME-src:/src" --entrypoint sleep "$IMAGE_NAME" infinity >/dev/null \
            && docker exec -u 0 "$SYNC_CNAME" sh -c "chown $uid:$gid /src &&
                echo kib:x:$uid:$gid::/tmp:/bin/sh >>/etc/passwd && echo kib:x:$gid: >>/etc/group"
    } || die "could not start the project's sync container ($SYNC_CNAME)."
    echo "🔄 kib: syncing $PWD into the VM…" >&2
    {
        _mutagen sync create --name "$CNAME" --label kib=1 --sync-mode two-way-resolved \
            --symlink-mode posix-raw --no-ignore-vcs -c "$cfg" "$PWD" "docker://$SYNC_CNAME/src" \
            >/dev/null && _mutagen sync flush "$CNAME" >/dev/null
    } || die "could not sync $PWD into the VM." "$(_mutagen sync list "$CNAME" 2>&1)"
    # What the sync ignores, one way: redacted files as their keys, protected ones as is.
    # ponytail: seeded once per container; a host edit to one shows at the next cold start.
    kib_py host.vmseed seed "$KIB_GUARD_FILE_HOST" "$PATTERNS_STATE" "$PWD" \
        | docker exec -i -u "$uid:$gid" "$SYNC_CNAME" tar -xf - -C /src \
        || die "could not copy the redacted and protected files' stand-ins into the VM."
}

# Flush, then drop it all. A failed flush keeps everything, so no box edit is ever lost.
vm_sync_stop() {
    engine_lima || return 0
    if docker start "$SYNC_CNAME" >/dev/null 2>&1 \
        && ! _mutagen sync flush "$CNAME" >/dev/null 2>&1; then
        warn "the box's last edits did not sync back. They stay in the VM volume $CNAME-src," \
            "and the next kib here carries them over."
        return 0
    fi
    _mutagen sync terminate "$CNAME" >/dev/null 2>&1 || true
    docker rm -f "$SYNC_CNAME" >/dev/null 2>&1 || true
    docker volume rm "$CNAME-src" >/dev/null 2>&1 || true
}

# Last kib out stops the VM. A kib starting meanwhile waits on its shared acquire, then restarts it.
vm_down() {
    engine_lima || return 0
    exec 205>&-
    exec 205>"$VM_LOCK"
    if lock_fd -n -x 205; then
        echo "🛡️  kib: last session closed — stopping the VM." >&2
        limactl stop "$KIB_VM_NAME" >/dev/null 2>&1 || true
        _mutagen daemon stop >/dev/null 2>&1 || true
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
        is_macos && return 0 # Docker Desktop is already a VM
        case "$1" in claude | exec) ;; *) return 0 ;; esac
        echo "⚠️  kib: this box shares your kernel — a kernel exploit inside it owns this machine." >&2
        echo "   Install Lima once and every box runs in a VM: $KIB_ROOT/docs/vm.md" >&2
        echo "   (hide this note: 'vm = off' in $KIB_CONFIG)" >&2
        return 0
    fi
    _mutagen_ensure
    vm_up
}
