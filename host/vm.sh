#!/usr/bin/env bash
# Docker runs in a Lima VM while kib stays on the host, so a kernel exploit in the box lands in
# the VM's kernel, not yours (docs/vm.md). Same ~/.claude, login and broker either way: kib
# itself never moves. The VM mounts a fixed set and never a project, so it never restarts for one.
#
# Reads:  KIB_CFG_VM KIB_CFG_VM_SKIP KIB_VM KIB_CONFIG KIB_STATE_ROOT KIB_ROOT HOME LIMA_VM_TYPE LIMA_MOUNT_TYPE
#         LIMA_MOUNT_SET CNAME SYNC_CNAME PATTERNS_STATE KIB_GUARD_FILE_HOST IMAGE_NAME SLUG
#         CLAUDE_HOME
# Writes: DOCKER_HOST DOCKER_CONFIG (exported) _KIB_ENGINE_VM KIB_NODE_CACHE KIB_HOST_GATEWAY
#         VM_MOUNTS VM_RW VM_RO PATH
# shellcheck disable=SC2034

KIB_VM_NAME="kib-vm"
VM_LOCK="$KIB_STATE_ROOT/.locks/vm.lock"
VM_SPEC="$KIB_STATE_ROOT/vm-spec" # the mount set the VM was last booted with
# ponytail: Lima's user-mode network address; read it from the VM if a network differs.
LIMA_HOST_IP=192.168.5.2

LIMA_VERSION=2.2.1
MUTAGEN_VERSION=v0.18.1
DOCKER_VERSION=29.9.3
BUILDX_VERSION=v0.38.2
# Open projects' state, and the VM's only view of kib's: what the box writes in VM_RW, what the
# host writes for the VM (and its own per-container files) in VM_RO, read-only there.
VM_RW="$KIB_STATE_ROOT/vm-rw"
VM_RO="$KIB_STATE_ROOT/vm-ro"
# Never VM-mounted: these files steer the host's Mutagen daemon.
MUTAGEN_DATA="${XDG_STATE_HOME:-$HOME/.local/state}/kib-mutagen"
VM_SYNC_STATUS='{{range .}}{{.Status.Description}}{{with .Beta.StagingProgress}} {{.ReceivedFiles}}/{{.ExpectedFiles}}: {{.Path}}{{end}}{{end}}'
# Each open project's filtered copy, the VM's side of its sync. Never VM-mounted.
VM_SHADOW="${XDG_STATE_HOME:-$HOME/.local/state}/kib-shadow"

vm_wanted() { # always on macOS: kib runs no other engine there
    is_macos && return 0
    case "${KIB_VM:-$KIB_CFG_VM}" in on | auto | 1 | true | yes) ;; *) return 1 ;; esac
}

# Every host path a bind names, at its own path. Not ~/.claude itself: its credential,
# settings.json and CLAUDE.md are copied into the state dir.
_vm_mounts() {
    local d
    VM_MOUNTS=(--mount-only "$KIB_ROOT" --mount-only "$KIB_NODE_CACHE:w")
    for d in plugins skills agents commands hooks; do
        VM_MOUNTS+=(--mount-only "$HOME/.claude/$d:w")
    done
    VM_MOUNTS+=(--mount-only "$VM_RW:w" --mount-only "$VM_RO")
    if [ -n "$LIMA_MOUNT_SET" ]; then VM_MOUNTS+=(--set="$LIMA_MOUNT_SET"); fi
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
    MUTAGEN_DATA_DIRECTORY="$MUTAGEN_DATA" mutagen "$@" 200>&- 201>&- 202>&- 205>&- 206>&-
}

# Pinned, not read off a release: a SHA256SUMS beside the tarball vouches for nothing. Docker
# publishes none for its static CLI; those were hashed at the pin.
_tool() { # <command> → "<sha256> <url> <dir under ~> [tar members…]"; nothing if no build
    local lima="https://github.com/lima-vm/lima/releases/download/v$LIMA_VERSION/lima-$LIMA_VERSION"
    local mg="https://github.com/mutagen-io/mutagen/releases/download/$MUTAGEN_VERSION/mutagen"
    local dk="https://download.docker.com" m=".local/bin mutagen mutagen-agents.tar.gz"
    local bx="https://github.com/docker/buildx/releases/download/$BUILDX_VERSION/buildx-$BUILDX_VERSION"
    local p=".local/docker/cli-plugins docker-buildx"
    case "$1 $KIB_OS-$(uname -m)" in
        "limactl linux-x86_64") echo "b391ac7fcac2b2a5a1628107756463188ded4d18d3104a40a66a8bb6fec01bcb $lima-Linux-x86_64.tar.gz .local" ;;
        "limactl linux-aarch64") echo "fbcf4d127936666aa2cf6013b663c250431f2a59394757b404070f8d6a160e10 $lima-Linux-aarch64.tar.gz .local" ;;
        "limactl darwin-x86_64") echo "6b776e4bc41f358e6ee01fefcc78e2eb26f11635a0fcff632234af77a566c6c4 $lima-Darwin-x86_64.tar.gz .local" ;;
        "limactl darwin-arm64") echo "9e9eacce88f37e185c346bad73aa6136f738d8cdf8c3bb23cd42b071824bc66e $lima-Darwin-arm64.tar.gz .local" ;;
        "mutagen linux-x86_64") echo "7735286c778cc438418209f24d03a64f3a0151c8065ef0fe079cfaf093af6f8f ${mg}_linux_amd64_$MUTAGEN_VERSION.tar.gz $m" ;;
        "mutagen linux-aarch64") echo "bcba735aebf8cbc11da9b3742118a665599ac697fa06bc5751cac8dcd540db8a ${mg}_linux_arm64_$MUTAGEN_VERSION.tar.gz $m" ;;
        "mutagen darwin-x86_64") echo "7d06f7d8fcfe90bc7e55cc834a2f2f20c2e0af9ea9bc35911fc4341ad56a9bbf ${mg}_darwin_amd64_$MUTAGEN_VERSION.tar.gz $m" ;;
        "mutagen darwin-arm64") echo "6f810416d9e5fc4fd5e18431146f8b3c5a2056ba5a24f76c1e66da86eb3257e2 ${mg}_darwin_arm64_$MUTAGEN_VERSION.tar.gz $m" ;;
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

# What VM mode lacks, installed after one prompt. 1 = still missing: declined, or not possible.
_vm_tools() {
    local t miss=""
    for t in limactl mutagen docker; do
        command -v "$t" >/dev/null 2>&1 || miss="$miss $t"
    done
    # Without buildx, docker falls back to its legacy builder: every line, and no BuildKit cache.
    docker buildx version >/dev/null 2>&1 || miss="$miss buildx"
    [ -z "$miss" ] || { [ -t 0 ] && lima_host_ready && _vm_install "$miss"; }
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
    printf '🛡️  kib: VM mode runs every box in a Lima VM, so a kernel exploit stays in it.\n' >&2
    printf '   Install %s into ~/.local? [Y/n/never] ' "$list" >&2
    read -r a || true
    case "$a" in
        [nN]ever)
            is_macos && return 1 # no other engine to turn to
            mkdir -p "${KIB_CONFIG%/*}" && echo "vm = off" >>"$KIB_CONFIG" && KIB_CFG_VM=off
            echo "   OK: 'vm = off' is now in $KIB_CONFIG." >&2
            return 1
            ;;
        [nN]*) return 1 ;;
    esac
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

# The project reaches the VM in two hops. Host-local first, into a shadow copy with every guarded
# path dropped: both ends scanned here, so the guard holds whatever the VM's Mutagen agent claims
# (PLAN_VM_SECURITY.md S5). Then the shadow ⇄ a VM volume. The host wins conflicts on both.
vm_sync_start() {
    local uid gid cfg="$PATTERNS_STATE.sync.yml" shadow="$VM_SHADOW/$CNAME"
    uid="$(box_uid)" gid="$(box_gid)"
    kib_py shared.rules sync-config "$KIB_GUARD_FILE_HOST" "$PATTERNS_STATE" "$KIB_CFG_VM_SKIP" >"$cfg"
    kib_py shared.rules vm-sync-config "$KIB_CFG_VM_SKIP" >"$cfg.vm"
    # A failed close kept its sessions: flush them first, while they still hold their history,
    # so the box's last edits reach the project. A new session would see every difference as a
    # conflict, and the host's copy would win.
    if docker start "$SYNC_CNAME" >/dev/null 2>&1; then
        _mutagen sync flush "$CNAME" >/dev/null 2>&1 && _mutagen sync flush "$CNAME-host" >/dev/null 2>&1
    fi
    _mutagen sync terminate "$CNAME" "$CNAME-host" >/dev/null 2>&1 || true
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
    # What the host-local hop drops, one way: redacted files as their keys, protected ones as is.
    # ponytail: seeded once per container; a host edit to one shows at the next cold start.
    {
        (umask 077 && mkdir -p "$shadow") \
            && kib_py host.vmseed seed "$KIB_GUARD_FILE_HOST" "$PATTERNS_STATE" "$PWD" "$shadow" \
                "$KIB_CFG_VM_SKIP"
    } || die "could not stage the redacted and protected files' stand-ins in $shadow."
    echo "🔄 kib: syncing $PWD into the VM…" >&2
    local t0=$SECONDS
    {
        _vm_session "$CNAME-host" "$cfg" "$PWD" "$shadow" \
            && _vm_session "$CNAME" "$cfg.vm" "$shadow" "docker://$SYNC_CNAME/src"
    } || die "could not sync $PWD into the VM." "$(_mutagen sync list "$CNAME-host" "$CNAME" 2>&1)"
    [ $((SECONDS - t0)) -lt 30 ] || note "ℹ️  kib: the first sync took $((SECONDS - t0)) s. To skip folders the box can rebuild,
   put their names in this line, then paste it:
   echo 'vm_skip = dist, .yarn' >> $KIB_CONFIG"
}

# A reloaded .kibignore re-filters the host hop: recreate it on the new ignores, and swap every
# file it now redacts in the shadow for its render. The VM hop carries both into the volume.
vm_sync_restage() {
    local cfg="$PATTERNS_STATE.sync.yml" shadow="$VM_SHADOW/$CNAME"
    # Built first: until the new session exists, no box edit reaches the project.
    kib_py shared.rules sync-config "$KIB_GUARD_FILE_HOST" "$PATTERNS_STATE" "$KIB_CFG_VM_SKIP" \
        >"$cfg.new" || return 1
    # Flushed first: a fresh session lets the host win every difference it finds.
    _mutagen sync flush "$CNAME-host" >/dev/null 2>&1 || true
    _mutagen sync terminate "$CNAME-host" >/dev/null 2>&1 || true
    kib_py host.vmseed redact "$KIB_GUARD_FILE_HOST" "$PATTERNS_STATE" "$PWD" "$shadow" \
        "$KIB_CFG_VM_SKIP" || warn "could not re-render the newly redacted files in $shadow."
    mv "$cfg.new" "$cfg" && _vm_session "$CNAME-host" "$cfg" "$PWD" "$shadow"
}

_vm_session() { # <name> <config> <alpha> <beta> — create, then wait for the first sync
    local pid cols
    _mutagen sync create --name "$1" --label kib=1 --sync-mode two-way-resolved \
        --symlink-mode posix-raw --no-ignore-vcs -c "$2" "$3" "$4" >/dev/null || return 1
    _mutagen sync flush "$1" >/dev/null 200>&- 201>&- 205>&- 206>&- &
    pid=$!
    cols="$(tput cols 2>/dev/null || echo 80)"
    while [ -t 2 ] && kill -0 "$pid" 2>/dev/null; do # one line: status, and the file it is on
        printf '\r\033[K   %s' "$(_mutagen sync list "$1" --template "$VM_SYNC_STATUS" 2>/dev/null \
            | sed 's/ on beta//' | cut -c "1-$((cols - 4))")" >&2
        sleep 1
    done
    [ ! -t 2 ] || printf '\r\033[K' >&2
    wait "$pid"
}

# Flush VM → shadow → project, then drop it all. A failed flush keeps everything, so no box edit
# is ever lost.
vm_sync_stop() {
    engine_lima || return 0
    if docker start "$SYNC_CNAME" >/dev/null 2>&1 \
        && ! _mutagen sync flush "$CNAME" >/dev/null 2>&1; then
        warn "the box's last edits did not sync back. They stay in the VM volume $CNAME-src," \
            "and the next kib in $PWD carries them over first."
        return 0
    fi
    if _mutagen sync list "$CNAME-host" >/dev/null 2>&1 \
        && ! _mutagen sync flush "$CNAME-host" >/dev/null 2>&1; then
        warn "the box's last edits did not sync back. They stay in $VM_SHADOW/$CNAME," \
            "and the next kib in $PWD carries them over first."
        return 0
    fi
    _mutagen sync terminate "$CNAME" "$CNAME-host" >/dev/null 2>&1 || true
    docker rm -f "$SYNC_CNAME" >/dev/null 2>&1 || true
    docker volume rm "$CNAME-src" >/dev/null 2>&1 || true
    rm -rf "${VM_SHADOW:?}/${CNAME:?}"
}

# A project's session dir and transcripts sit on VM_RW only while it is open: `in` at launch, `out`
# at the last exit. Canonical keeps a link, so a host claude still finds its transcripts.
# VM root can swap any vm-rw dir for a link; the host must never write or move through one.
vm_state() { # in | out
    local home="$KIB_STATE_ROOT/$SLUG" vm="$VM_RW/$SLUG" tr="$CLAUDE_HOME/projects/$SLUG"
    if [ -L "$vm" ] || [ -L "$vm/transcripts" ] || [ -L "$VM_RW/.state" ]; then
        [ ! -L "$tr" ] || rm -f "$tr"
        warn "$vm, its transcripts or $VM_RW/.state is a symlink, which kib never makes:" \
            "something in the VM planted it. Delete it (rm, not rm -r) and relaunch."
        [ "$1" = out ] && return 1 # teardown must go on
        exit 1
    fi
    if [ "$1" = in ]; then
        [ -e "$vm" ] || mv "$home" "$vm" 2>/dev/null || mkdir -p "$vm"
        mkdir -p "$tr" 2>/dev/null || true
        if [ ! -L "$tr" ] && [ ! -e "$vm/transcripts" ]; then
            mv "$tr" "$vm/transcripts" && ln -s "$vm/transcripts" "$tr"
        fi
    elif [ -e "$vm" ] && [ ! -e "$home" ]; then # native mode tidies what a crashed VM run left
        if [ -L "$tr" ]; then rm -f "$tr" && mv "$vm/transcripts" "$tr"; fi
        mv "$vm" "$home"
    fi
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
    _mutagen daemon stop >/dev/null 2>&1 || true
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
    PATH="$PATH:$HOME/.local/bin:$HOME/.local/docker" # where _vm_tools installs
    # kib's docker config, plugins beside it. Not ~/.docker: Docker Desktop's `credsStore: desktop`
    # there fails every pull once it is gone.
    export DOCKER_CONFIG="$HOME/.local/docker"
    if ! _vm_tools; then
        is_macos && die "kib on macOS runs every box in a Lima VM." \
            "Run kib in a terminal and answer Y to install it (no sudo, nothing else changes)."
        case "$1" in claude | exec) ;; *) return 0 ;; esac
        vm_wanted || return 0 # answered never
        warn "this box shares your kernel: a kernel exploit inside it owns this machine." \
            "Install Lima once and every box runs in a VM: $KIB_ROOT/docs/vm.md" \
            "(hide this note: 'vm = off' in $KIB_CONFIG)"
        return 0
    fi
    vm_up
}
