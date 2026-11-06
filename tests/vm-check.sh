#!/usr/bin/env bash
# Host-side: what kib's VM can see. Run with at least one kib session open; run it again after
# closing a project (its volume must be gone). Every line must pass. (PLAN_VM_SECURITY.md)
set -u
KIB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$KIB_ROOT/tests/lib.sh"
IMAGE_NAME="keep-it-in-your-box" # as bin/kib names it
# shellcheck source=SCRIPTDIR/../host/_load.sh
. "$KIB_ROOT/host/_load.sh"

PATH="$PATH:$HOME/.local/bin:$HOME/.local/docker"
export DOCKER_CONFIG="$HOME/.local/docker"
if [ "$(limactl list --format '{{.Status}}' "$KIB_VM_NAME" 2>/dev/null)" != Running ]; then
    echo "❌ kib's VM is not running: open a kib session first." >&2
    exit 2
fi
DOCKER_HOST="unix://$(limactl list --format '{{.Dir}}' "$KIB_VM_NAME")/sock/docker.sock"
export DOCKER_HOST
vm() { limactl shell --workdir / "$KIB_VM_NAME" -- "$@" 2>/dev/null; }

section "Mounts: kib's fixed set, nothing else"
KIB_NODE_CACHE="$KIB_NODE_CACHE-vm" # as vm_up names it
_vm_mounts
_want="$(for m in "${VM_MOUNTS[@]}"; do case "$m" in --*) ;; *) echo "${m%:w}" ;; esac done | sort)"
is "the VM mounts exactly kib's list" "$_want" "$(vm findmnt -rn -t 9p,virtiofs,fuse.sshfs -o TARGET | sort)"
is "no reverse-sshfs" "" "$(vm findmnt -rn -t fuse.sshfs -o TARGET)"
deny "vm-ro is read-only in the VM" vm touch "$VM_RO/.vm-check"
deny "kib's checkout is read-only in the VM" vm touch "$KIB_ROOT/.vm-check"
deny "the VM has no ~/.ssh" vm test -e "$HOME/.ssh"
deny "the VM has no ~/.keep-it-in-your-box (tokens)" vm test -e "$HOME/.keep-it-in-your-box"
deny "the VM has no ~/.claude.json" vm test -e "$HOME/.claude.json"

section "Open projects only, without their secrets"
_vols="$(docker volume ls -q --filter label=kib-src=1)"
for v in $_vols; do
    is "$v belongs to an open project" "${v%-src}" \
        "$(docker ps --format '{{.Names}}' --filter "name=^${v%-src}\$")"
    # Every .env assignment in the volume is kib's render, never a value. `ok` last: a probe
    # that never ran must not read as a clean volume.
    is "no .env value in $v" "ok" "$(docker run --rm --network none -v "$v:/s:ro" --entrypoint sh \
        "$IMAGE_NAME" -c 'find /s -name ".env*" -type f ! -name .env.example ! -name .env.sample \
        ! -name .env.template -exec grep -H "=" {} + | grep -v "=<redacted>\$"; echo ok' 2>&1)"
done
is "vm-rw holds one dir per open project (and .state)" "$(printf '%s\n' "$_vols" | grep -c .)" \
    "$(find "$VM_RW" -mindepth 1 -maxdepth 1 ! -name .state | grep -c .)"

report
