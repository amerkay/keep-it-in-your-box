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
        esac
        ;;
esac
EOF
# Fake docker: one running box, whose project is ~/other/app; stops are logged.
cat >"$_vm_dir/bin/docker" <<EOF
#!/usr/bin/env bash
case "\$1" in
    info) cat "$_vm_dir/runtimes" 2>/dev/null ;;
    ps) echo box1 ;;
    inspect) echo "$_vm_dir/home/other/app" ;;
    stop) echo stop >>"$_vm_dir/dstops" ;;
esac
EOF
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
_vm_t_root() { cd "$1" && vm_project_ok && echo "${VM_NEW_ROOT:-none}"; }
_vm_t_evict() { VM_EVICT_WAIT=1 && _vm_t_shared; }
# Another kib holds the VM for a second, then closes: the restart waits it out.
_vm_t_released() {
    (exec 207>"$VM_LOCK" && flock -s 207 && sleep 1) &
    sleep 0.3
    VM_EVICT_WAIT=5 && vm_project_ok && vm_up >/dev/null 2>&1 && cat "$VM_ROOTS"
    [ ! -e "$VM_RESTART" ] || echo "marker left"
    wait
}

_vm_run() { ( # <PATH> <cmd…> — a fresh subshell with the units loaded, HOME and state faked
    export HOME="$_vm_dir/home" KIB_STATE_ROOT="$_vm_dir/home/.local/state/kib"
    export KIB_CONFIG="$_vm_dir/home/.keep-it-in-your-box/config" KIB_NODE_CACHE="$_vm_dir/node"
    PATH="$1"
    unset KIB_PORTABLE_SOURCED # a fresh load, as bin/kib does
    shift
    # shellcheck source=/dev/null
    . "$KIB_ROOT/host/core.sh" && . "$KIB_ROOT/host/portable.sh" && . "$KIB_ROOT/host/gitguard.sh"
    . "$KIB_ROOT/host/session-state.sh" && . "$KIB_ROOT/host/vm.sh"
    cd "$HOME/devel/proj" && "$@"
) 2>&1 </dev/null; }

is "an inherited _KIB_ENGINE_VM=1 is ignored" "native" "$(_KIB_ENGINE_VM=1 _vm_run "$PATH" _vm_t_engine)"
_vm_h="$_vm_dir/home"
is "the VM never mounts ~: ~/.claude, kib's own dirs, its checkout read-only" \
    "--mount-only $_vm_h/.claude:w --mount-only $_vm_h/.local/state/kib:w --mount-only $_vm_dir/node:w --mount-only $KIB_ROOT" \
    "$(_vm_run "$PATH" _vm_t_mounts | tr '\n' ' ' | sed 's/ $//')"
is "a project shares itself, never its siblings" "$_vm_h/devel/proj" \
    "$(_vm_run "$PATH" _vm_t_root "$_vm_h/devel/proj")"
mkdir -p "$_vm_dir/srv/app"
is "a project outside ~ works too" "$_vm_dir/srv/app" "$(_vm_run "$PATH" _vm_t_root "$_vm_dir/srv/app")"
case "$(_vm_run "$PATH" _vm_t_root "$_vm_h")$(_vm_run "$PATH" _vm_t_root "$_vm_dir")" in
    *"won't share $_vm_h"*"won't share $_vm_dir"*) pass "~, and a folder holding it, are never shared" ;;
    *) fail "~ or a folder holding it was shared" ;;
esac
git init -q "$_vm_h"
is "a home folder that is a git repo is never shared" "$_vm_h/devel/proj" \
    "$(_vm_run "$PATH" _vm_t_root "$_vm_h/devel/proj")"
rm -rf "$_vm_h/.git"
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
_vm_tag="$_vm_h/.local/state/kib/.state/-p.sleep/kib-$$-1"
mkdir -p "$_vm_tag" && touch "$_vm_tag/live" "$_vm_tag/turn"
mv "$_vm_spec" "$_vm_dir/spec" && echo stale >"$_vm_spec"
case "$(_vm_run "$_vm_dir/bin:$PATH" _vm_t_evict)" in
    *"1 of its sessions are mid-work"*"left the VM as it is"*) is \
        "a restart with a session mid-work and nobody to say y: refused, nothing stopped" \
        "1 no" "$(_vm_edits) $([ -e "$_vm_dir/dstops" ] && echo yes || echo no)" ;;
    *) fail "a restart under a session mid-work was not asked" ;;
esac
rm "$_vm_tag/turn"
case "$(_vm_run "$_vm_dir/bin:$PATH" _vm_t_evict)" in
    *"1 idle session(s) resume after"*"still use the VM after 1 s"*) is \
        "all idle: no question, the boxes stop, the VM waits for their kibs" "1" "$(_vm_edits)" ;;
    *) fail "a restart under idle sessions did not go ahead" ;;
esac
is "the restart stops every box" "1" "$(wc -l <"$_vm_dir/dstops" | tr -d ' ')"
is "a running box's project and the new one stay shared; the restart's marker is gone" \
    "$_vm_h/devel/proj $_vm_h/other/app" "$(_vm_run "$_vm_dir/bin:$PATH" _vm_t_released | tr '\n' ' ' | sed 's/ $//')"
is "then the VM is re-mounted with them" "2" "$(_vm_edits)"
is "a project opened before needs no restart" "none" "$(_vm_run "$PATH" _vm_t_root "$_vm_h/devel/proj")"
rm -rf "$_vm_tag" "$_vm_spec" && mv "$_vm_dir/spec" "$_vm_spec"
_vm_run "$_vm_dir/bin:$PATH" _vm_t_up >/dev/null # back to the plain mount set

# A session cut by another kib's restart: no stop timer, and it comes back as itself.
_vm_t_cut() { # <sid marker name>
    VERB=claude CMD=(claude --dangerously-skip-permissions --model opus "fix it")
    SLEEP_STATE="$_vm_dir/sl" SESSION_TAG=t && mkdir -p "$SLEEP_STATE/t" && touch "$SLEEP_STATE/t/$1"
    exec 207>"$VM_LOCK" && flock -s 207 && vm_up >/dev/null 2>&1 && echo "$$" >"$VM_RESTART"
    vm_down && echo "resume=$_VM_RESUME"
    KIB_ROOT="$_vm_dir/fake" && vm_resume
}
mkdir -p "$_vm_dir/fake/bin" && printf '#!/bin/sh\necho "relaunched: $*"\n' >"$_vm_dir/fake/bin/kib"
chmod +x "$_vm_dir/fake/bin/kib"
_vm_sid=0123abcd-0000-4000-8000-0123456789ab
case "$(_vm_run "$_vm_dir/bin:$PATH" _vm_t_cut "sid.$_vm_sid")" in
    *"resume=$_vm_sid"*"resumes after it"*"relaunched: claude --model opus --resume $_vm_sid") pass \
        "a session cut by a restart relaunches itself with --resume, no stop timer" ;;
    *) fail "a cut session did not resume itself" "$(_vm_run "$_vm_dir/bin:$PATH" _vm_t_cut "sid.$_vm_sid")" ;;
esac
case "$(_vm_run "$_vm_dir/bin:$PATH" _vm_t_cut none)" in
    *"resume=-"*"ended this session"*relaunched*) fail "a session with no id relaunched blind" ;;
    *"resume=-"*"ended this session"*) pass "a session with no id is told, not relaunched" ;;
    *) fail "a cut session with no id was not told" ;;
esac
rm -f "$_vm_dir/home/.local/state/kib/vm-restart"

_vm_t_args() { _vm_resume_args "$@" && local IFS='|' && echo "${RESUME_ARGS[*]+"${RESUME_ARGS[*]}"}"; }
for _vm_case in \
    "a prompt is never sent again|--model|opus|--model opus fix-it" \
    "a session pick is dropped, many-valued flags kept whole|--add-dir|a|b|--verbose|-r abc --add-dir a b --verbose" \
    "print and continue are dropped||-c -p hi" \
    "an unknown flag before a word: both dropped||--frob val" \
    "an unknown flag alone, and flag=value, are kept|--frob|--model=x|--frob --model=x fix-it" \
    "everything after -- is a prompt|--effort|high|--effort high -- --model x"; do
    _vm_want="${_vm_case#*|}" && _vm_want="${_vm_want%|*}"
    # shellcheck disable=SC2086 # the case's words
    is "relaunch flags: ${_vm_case%%|*}" "$_vm_want" "$(_vm_run "$PATH" _vm_t_args ${_vm_case##*|})"
done

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

rm -rf "$_vm_dir"
unset _vm_dir _vm_spec _vm_grow _vm_h _vm_tag _vm_sid _vm_case _vm_want
