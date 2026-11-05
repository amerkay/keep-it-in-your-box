#!/usr/bin/env bash
# Sourced by tests/check.sh — host/vm.sh's mounts, engine switch and VM lifetime, with a fake limactl.
# shellcheck disable=SC2030,SC2031  # _vm_run sets PATH in its own subshell, on purpose

# shellcheck source=SCRIPTDIR/_guard.sh
. "${BASH_SOURCE%/*}/_guard.sh" # sourced by tests/check.sh, never run directly

section "Lima VM engine (host/vm.sh)"

_vm_dir="$(mktemp -d)"
mkdir -p "$_vm_dir/bin" "$_vm_dir/home/devel/proj" "$_vm_dir/lima"
# Fake limactl: an existing, running VM; every stop is logged so the lifetime can be asserted.
cat >"$_vm_dir/bin/limactl" <<EOF
#!/usr/bin/env bash
case "\$1" in
    list) case "\$3" in *Dir*) echo "$_vm_dir/lima" ;; *) echo Running ;; esac ;;
    stop) echo stop >>"$_vm_dir/stops" ;;
esac
EOF
chmod +x "$_vm_dir/bin/limactl"

# Subshells inherit these; a `sh -c` would not see the sourced functions.
_vm_t_mounts() { _vm_mounts "$1" && printf '%s\n' "${VM_MOUNTS[@]}"; }
_vm_t_up() { vm_use claude && printf '%s %s\n' "$DOCKER_HOST" "$(engine_in_vm && echo vm)"; }
_vm_t_last() { vm_up && vm_down; }
_vm_stops() { if [ -f "$_vm_dir/stops" ]; then wc -l <"$_vm_dir/stops" | tr -d ' '; else echo 0; fi; }
_vm_t_engine() { if engine_in_vm; then echo vm; else echo native; fi; }
_vm_t_returns() {
    vm_use claude
    echo returned
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
is "no tty: only the project is mounted, never its parent" "$_vm_dir/home/devel/proj" \
    "$(_vm_run "$PATH" _vm_pick_root "$_vm_dir/home/devel/proj")"
case "$(_vm_run "$PATH" _vm_pick_root "$_vm_dir")" in
    *"holds your home"*) pass "a root that contains \$HOME is refused" ;;
    *) fail "a root containing \$HOME was accepted" ;;
esac

printf '%s\n' "$_vm_dir/home/devel" >"$_vm_dir/roots"
_vm_m="$(_vm_run "$PATH" _vm_t_mounts "$_vm_dir/roots")"
case "$_vm_m" in
    *"$_vm_dir/home/devel:w"*"/.claude/skills:w"*"$_vm_dir/state:w"*"/.keep-it-in-your-box"$'\n'*"$KIB_ROOT")
        pass "roots + ~/.claude trees + state rw; broker dir and kib read-only"
        ;;
    *) fail "unexpected VM mounts" "$_vm_m" ;;
esac
case "$_vm_m" in
    *"/.claude"$'\n'* | *"/.claude:w"$'\n'* | *.credentials*) fail "all of ~/.claude is exposed to the VM" ;;
    *) pass "the .claude dir itself (credential, settings, CLAUDE.md) stays off the VM" ;;
esac

is "the docker engine moves into the VM; kib stays here" "unix://$_vm_dir/lima/sock/docker.sock vm" \
    "$(_vm_run "$_vm_dir/bin:$PATH" _vm_t_up | tail -1)"
is "the new root is recorded" "$_vm_dir/home/devel/proj" "$(cat "$_vm_dir/state/vm-roots" 2>/dev/null)"

rm -f "$_vm_dir/stops"
_vm_run "$_vm_dir/bin:$PATH" _vm_t_shared >/dev/null
is "the VM stays up while another kib holds it" "0" "$(_vm_stops)"
_vm_run "$_vm_dir/bin:$PATH" _vm_t_last >/dev/null
is "the last kib out stops the VM" "1" "$(_vm_stops)"

_vm_out="$(_vm_run /usr/bin:/bin _vm_t_returns)"
case "$_vm_out" in
    *docs/vm.md*returned) pass "no Lima: a session names docs/vm.md and runs natively" ;;
    *) fail "no-Lima fallback is wrong" "$_vm_out" ;;
esac

rm -rf "$_vm_dir"
unset _vm_dir _vm_m _vm_out
