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
esac
EOF
# Fake docker and mutagen log every call; MG_FLUSH sets whether a flush succeeds.
for _c in docker mutagen; do
    printf '#!/usr/bin/env bash\necho "%s $*" >>"%s/calls"\n' "$_c" "$_vm_dir" >"$_vm_dir/bin/$_c"
done
echo 'ls /proc/$$/fd >>"'"$_vm_dir"'/mg-fds"' >>"$_vm_dir/bin/mutagen"
echo 'case "$*" in *"sync flush"*) exit "${MG_FLUSH:-0}" ;; esac' >>"$_vm_dir/bin/mutagen"
chmod +x "$_vm_dir/bin/"*

# Subshells inherit these; a `sh -c` would not see the sourced functions.
_vm_t_mounts() { _vm_mounts && printf '%s\n' "${VM_MOUNTS[@]}"; }
_vm_t_up() { vm_use claude && printf '%s %s %s\n' "$DOCKER_HOST" "$(engine_in_vm && echo vm)" \
    "$KIB_HOST_GATEWAY"; }
_vm_edits() { if [ -f "$_vm_dir/edits" ]; then wc -l <"$_vm_dir/edits" | tr -d ' '; else echo 0; fi; }
_vm_t_last() { vm_up && vm_down; }
_vm_stops() { if [ -f "$_vm_dir/stops" ]; then wc -l <"$_vm_dir/stops" | tr -d ' '; else echo 0; fi; }
_vm_t_engine() { if engine_in_vm; then echo vm; else echo native; fi; }
_vm_t_returns() {
    vm_use claude
    echo returned
}
_vm_t_sync() { # [stop] — the sync of a project named "proj", with the state a launch stages
    CNAME=kib-proj-1 SYNC_CNAME=kib-proj-1-sync IMAGE_NAME=img KIB_BOX_UID=1000 KIB_BOX_GID=1000
    PATTERNS_STATE="$_vm_dir/pat" _KIB_ENGINE_VM=1
    KIB_GUARD_FILE_HOST="$KIB_ROOT/guest/policy/global.kibignore" MUTAGEN_BIN=mutagen
    printf '.secret\n' >"$PATTERNS_STATE"
    exec 200>"$_vm_dir/l200" 205>"$_vm_dir/l205" # held by a real launch
    if [ -n "${1:-}" ]; then vm_sync_stop; else vm_sync_start; fi
}
_vm_t_shared() { exec 207>"$VM_LOCK" && flock -s 207 && vm_up && vm_down; }

_vm_run() { ( # <PATH> <cmd…> — a fresh subshell with the units loaded, HOME and state faked
    export HOME="$_vm_dir/home" KIB_STATE_ROOT="$_vm_dir/state" KIB_VM="${KIB_VM-on}"
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

is "the docker engine moves into the VM; kib stays here" \
    "unix://$_vm_dir/lima/sock/docker.sock vm 192.168.5.2" "$(_vm_run "$_vm_dir/bin:$PATH" _vm_t_up | tail -1)"
is "a VM with an old mount set is re-mounted once, then left alone" "1" \
    "$(_vm_run "$_vm_dir/bin:$PATH" _vm_t_up >/dev/null && _vm_edits)"
case "$(cat "$_vm_dir/edits")" in
    *--mount-type=9p*) pass "the re-mount pins 9p, never reverse-sshfs" ;;
    *) fail "the re-mount did not pin the mount type" "$(cat "$_vm_dir/edits")" ;;
esac
mv "$_vm_dir/state/vm-spec" "$_vm_dir/spec" && echo stale >"$_vm_dir/state/vm-spec"
_vm_run "$_vm_dir/bin:$PATH" _vm_t_shared >/dev/null
is "a stale mount set never restarts a VM another kib is using" "1" "$(_vm_edits)"
mv "$_vm_dir/spec" "$_vm_dir/state/vm-spec"

rm -f "$_vm_dir/stops"
_vm_run "$_vm_dir/bin:$PATH" _vm_t_shared >/dev/null
is "the VM stays up while another kib holds it" "0" "$(_vm_stops)"
_vm_run "$_vm_dir/bin:$PATH" _vm_t_last >/dev/null
is "the last kib out stops the VM" "1" "$(_vm_stops)"

rm -f "$_vm_dir/calls"
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
case "$_vm_c" in
    *"sync create --name kib-proj-1"*"two-way-resolved"*"-c $_vm_dir/pat.sync.yml $_vm_dir/home/devel/proj docker://kib-proj-1-sync/src"*"sync flush kib-proj-1"*)
        pass "Mutagen syncs the project in, host wins, and the launch waits for the first sync"
        ;;
    *) fail "unexpected Mutagen session" "$_vm_c" ;;
esac
case "$_vm_c" in
    *"sync flush kib-proj-1"*"docker exec -i -u 1000:1000 kib-proj-1-sync tar -xf - -C /src"*)
        pass "after the first sync, the redacted/protected stand-ins are seeded into the volume"
        ;;
    *) fail "the guarded files are never seeded" "$_vm_c" ;;
esac
case "$(cat "$_vm_dir/pat.sync.yml")" in
    *'"node_modules"'*'".env"'*'".secret"'*'"**/.git/**/hooks"'*) pass "the sync ignores build dirs, the guard and .kibignore" ;;
    *) fail "the sync ignores miss a tier" "$(cat "$_vm_dir/pat.sync.yml")" ;;
esac
case " $(tr '\n' ' ' <"$_vm_dir/mg-fds") " in
    *" 200 "* | *" 205 "*) fail "Mutagen (whose daemon outlives kib) inherited a lock fd" ;;
    *) pass "Mutagen never inherits a lock fd, so its daemon cannot pin a project or the VM" ;;
esac
rm -f "$_vm_dir/calls"
_vm_run "$_vm_dir/bin:$PATH" _vm_t_sync stop >/dev/null
case "$(cat "$_vm_dir/calls")" in
    *"sync flush"*"sync terminate"*"docker volume rm kib-proj-1-src"*) pass "close: flush, then the volume is gone" ;;
    *) fail "close did not flush then drop the volume" "$(cat "$_vm_dir/calls")" ;;
esac
rm -f "$_vm_dir/calls"
_vm_out="$(MG_FLUSH=1 _vm_run "$_vm_dir/bin:$PATH" _vm_t_sync stop)"
case "$(cat "$_vm_dir/calls")" in
    *"volume rm"* | *"sync terminate"*) fail "a failed flush still dropped the box's edits" ;;
    *) pass "a failed flush keeps the volume, so no box edit is lost" ;;
esac
case "$(_vm_run /usr/bin:/bin _mutagen_ensure)" in
    *"Run kib in a terminal"*) pass "no Mutagen and no tty: refused, never installed unasked" ;;
    *) fail "Mutagen install ran without a prompt" ;;
esac

_vm_out="$(_vm_run /usr/bin:/bin _vm_t_returns)"
case "$_vm_out" in
    *docs/vm.md*returned) pass "no Lima: a session names docs/vm.md and runs natively" ;;
    *) fail "no-Lima fallback is wrong" "$_vm_out" ;;
esac

rm -rf "$_vm_dir"
unset _vm_dir _vm_m _vm_out _vm_c _c
