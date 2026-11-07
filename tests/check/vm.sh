#!/usr/bin/env bash
# Sourced by tests/check.sh — host/vm.sh's mounts, gVisor and VM lifetime, with a fake limactl.
# shellcheck disable=SC2030,SC2031,SC2034  # _vm_run sets PATH and launch state in a subshell
# shellcheck disable=SC2016  # the fakes expand their own $*

# shellcheck source=SCRIPTDIR/_guard.sh
. "${BASH_SOURCE%/*}/_guard.sh" # sourced by tests/check.sh, never run directly

section "Lima VM engine (host/vm.sh)"

_vm_dir="$(mktemp -d)"
mkdir -p "$_vm_dir/bin" "$_vm_dir/home/devel/proj" "$_vm_dir/lima"
# Fake limactl: an existing, running VM; stops, edits and root shells are logged. A root shell
# that runs `runsc install` registers the runtime it names (its last argument) with fake docker.
cat >"$_vm_dir/bin/limactl" <<EOF
#!/usr/bin/env bash
case "\$1" in
    list) case "\$3" in *Dir*) echo "$_vm_dir/lima" ;; *) echo Running ;; esac ;;
    stop) echo stop >>"$_vm_dir/stops" ;;
    edit) echo "\$*" >>"$_vm_dir/edits" ;;
    start) echo start >>"$_vm_dir/starts" ;;
    shell)
        ls /proc/\$\$/fd >>"$_vm_dir/shell-fds"
        case "\$*" in
            *"runsc install"*) echo "\${@: -1}" >>"$_vm_dir/runtimes" && echo gvisor >>"$_vm_dir/installs" ;;
            *nameserver*) echo "nameserver 192.168.5.3" ;;
            *bindfs*) echo "\$*" >>"$_vm_dir/bindfs" ;;
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
_vm_t_resolv() { vm_resolv "$_vm_dir/resolv" && cat "$_vm_dir/resolv"; }
_vm_t_outside() { cd /tmp && vm_project_ok && echo allowed; }

_vm_run() { ( # <PATH> <cmd…> — a fresh subshell with the units loaded, HOME and state faked
    export HOME="$_vm_dir/home" KIB_STATE_ROOT="$_vm_dir/home/.local/state/kib"
    export KIB_CONFIG="$_vm_dir/home/.keep-it-in-your-box/config" KIB_NODE_CACHE="$_vm_dir/node"
    PATH="$1"
    unset KIB_PORTABLE_SOURCED # a fresh load, as bin/kib does
    shift
    # shellcheck source=/dev/null
    . "$KIB_ROOT/host/core.sh" && . "$KIB_ROOT/host/portable.sh" && . "$KIB_ROOT/host/vm.sh"
    cd "$HOME/devel/proj" && "$@"
) 2>&1 </dev/null; }

is "an inherited _KIB_ENGINE_VM=1 is ignored" "native" "$(_KIB_ENGINE_VM=1 _vm_run "$PATH" _vm_t_engine)"
is "the VM mounts ~ rw; outside it, only kib's checkout (read-only) and its own dirs" \
    "--mount-only $_vm_dir/home:w --mount-only $KIB_ROOT --mount-only $_vm_dir/node:w" \
    "$(_vm_run "$PATH" _vm_t_mounts | tr '\n' ' ' | sed 's/ $//')"
case "$(_vm_run "$PATH" _vm_t_outside)" in
    *"outside $_vm_dir/home"*) pass "a project outside ~ is refused: the VM cannot see it" ;;
    *) fail "a project outside ~ was not refused" ;;
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

_vm_t_mac() { KIB_OS=darwin && vm_use claude && echo returned; }
case "$(_vm_run /usr/bin:/bin _vm_t_mac)" in
    *"runs every box in a Lima VM"*) pass "macOS without Lima: refused, never a non-VM engine" ;;
    *) fail "macOS ran without Lima" ;;
esac
_vm_t_linux() { KIB_OS=linux && vm_use claude && echo returned; }
case "$(_vm_run /usr/bin:/bin _vm_t_linux)" in
    *docs/vm.md*returned) fail "Linux without the VM's prerequisites ran natively" ;;
    *docs/vm.md*) pass "Linux without QEMU/KVM/virtiofsd: refused, naming docs/vm.md" ;;
    *) fail "Linux without the VM's prerequisites is not refused" ;;
esac

_vm_t_build() { KIB_OS=darwin && VM_LINGER=1 && vm_use build >/dev/null 2>&1 && echo built; }
case "$(_vm_run "$_vm_dir/bin:$PATH" _vm_t_build)" in
    *built*"VM stops in"*) pass "kib build arms the VM's stop timer at exit, as a session does" ;;
    *) fail "kib build left the VM running with no stop timer" ;;
esac
sleep 2 # its 1 s timer, before the files go

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

rm -rf "$_vm_dir"
unset _vm_dir _vm_spec
