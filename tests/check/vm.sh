#!/usr/bin/env bash
# Sourced by tests/check.sh — host/vm.sh's mounts, gVisor and VM lifetime, with a fake limactl.
# shellcheck disable=SC2030,SC2031,SC2034  # _vm_run sets PATH and launch state in a subshell
# shellcheck disable=SC2016  # the fakes expand their own $*

# shellcheck source=SCRIPTDIR/_guard.sh
. "${BASH_SOURCE%/*}/_guard.sh" # sourced by tests/check.sh, never run directly

section "Engines: Lima VM, rootless and rootful Docker (host/vm.sh, host/engine.sh)"

_vm_dir="$(mktemp -d)"
mkdir -p "$_vm_dir/bin" "$_vm_dir/home/devel/proj" "$_vm_dir/lima"
# Fake limactl: an existing, running VM; stops, edits and root shells are logged. A root shell
# that runs `runsc install` registers the runtime it names (its last argument) with fake docker.
cat >"$_vm_dir/bin/limactl" <<EOF
#!/usr/bin/env bash
case "\$1" in
    list) case "\$3" in
        *Dir*) echo "$_vm_dir/lima" ;;
        *Memory*) echo 4294967296 ;;
        *) cat "$_vm_dir/status" 2>/dev/null || echo Running ;;
    esac ;;
    stop) echo stop >>"$_vm_dir/stops" ;;
    edit) echo "\$*" >>"$_vm_dir/edits" ;;
    start) echo start >>"$_vm_dir/starts" ;;
    shell)
        ls /proc/\$\$/fd >>"$_vm_dir/shell-fds"
        case "\$*" in
            *"runsc install"*) echo "\${@: -1}" >>"$_vm_dir/runtimes" && echo gvisor >>"$_vm_dir/installs" ;;
            *nameserver*) echo "nameserver 192.168.5.3" ;;
            *bindfs*) echo "\$*" >>"$_vm_dir/bindfs" ;;
            *only-upgrade*) echo docker >>"$_vm_dir/upgrades" ;;
            *vmstat*) [ -e "$_vm_dir/oom" ] ;;
            *zram*) echo zram >>"$_vm_dir/zram" ;;
            *"system prune"*) echo moved >>"$_vm_dir/classic" ;;
            *"docker info"*) if [ -e "$_vm_dir/classic" ]; then echo overlay2; else echo overlayfs; fi ;;
            *"mount -t nfs"*) echo "\$*" >>"$_vm_dir/nfs" ;;
        esac
        ;;
esac
EOF
printf '#!/usr/bin/env bash\ncase "$1" in info) cat "%s/runtimes" 2>/dev/null ;; esac\n' "$_vm_dir" \
    >"$_vm_dir/bin/docker"
chmod +x "$_vm_dir/bin/"*

# Subshells inherit these; a `sh -c` would not see the sourced functions.
_vm_t_mounts() { _vm_mounts && printf '%s\n' "${VM_MOUNTS[@]}"; }
_vm_t_up() { vm_up && printf '%s %s %s\n' "$DOCKER_HOST" "$(engine_lima && echo vm)" \
    "$KIB_HOST_GATEWAY"; }
_vm_edits() { if [ -f "$_vm_dir/edits" ]; then wc -l <"$_vm_dir/edits" | tr -d ' '; else echo 0; fi; }
_vm_t_last() { VM_LINGER=1 && vm_up && vm_down; }
_vm_stops() { if [ -f "$_vm_dir/stops" ]; then wc -l <"$_vm_dir/stops" | tr -d ' '; else echo 0; fi; }
_vm_t_engine() { if engine_lima; then echo vm; else echo native; fi; }
_vm_t_shared() { exec 207>"$VM_LOCK" && flock -s 207 && vm_up && vm_down; }
_vm_t_resolv() { _KIB_ENGINE_VM=1 && vm_resolv "$_vm_dir/resolv" && cat "$_vm_dir/resolv"; }
_vm_t_view() { mkdir -p "$KIB_STATE_ROOT" && vm_view_mount /mnt/kib/abc 40123 s3cr3t && cat "$_vm_dir/nfs"; }
_vm_t_hostonly() {
    _vm_mounts && _vm_under "$KIB_HOST_ONLY" "${VM_MOUNTS[@]}" && echo shared
    true
}

_vm_run() { ( # <PATH> <cmd…> — a fresh subshell with the units loaded, HOME and state faked
    export HOME="$_vm_dir/home" KIB_STATE_ROOT="$_vm_dir/home/.local/state/kib"
    export KIB_CONFIG="$_vm_dir/home/.keep-it-in-your-box/config" KIB_NODE_CACHE="$_vm_dir/node"
    PATH="$1"
    unset KIB_PORTABLE_SOURCED # a fresh load, as bin/kib does
    shift
    # shellcheck source=/dev/null
    . "$KIB_ROOT/host/core.sh" && . "$KIB_ROOT/host/portable.sh" && . "$KIB_ROOT/host/vm.sh" \
        && . "$KIB_ROOT/host/engine.sh"
    cd "$HOME/devel/proj" && "$@"
) 2>&1 </dev/null; }

is "an inherited _KIB_ENGINE_VM=1 is ignored" "native" "$(_KIB_ENGINE_VM=1 _vm_run "$PATH" _vm_t_engine)"
_vm_h="$_vm_dir/home"
is "the VM never mounts ~: ~/.claude, kib's own dirs, its checkout read-only" \
    "--mount-only $_vm_h/.claude:w --mount-only $_vm_h/.local/state/kib:w --mount-only $_vm_dir/node:w --mount-only $KIB_ROOT" \
    "$(_vm_run "$PATH" _vm_t_mounts | tr '\n' ' ' | sed 's/ $//')"
is "the view's binary and rules are outside every VM share: VM root cannot swap them" "" \
    "$(_vm_run "$PATH" _vm_t_hostonly)"
case "$(_vm_run "$_vm_dir/bin:$PATH" _vm_t_view)" in
    *'mount -t nfs -o "$2,port=$3,mountport=$3" "$4:/$5" "$1"'*" _ /mnt/kib/abc vers=3,proto=tcp,mountproto=tcp,nolock,sync,actimeo=1,soft,timeo=10,retrans=2 40123 192.168.5.2 s3cr3t")
        pass "VM root mounts a view from the host's loopback, by its secret path, soft"
        ;;
    *) fail "the view's NFS mount is wrong" "$(_vm_run "$_vm_dir/bin:$PATH" _vm_t_view)" ;;
esac
is "the docker engine moves into the VM; kib stays here" \
    "unix://$_vm_dir/lima/sock/docker.sock vm 192.168.5.2" "$(_vm_run "$_vm_dir/bin:$PATH" _vm_t_up | tail -1)"
is "gVisor is installed once per pin" "1" \
    "$(_vm_run "$_vm_dir/bin:$PATH" _vm_t_up >/dev/null && wc -l <"$_vm_dir/installs" | tr -d ' ')"
case "$(cat "$_vm_dir/runtimes")" in
    kib-gvisor-*) pass "the runtime is named for its pin, so a bump installs beside the old one" ;;
    *) fail "unexpected gVisor runtime name" "$(cat "$_vm_dir/runtimes")" ;;
esac
is "Linux: no bindfs, virtiofsd passes the real owners" "no" \
    "$([ -e "$_vm_dir/bindfs" ] && echo yes || echo no)"
_vm_t_owners() { KIB_OS=darwin && vm_up >/dev/null; }
_vm_run "$_vm_dir/bin:$PATH" _vm_t_owners
case "$(cat "$_vm_dir/bindfs" 2>/dev/null)" in
    *"ulimit -n 1048576"*--multithreaded*"$_vm_dir/home/.claude $_vm_dir/home/.local/state/kib") pass \
        "macOS: bindfs gives the VM your owners on ~/.claude and kib's state, nothing else" ;;
    *) fail "macOS: kib's bind sources lack bindfs" "$(cat "$_vm_dir/bindfs" 2>/dev/null)" ;;
esac
is "the box's resolv.conf is the VM's resolvers" "nameserver 192.168.5.3" \
    "$(_vm_run "$_vm_dir/bin:$PATH" _vm_t_resolv)"
case " $(tr '\n' ' ' <"$_vm_dir/shell-fds") " in
    *" 200 "* | *" 205 "* | *" 206 "*) fail "a VM root shell (whose ssh master outlives kib) inherited a lock fd" ;;
    *) pass "a VM root shell never inherits a lock fd" ;;
esac
is "a VM with an old mount set is re-mounted once, then left alone" "1" "$(_vm_edits)"
is "the re-mount starts the VM again, even when the edit changes nothing" "1" \
    "$(wc -l <"$_vm_dir/starts" | tr -d ' ')"
case "$(cat "$_vm_dir/edits")" in
    *--mount-type=virtiofs*) pass "the re-mount is virtiofs, never 9p or reverse-sshfs" ;;
    *) fail "the re-mount is not virtiofs" "$(cat "$_vm_dir/edits")" ;;
esac
_vm_spec="$_vm_dir/home/.local/state/kib/vm-spec"
mv "$_vm_spec" "$_vm_dir/spec" && echo stale >"$_vm_spec"
case "$(_vm_run "$_vm_dir/bin:$PATH" _vm_t_shared)" in
    *"other kib sessions use it"*) is "a stale mount set in use: refused, the VM untouched" "1" "$(_vm_edits)" ;;
    *) fail "a stale mount set in use was not refused" ;;
esac
mv "$_vm_dir/spec" "$_vm_spec"

rm -f "$_vm_dir/stops"
_vm_run "$_vm_dir/bin:$PATH" _vm_t_shared >/dev/null
is "the VM stays up while another kib holds it" "0" "$(_vm_stops)"
_vm_run "$_vm_dir/bin:$PATH" _vm_t_last >/dev/null
is "the last kib out leaves the VM up (it lingers)" "0" "$(_vm_stops)"
_vm_run "$_vm_dir/bin:$PATH" _vm_t_last >/dev/null # a second close within the linger
sleep 3
is "after the linger, only the newest close's timer stops the VM" "1" "$(_vm_stops)"
is "the idle stop updates Docker first, when no session's terminal can be cut" "1" \
    "$(wc -l <"$_vm_dir/upgrades" | tr -d ' ')"

_vm_t_mac() { KIB_OS=darwin && vm_use claude && echo returned; }
case "$(_vm_run /usr/bin:/bin _vm_t_mac)" in
    *"runs every box in a Lima VM"*) pass "macOS without Lima: refused, never a non-VM engine" ;;
    *) fail "macOS ran without Lima" ;;
esac
_vm_t_linux() { KIB_OS=linux && vm_use claude && echo returned; }
case "$(_vm_run /usr/bin:/bin _vm_t_linux)" in
    *returned) fail "Linux with nothing picked and no terminal ran anyway" ;;
    *"in a terminal for a menu"*"vm = off"*"vm = on"*) pass "nothing picked, no terminal: the config lines, then stop" ;;
    *) fail "nothing picked, no terminal: no way forward printed" ;;
esac

# No-VM mode: rootless Docker that already lists kib's gVisor runtime. The box is root inside.
_vm_rt="kib-gvisor-$(sed -n 's/^GVISOR_VERSION=//p' "$KIB_ROOT/host/vm.sh")"
mkdir -p "$_vm_dir/rl" "$_vm_dir/rf"
printf '#!/bin/sh\necho "name=rootless %s"\n' "$_vm_rt" >"$_vm_dir/rl/docker"
# Rootful: what it lists is in $_vm_dir/rf-runtimes. A fake sudo records any call: kib never may.
printf '#!/bin/sh\necho "name=seccomp $(cat %s/rf-runtimes 2>/dev/null)"\n' "$_vm_dir" >"$_vm_dir/rf/docker"
printf '#!/bin/sh\necho "$*" >>%s/sudo-calls\n' "$_vm_dir" >"$_vm_dir/rf/sudo"
chmod +x "$_vm_dir/rl/docker" "$_vm_dir/rf/docker" "$_vm_dir/rf/sudo"
_vm_t_rootless() { KIB_OS=$1 && KIB_CFG_VM=off && vm_use claude && echo "$(box_uid):$(box_gid) $(_vm_t_engine)"; }
is "vm = off: no VM, the box runs as root (this user outside)" "0:0 native" \
    "$(_vm_run "$_vm_dir/rl:$PATH" _vm_t_rootless linux | tail -1)"
case "$(_vm_run "$_vm_dir/rl:$PATH" _vm_t_rootless darwin)" in
    *"Linux only"*"Remove the  vm = off"*) pass "vm = off is refused on macOS, saying how to fix it" ;;
    *) fail "vm = off ran on macOS, or refused without the fix" ;;
esac
_vm_t_default() { KIB_OS=$1 && KIB_CFG_VM=$2 && engine_choice && echo "$ENGINE"; }
is "nothing set, Linux with rootless Docker: rootless gVisor, no menu" "rootless" \
    "$(_vm_run "$_vm_dir/rl:$PATH" _vm_t_default linux '' | tail -1)"
is "nothing set, Linux with only rootful Docker: the menu" "ask" \
    "$(_vm_run "$_vm_dir/rf:$PATH" _vm_t_default linux '' | tail -1)"
is "nothing set, macOS: the VM, rootless Docker or not" "vm" \
    "$(_vm_run "$_vm_dir/rl:$PATH" _vm_t_default darwin '' | tail -1)"
is "vm = on keeps the VM on Linux with rootless Docker" "vm" \
    "$(_vm_run "$_vm_dir/rl:$PATH" _vm_t_default linux on | tail -1)"
_vm_t_norootless() { KIB_OS=linux && KIB_CFG_VM=off && vm_use claude && echo returned; }
case "$(_vm_run /usr/bin:/bin _vm_t_norootless)" in
    *returned) fail "vm = off without rootless Docker fell back to something" ;;
    *"kib never runs"*"dockerd-rootless-setuptool.sh install"*) pass "vm = off, no Docker: the rootless steps, then stop" ;;
    *) fail "vm = off, no Docker: stopped without the steps" ;;
esac

# Rootful Docker: steps until gVisor and user_allow_other are in, then gVisor as this user.
_vm_t_rootful() { KIB_OS=linux && KIB_CFG_VM=off && FUSE_CONF="$_vm_dir/fuse.conf" && vm_use claude \
    && echo "returned $(engine_rootful && echo rootful) $(box_uid)"; }
case "$(_vm_run "$_vm_dir/rf:$PATH" _vm_t_rootful)" in
    *returned*) fail "rootful Docker without gVisor ran a box" ;;
    *"kib never runs"*"sudo /opt/kib-gvisor/"*"runsc install --runtime=$_vm_rt"*"sudo systemctl reload docker"*)
        pass "rootful Docker without gVisor: the sudo steps, then stop"
        ;;
    *) fail "rootful Docker without gVisor: no usable steps" ;;
esac
is "kib ran no sudo of its own" "absent" "$([ -e "$_vm_dir/sudo-calls" ] && echo ran || echo absent)"
echo "$_vm_rt" >"$_vm_dir/rf-runtimes" && echo user_allow_other >"$_vm_dir/fuse.conf"
_vm_rf_out="$(_vm_run "$_vm_dir/rf:$PATH" _vm_t_rootful)"
is "rootful Docker with gVisor: no VM, the box runs as this user" "returned rootful $(id -u)" \
    "$(printf '%s\n' "$_vm_rf_out" | tail -1)"
case "$_vm_rf_out" in
    *"Rootless Docker is safer"*docs.docker.com/engine/security/rootless*) pass "rootful: a short note that rootless is safer, with its docs" ;;
    *) fail "rootful: no note pointing at rootless Docker" ;;
esac

# docker = rootful reaches the system socket even when the shell's docker is rootless.
python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$_vm_dir/sys.sock"
mkdir -p "$_vm_dir/both"
printf '#!/bin/sh\ncase "$DOCKER_HOST" in *sys.sock) echo "name=seccomp %s" ;; *) echo name=rootless ;; esac\n' \
    "$_vm_rt" >"$_vm_dir/both/docker" && chmod +x "$_vm_dir/both/docker"
_vm_t_pinned() { KIB_OS=linux && KIB_CFG_DOCKER=rootful && ROOTFUL_SOCK="$_vm_dir/sys.sock" \
    && engine_choice && echo "$ENGINE $(_docker_kind)"; }
is "docker = rootful aims at the system socket past a rootless default" "rootful rootful" \
    "$(_vm_run "$_vm_dir/both:$PATH" _vm_t_pinned | tail -1)"
_vm_t_both_menu() { KIB_OS=linux && ROOTFUL_SOCK="$_vm_dir/sys.sock" FUSE_CONF="$_vm_dir/fuse.conf" \
    && _prefer_rootless_socket && _menu_rows && echo "${MENU_T[1]}"; }
is "menu: a set-up rootful Docker starts now while the shell points at rootless" "starts now" \
    "$(_vm_run "$_vm_dir/both:$PATH" _vm_t_both_menu | tail -1)"

_vm_t_menu() { _menu_rows && _menu_pick 2>/dev/null < <(printf '%b' "$1") && echo "$MENU_PICK"; }
is "menu: ↓ ↓ Enter picks the VM" "2" "$(_vm_run /usr/bin:/bin _vm_t_menu '\033[B\033[B\n' | tail -1)"
is "menu: ↑ at the top stays on rootless" "0" "$(_vm_run /usr/bin:/bin _vm_t_menu '\033[A\n' | tail -1)"
is "menu: a row's number, then Enter" "1" "$(_vm_run /usr/bin:/bin _vm_t_menu '2\n' | tail -1)"
_vm_t_save() {
    mkdir -p "${KIB_CONFIG%/*}" && printf 'engine = rootless\nbroker = off\n' >"$KIB_CONFIG"
    _save_engine on 2>/dev/null && tr '\n' ' ' <"$KIB_CONFIG"
}
is "the pick replaces old engine lines and keeps the rest" "broker = off vm = on " \
    "$(_vm_run /usr/bin:/bin _vm_t_save | tail -1)"

_vm_t_build() { KIB_OS=darwin && VM_LINGER=1 && vm_use build >/dev/null 2>&1 && echo built; }
case "$(_vm_run "$_vm_dir/bin:$PATH" _vm_t_build)" in
    *built*"VM stops in"*) pass "kib build arms the VM's stop timer at exit, as a session does" ;;
    *) fail "kib build left the VM running with no stop timer" ;;
esac
sleep 2 # its 1 s timer, before the files go

# The fake VM has 4 GiB; <host RAM in GiB>. Another kib holds the VM, so no stop timer.
_vm_t_oom() {
    # shellcheck disable=SC2317 # _vm_oom calls it
    _mem=$1 && host_mem_kib() { echo $((_mem << 20)); }
    exec 207>"$VM_LOCK" && flock -s 207 && vm_up >/dev/null 2>&1 && vm_down
}
_vm_grow="$_vm_dir/home/.local/state/kib/vm-memory"
rm -f "$_vm_dir/edits"
is "no out-of-memory kill: nothing said, the size kept" "" \
    "$(_vm_run "$_vm_dir/bin:$PATH" _vm_t_oom 64)$(cat "$_vm_grow" 2>/dev/null)"
touch "$_vm_dir/oom"
case "$(_vm_run "$_vm_dir/bin:$PATH" _vm_t_oom 64)" in
    *"out of memory (4 GiB)"*"gets 8 GiB from its next start"*"--memory 32") pass \
        "an out-of-memory kill: told, with the command for more" ;;
    *) fail "an out-of-memory kill went unreported" ;;
esac
is "said once per boot" "" "$(_vm_run "$_vm_dir/bin:$PATH" _vm_t_oom 64)"
echo Stopped >"$_vm_dir/status" && rm -f "$_vm_dir/zram"
_vm_run "$_vm_dir/bin:$PATH" _vm_t_up >/dev/null
case "$(cat "$_vm_dir/edits" 2>/dev/null)" in
    *"--memory 8 kib-vm") pass "the next start from stopped doubles the VM's memory" ;;
    *) fail "the VM did not grow at its next start" "$(cat "$_vm_dir/edits" 2>/dev/null)" ;;
esac
is "then the plan is spent" "no" "$([ -e "$_vm_grow" ] && echo yes || echo no)"
is "a boot turns on compressed swap, a running VM is left alone" "zram" "$(cat "$_vm_dir/zram")"
is "a VM on containerd storage moves to classic once, however often it boots" "moved" \
    "$(cat "$_vm_dir/classic" 2>/dev/null)"
rm -f "$_vm_dir/status"
_vm_run "$_vm_dir/bin:$PATH" _vm_t_oom 4 >/dev/null
is "never past half the host's RAM, and never below a size set by hand" "4" "$(cat "$_vm_grow")"

_vm_t_lima() { # <answer> — the install prompt's outcome and any limactl it left
    printf '%s\n' "$1" | _vm_install " limactl docker" 2>&3 && echo installed || echo declined
    [ ! -e "$HOME/.local/bin/limactl" ] || echo limactl
}
mkdir -p "$_vm_dir/curl"
printf '#!/bin/sh\nwhile [ "$1" != -o ]; do shift; done; echo junk >"$2"\n' >"$_vm_dir/curl/curl"
chmod +x "$_vm_dir/curl/curl"
is "VM tools prompt: n declines" "declined" "$(_vm_run /usr/bin:/bin _vm_t_lima n 3>/dev/null)"
case "$(_vm_run "$_vm_dir/curl:/usr/bin:/bin" _vm_t_lima y 3>&1)" in
    *"failed its checksum"*declined) pass "VM tools prompt: a download off its pinned checksum installs nothing" ;;
    *) fail "a download off its checksum was installed or not refused" ;;
esac

_vm_t_notes() { _KIB_NOTES='' && warn one two && note three && printf '%s' "$_KIB_NOTES" >&3; }
is "launch notices are kept for the replay after the session" "⚠️  kib: one
   two
three" "$(_vm_run "$PATH" _vm_t_notes 3>&1 >/dev/null)"

# Disk cleanup with a fake docker (no VM): "old" was closed long ago, "new" was never stamped.
mkdir -p "$_vm_dir/dc"
cat >"$_vm_dir/dc/docker" <<EOF
#!/bin/sh
case "\$1 \$2" in
    "volume ls") printf '%s\n' kib-old-aaaaaaaa-cache kib-old-aaaaaaaa-local-dba27c31 \
        kib-new-bbbbbbbb-cache kib-fresh-cccccccc-cache other ;;
    "volume rm") shift 2 && echo "\$*" >>"$_vm_dir/dc/rm" ;;
    *) printf 'Total reclaimed space: \033[0Kc1.5GB\n' ;; # a stray byte before the size, as seen
esac
EOF
chmod +x "$_vm_dir/dc/docker"
_vm_t_clean() {
    CNAME=kib-proj-12345678 && mkdir -p "$KIB_USED"
    touch -t 202001010000 "$KIB_USED/kib-old-aaaaaaaa" && touch "$KIB_USED/kib-fresh-cccccccc"
    disk_cleanup && disk_cleanup && ls "$KIB_USED"
}
_vm_case="$(_vm_run "$_vm_dir/dc:$PATH" _vm_t_clean)"
is "a project closed over cleanup_days loses every volume; none other does" \
    "kib-old-aaaaaaaa-cache kib-old-aaaaaaaa-local-dba27c31" "$(cat "$_vm_dir/dc/rm")"
case "$_vm_case" in
    *"daily disk cleanup"*"daily disk cleanup"*) fail "the disk cleanup ran twice in a day" ;;
    *"1.5GB freed"*"unused projects     old (closed over 14 days)"*kib-fresh-cccccccc*kib-new-bbbbbbbb*kib-proj-12345678)
        pass "disk cleanup: once a day, says what it freed; a first-seen project starts its clock"
        ;;
    *) fail "disk cleanup output or stamps are wrong" "$_vm_case" ;;
esac

rm -rf "$_vm_dir"
unset _vm_dir _vm_spec _vm_grow _vm_h _vm_tag _vm_sid _vm_case _vm_want
