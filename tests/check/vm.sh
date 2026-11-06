#!/usr/bin/env bash
# Sourced by tests/check.sh — host/vm.sh's mounts, engine switch and VM lifetime, with a fake limactl.
# shellcheck disable=SC2030,SC2031,SC2034  # _vm_run sets PATH and launch state in a subshell
# shellcheck disable=SC2016  # the fakes expand their own $*

# shellcheck source=SCRIPTDIR/_guard.sh
. "${BASH_SOURCE%/*}/_guard.sh" # sourced by tests/check.sh, never run directly

section "Lima VM engine (host/vm.sh)"

_vm_dir="$(mktemp -d)"
mkdir -p "$_vm_dir/bin" "$_vm_dir/home/devel/proj" "$_vm_dir/lima"
# Fake limactl: an existing, running VM; stops and edits are logged so lifetime can be asserted.
cat >"$_vm_dir/bin/limactl" <<EOF
#!/usr/bin/env bash
case "\$1" in
    list) case "\$3" in *Dir*) echo "$_vm_dir/lima" ;; *) echo Running ;; esac ;;
    stop) echo stop >>"$_vm_dir/stops" ;;
    edit) echo "\$*" >>"$_vm_dir/edits" ;;
    start) echo start >>"$_vm_dir/starts" ;;
esac
EOF
# Fake docker and mutagen log every call; MG_FLUSH sets whether a flush succeeds.
for _c in docker mutagen; do
    printf '#!/usr/bin/env bash\necho "%s $*" >>"%s/calls"\n' "$_c" "$_vm_dir" >"$_vm_dir/bin/$_c"
done
echo 'ls /proc/$$/fd >>"'"$_vm_dir"'/mg-fds"' >>"$_vm_dir/bin/mutagen"
echo 'case "$*" in *"sync flush"*-host) exit "${MG_FLUSH_HOST:-0}" ;; *"sync flush"*) exit "${MG_FLUSH:-0}" ;; *"sync list"*) exit "${MG_LIST:-0}" ;; esac' >>"$_vm_dir/bin/mutagen"
echo 'case "$1" in start) exit "${DK_START:-0}" ;; esac' >>"$_vm_dir/bin/docker"
chmod +x "$_vm_dir/bin/"*

# Subshells inherit these; a `sh -c` would not see the sourced functions.
_vm_t_mounts() { _vm_mounts && printf '%s\n' "${VM_MOUNTS[@]}"; }
_vm_t_up() { vm_use claude && printf '%s %s %s\n' "$DOCKER_HOST" "$(engine_lima && echo vm)" \
    "$KIB_HOST_GATEWAY"; }
_vm_edits() { if [ -f "$_vm_dir/edits" ]; then wc -l <"$_vm_dir/edits" | tr -d ' '; else echo 0; fi; }
_vm_t_last() { VM_LINGER=1 && vm_up && vm_down; }
_vm_stops() { if [ -f "$_vm_dir/stops" ]; then wc -l <"$_vm_dir/stops" | tr -d ' '; else echo 0; fi; }
_vm_t_engine() { if engine_lima; then echo vm; else echo native; fi; }
_vm_t_returns() {
    vm_use claude
    echo returned
}
_vm_t_sync() { # [stop] — the sync of a project named "proj", with the state a launch stages
    CNAME=kib-proj-1 SYNC_CNAME=kib-proj-1-sync IMAGE_NAME=img KIB_BOX_UID=1000 KIB_BOX_GID=1000
    PATTERNS_STATE="$_vm_dir/pat" _KIB_ENGINE_VM=1
    KIB_GUARD_FILE_HOST="$KIB_ROOT/guest/policy/global.kibignore"
    printf '.secret\n' >"$PATTERNS_STATE"
    exec 200>"$_vm_dir/l200" 205>"$_vm_dir/l205" # held by a real launch
    if [ -n "${1:-}" ]; then vm_sync_stop; else vm_sync_start; fi
}
_vm_t_state() { # in, then out: where a project's state sits each time
    SLUG=-p CLAUDE_HOME="$HOME/.claude" VM_RW="$_vm_dir/vm-rw"
    mkdir -p "$KIB_STATE_ROOT/-p/session" "$CLAUDE_HOME/projects/-p" "$VM_RW"
    echo t >"$CLAUDE_HOME/projects/-p/t.jsonl"
    vm_state in && ls "$VM_RW/-p" && cat "$CLAUDE_HOME/projects/-p/t.jsonl"
    vm_state out && ls -A "$VM_RW" && echo : && ls "$KIB_STATE_ROOT/-p" "$CLAUDE_HOME/projects/-p"
    [ -L "$CLAUDE_HOME/projects/-p" ] || echo real
}
_vm_t_paths() { # every per-project path a VM launch names, one per line
    . "$KIB_ROOT/host/config.sh" && . "$KIB_ROOT/host/lifecycle.sh" && _KIB_ENGINE_VM=1
    kib_resolve_paths && kib_identity
    printf 'rw %s\n' "$SESSION_BASE" "$SHARED_BASE" "$TRANSCRIPTS_SRC" "$SLEEP_STATE" \
        "$CLIP_STATE" "$BROKER_OUT"
    printf 'ro %s\n' "$PATTERNS_STATE" "$PASSWD_STATE" "$CRED_WITNESS" "$BROKER_DIR" "$CLIP_HOST"
}
_vm_t_shared() { exec 207>"$VM_LOCK" && flock -s 207 && vm_up && vm_down; }

_vm_run() { ( # <PATH> <cmd…> — a fresh subshell with the units loaded, HOME and state faked
    export HOME="$_vm_dir/home" KIB_STATE_ROOT="$_vm_dir/state" KIB_VM="${KIB_VM-on}"
    export XDG_STATE_HOME="$_vm_dir/state-xdg"
    export KIB_CONFIG="$_vm_dir/home/.keep-it-in-your-box/config" KIB_NODE_CACHE="$_vm_dir/node"
    PATH="$1"
    unset KIB_PORTABLE_SOURCED # a fresh load, as bin/kib does
    shift
    # shellcheck source=/dev/null
    . "$KIB_ROOT/host/core.sh" && . "$KIB_ROOT/host/portable.sh" && . "$KIB_ROOT/host/vm.sh"
    cd "$HOME/devel/proj" && "$@"
) 2>&1 </dev/null; }

is "VM mode is opt-in: off without vm = on" "returned" "$(KIB_VM='' _vm_run "$_vm_dir/bin:$PATH" _vm_t_returns | tail -1)"
case "$(KIB_VM='' DOCKER_HOST="unix://$_vm_dir/.lima/kib-vm/sock/docker.sock" _vm_run "$PATH" _vm_t_returns 2>&1)" in
    *"unset DOCKER_HOST"*) pass "VM off but DOCKER_HOST aims at kib-vm: refused with the fix" ;;
    *) fail "a leftover DOCKER_HOST at kib-vm was not caught" ;;
esac
is "an inherited _KIB_ENGINE_VM=1 is ignored" "native" "$(_KIB_ENGINE_VM=1 _vm_run "$PATH" _vm_t_engine)"
_vm_m="$(_vm_run "$PATH" _vm_t_mounts)"
case "$_vm_m" in
    *"$KIB_ROOT"$'\n'*"$_vm_dir/node:w"*"/.claude/skills:w"*"/.claude/hooks:w"*)
        pass "kib read-only, the node cache and the shared ~/.claude trees rw"
        ;;
    *) fail "unexpected VM mounts" "$_vm_m" ;;
esac
case "$_vm_m" in
    *"/devel"* | *"$_vm_dir/home"$'\n'* | *"$_vm_dir/home:w"* | *.ssh*) fail "a user dir is mounted" "$_vm_m" ;;
    *) pass "no project, no \$HOME, no ~/.ssh in the VM's mounts" ;;
esac
case "$_vm_m" in
    *"/.claude"$'\n'* | *"/.claude:w"$'\n'* | *.credentials*) fail "all of ~/.claude is exposed to the VM" ;;
    *) pass "the .claude dir itself (credential, settings, CLAUDE.md) stays off the VM" ;;
esac

case "$_vm_m" in
    *"$_vm_dir/state/vm-rw:w"$'\n'--mount-only$'\n'"$_vm_dir/state/vm-ro"$'\n'*) pass "kib's state reaches the VM as vm-rw, and vm-ro read-only" ;;
    *) fail "kib's state is not mounted as vm-rw + read-only vm-ro" "$_vm_m" ;;
esac
case "$_vm_m" in
    *"$_vm_dir/state:w"* | *"/.claude/projects"* | *.keep-it-in-your-box*)
        fail "kib's whole state, every transcript or the token store is in the VM" "$_vm_m"
        ;;
    *) pass "no other project's state or transcripts, and no token store, in the VM" ;;
esac
_vm_out="$(_vm_run "$PATH" _vm_t_paths)"
is "the box's files are on vm-rw; pidfiles, witness, rules and tokens on vm-ro" "6 5" \
    "$(grep -c "^rw $_vm_dir/state/vm-rw/" <<<"$_vm_out") $(grep -c "^ro $_vm_dir/state/vm-ro/" <<<"$_vm_out")"
_vm_out="$(_vm_run "$PATH" _vm_t_state | tr '\n' ' ')"
is "open: session + transcripts onto vm-rw; close: back, and canonical a real dir again" \
    "session transcripts t : $_vm_dir/home/.claude/projects/-p: t.jsonl  $_vm_dir/state/-p: session real " \
    "$_vm_out"
is "the docker engine moves into the VM; kib stays here" \
    "unix://$_vm_dir/lima/sock/docker.sock vm 192.168.5.2" "$(_vm_run "$_vm_dir/bin:$PATH" _vm_t_up | tail -1)"
is "a VM with an old mount set is re-mounted once, then left alone" "1" \
    "$(_vm_run "$_vm_dir/bin:$PATH" _vm_t_up >/dev/null && _vm_edits)"
is "the re-mount starts the VM again, even when the edit changes nothing" "1" \
    "$(wc -l <"$_vm_dir/starts" | tr -d ' ')"
case "$(cat "$_vm_dir/edits")" in
    *--mount-type=9p*'--set=.mounts[]."9p".cache = "none"'*)
        pass "the re-mount pins 9p uncached, never reverse-sshfs"
        ;;
    *) fail "the re-mount did not pin 9p uncached" "$(cat "$_vm_dir/edits")" ;;
esac
mv "$_vm_dir/state/vm-spec" "$_vm_dir/spec" && echo stale >"$_vm_dir/state/vm-spec"
case "$(_vm_run "$_vm_dir/bin:$PATH" _vm_t_shared)" in
    *"other kib sessions use it"*) is "a stale mount set in use: refused, the VM untouched" "1" "$(_vm_edits)" ;;
    *) fail "a stale mount set in use was not refused" ;;
esac
mv "$_vm_dir/spec" "$_vm_dir/state/vm-spec"

rm -f "$_vm_dir/stops"
_vm_run "$_vm_dir/bin:$PATH" _vm_t_shared >/dev/null
is "the VM stays up while another kib holds it" "0" "$(_vm_stops)"
_vm_run "$_vm_dir/bin:$PATH" _vm_t_last >/dev/null
is "the last kib out leaves the VM up (it lingers)" "0" "$(_vm_stops)"
_vm_run "$_vm_dir/bin:$PATH" _vm_t_last >/dev/null # a second close within the linger
sleep 3
is "after the linger, only the newest close's timer stops the VM" "1" "$(_vm_stops)"

rm -f "$_vm_dir/calls"
printf 'K=v\n' >"$_vm_dir/home/devel/proj/.secret"
_vm_run "$_vm_dir/bin:$PATH" _vm_t_sync >/dev/null
_vm_c="$(cat "$_vm_dir/calls")"
case "$_vm_c" in
    *"docker run -d --name kib-proj-1-sync --network none --cap-drop=ALL --cap-add=CHOWN"*"kib-proj-1-src:/src"*)
        pass "sync endpoint: capless but CHOWN, no network, holding only the project's volume"
        ;;
    *) fail "the sync container is not locked down" "$_vm_c" ;;
esac
is "the sync container binds its volume and no host path" "1" \
    "$(grep 'docker run -d --name kib-proj-1-sync' "$_vm_dir/calls" | grep -o ' -v ' | wc -l | tr -d ' ')"
_vm_sh="$_vm_dir/state-xdg/kib-shadow/kib-proj-1"
case "$_vm_c" in
    *"sync create --name kib-proj-1-host"*"-c $_vm_dir/pat.sync.yml $_vm_dir/home/devel/proj $_vm_sh"*"sync flush kib-proj-1-host"*"sync create --name kib-proj-1 "*"-c $_vm_dir/pat.sync.yml.vm $_vm_sh docker://kib-proj-1-sync/src"*"sync flush kib-proj-1"*)
        pass "project ⇄ host-local shadow ⇄ VM, host wins, and the launch waits for both"
        ;;
    *) fail "unexpected Mutagen sessions" "$_vm_c" ;;
esac
is "the VM's Mutagen agent never touches the project itself" "0" \
    "$(grep -c "devel/proj docker://" "$_vm_dir/calls")"
case "$(cat "$_vm_dir/pat.sync.yml")" in
    *'"node_modules"'*'".env"'*'".secret"'*'"**/.git/**/hooks"'*) pass "the host hop drops build dirs, the guard and .kibignore" ;;
    *) fail "the host hop's ignores miss a tier" "$(cat "$_vm_dir/pat.sync.yml")" ;;
esac
case "$(cat "$_vm_dir/pat.sync.yml.vm")" in
    *'"node_modules"'*) case "$(cat "$_vm_dir/pat.sync.yml.vm")" in
        *.env* | *hooks*) fail "the VM hop drops the seeded stand-ins" ;;
        *) pass "the VM hop drops only build dirs, so the seeded stand-ins reach the box" ;;
    esac ;;
    *) fail "the VM hop syncs build dirs" "$(cat "$_vm_dir/pat.sync.yml.vm")" ;;
esac
is "the stand-ins are seeded into the shadow, values redacted" "K=<redacted>" "$(cat "$_vm_sh/.secret")"
is "the shadow is private" "$_vm_sh" "$(find "$_vm_sh" -maxdepth 0 -perm 700)"
case " $(tr '\n' ' ' <"$_vm_dir/mg-fds") " in
    *" 200 "* | *" 205 "*) fail "Mutagen (whose daemon outlives kib) inherited a lock fd" ;;
    *) pass "Mutagen never inherits a lock fd, so its daemon cannot pin a project or the VM" ;;
esac
rm -f "$_vm_dir/calls"
_vm_run "$_vm_dir/bin:$PATH" _vm_t_sync stop >/dev/null
case "$(cat "$_vm_dir/calls")" in
    *"sync flush kib-proj-1"$'\n'*"sync flush kib-proj-1-host"*"sync terminate"*"docker volume rm kib-proj-1-src"*)
        pass "close: flush VM → shadow → project, then the volume is gone"
        ;;
    *) fail "close did not flush both hops then drop the volume" "$(cat "$_vm_dir/calls")" ;;
esac
deny "close deletes the shadow" test -e "$_vm_sh"
rm -f "$_vm_dir/calls"
_vm_out="$(MG_FLUSH=1 _vm_run "$_vm_dir/bin:$PATH" _vm_t_sync stop)"
case "$(cat "$_vm_dir/calls")" in
    *"volume rm"* | *"sync terminate"*) fail "a failed flush still dropped the box's edits" ;;
    *) pass "a failed flush keeps the volume, so no box edit is lost" ;;
esac
mkdir -p "$_vm_sh"
_vm_out="$(MG_FLUSH_HOST=1 _vm_run "$_vm_dir/bin:$PATH" _vm_t_sync stop 2>&1)"
allow "a failed host-hop flush keeps the shadow" test -d "$_vm_sh"
case "$(DK_START=1 MG_LIST=1 MG_FLUSH_HOST=1 _vm_run "$_vm_dir/bin:$PATH" _vm_t_sync stop 2>&1)" in
    *"did not sync back"*) fail "a cold start with nothing left over warns of lost edits" ;;
    *) pass "a cold start with nothing left over cleans up silently" ;;
esac
_vm_t_mac() { KIB_OS=darwin && KIB_VM='' && vm_use claude && echo returned; }
case "$(_vm_run /usr/bin:/bin _vm_t_mac)" in
    *"runs every box in a Lima VM"*) pass "macOS without Lima: refused, never a non-VM engine" ;;
    *) fail "macOS ran without Lima" ;;
esac

_vm_out="$(_vm_run /usr/bin:/bin _vm_t_returns)"
case "$_vm_out" in
    *docs/vm.md*returned) pass "no Lima: a session names docs/vm.md and runs natively" ;;
    *) fail "no-Lima fallback is wrong" "$_vm_out" ;;
esac

_vm_t_lima() { # <answer> — the install prompt's outcome, the config and any limactl it left
    rm -f "$KIB_CONFIG"
    printf '%s\n' "$1" | _vm_install " limactl mutagen" 2>&3 && echo installed || echo declined
    cat "$KIB_CONFIG" 2>/dev/null || true
    [ ! -e "$HOME/.local/bin/limactl" ] || echo limactl
}
mkdir -p "$_vm_dir/curl"
printf '#!/bin/sh\nwhile [ "$1" != -o ]; do shift; done; echo junk >"$2"\n' >"$_vm_dir/curl/curl"
chmod +x "$_vm_dir/curl/curl"
is "VM tools prompt: never writes vm = off" "declined vm = off" \
    "$(_vm_run /usr/bin:/bin _vm_t_lima never 3>/dev/null | tr '\n' ' ' | sed 's/ $//')"
is "VM tools prompt: n declines this launch only" "declined" "$(_vm_run /usr/bin:/bin _vm_t_lima n 3>/dev/null)"
case "$(_vm_run "$_vm_dir/curl:/usr/bin:/bin" _vm_t_lima y 3>&1)" in
    *"failed its checksum"*declined) pass "VM tools prompt: a download off its pinned checksum installs nothing" ;;
    *) fail "a download off its checksum was installed or not refused" ;;
esac

_vm_t_notes() { _KIB_NOTES='' && warn one two && note three && printf '%s' "$_KIB_NOTES" >&3; }
is "launch notices are kept for the replay after the session" "⚠️  kib: one
   two
three" "$(_vm_run "$PATH" _vm_t_notes 3>&1 >/dev/null)"

rm -rf "$_vm_dir"
unset _vm_dir _vm_m _vm_out _vm_c _c
