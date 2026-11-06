#!/usr/bin/env bash
# tmp_: Phase 5 on the Mac — kib with no Docker Desktop (quit, its CLI off PATH). Delete after.
# Run from the kib checkout, on the Mac:  ./tmp_macos_test.sh     Report: tmp_macos_report.txt
cd "$(dirname "$0")" || exit 1
KIB_SRC="$PWD"
REPORT="$KIB_SRC/tmp_macos_report.txt"
exec > >(tee "$REPORT") 2>&1

step() { printf '\n━━ %s\n' "$*"; }
check() { # <description> <command…>
    local d="$1"
    shift
    if "$@" >/dev/null 2>&1; then echo "✅ $d"; else echo "❌ $d"; fi
}
wait_for() { # <seconds> <command…>
    local n="$1"
    shift
    while [ "$n" -gt 0 ]; do
        "$@" && return 0
        sleep 1
        n=$((n - 1))
    done
    return 1
}
not() { ! "$@"; }
dd_running() { pgrep -f 'Docker.app/Contents/MacOS/com.docker.backend' >/dev/null; }

step "0. Environment"
sw_vers | tr '\n' ' '
echo "$(uname -m), bash $BASH_VERSION"
echo "kib: $(git rev-parse --abbrev-ref HEAD) $(git rev-parse --short HEAD)"
for t in limactl mutagen docker; do echo "$t: $(command -v "$t" || echo missing)"; done

step "1. Docker Desktop off"
if dd_running; then
    docker desktop stop >/dev/null 2>&1 || osascript -e 'quit app "Docker"'
    wait_for 90 not dd_running
fi
check "Docker Desktop is not running" not dd_running
# Every PATH dir holding a docker binary, dropped: kib must bring its own CLI.
NODD=""
IFS=:
for d in $PATH; do [ -e "$d/docker" ] || NODD="$NODD${NODD:+:}$d"; done
unset IFS
echo "PATH for kib: $NODD"

step "2. A kib box with no Docker Desktop"
T="$HOME/kib-mac-test"
mkdir -p "$T/www" && cd "$T" || exit 1
[ -d .git ] || git init -q
rm -f box.txt host-done host-edit.txt
echo hello >hello.txt && echo 'SECRET=fake-not-a-secret' >.env && echo served >www/kib-probe.txt
python3 -m http.server 8765 --bind 127.0.0.1 --directory "$T/www" >/dev/null 2>&1 &
WWW=$!
L="unix://$HOME/.lima/kib-vm/sock/docker.sock"
D="$HOME/.local/docker/docker"
( # host side, while the box waits for host-done
    wait_for 900 test -e box.txt || exit 0
    echo "[host] ✅ box.txt reached the host"
    echo edited-on-host >host-edit.txt
    limactl shell kib-vm -- findmnt -rn -t 9p,virtiofs,fuse.sshfs -o TARGET,FSTYPE | sed 's/^/[host] vm mount: /'
    check "[host] ~/.ssh not in the VM" not limactl shell kib-vm -- test -e "$HOME/.ssh"
    check "[host] vm-ro read-only in the VM" not limactl shell kib-vm -- touch "$HOME/.local/state/keep-it-in-your-box/vm-ro/x"
    for v in $(DOCKER_HOST="$L" "$D" volume ls -q --filter label=kib-src); do
        check "[host] the .env value is not in $v" not env DOCKER_HOST="$L" \
            "$D" run --rm -v "$v:/s:ro" alpine grep -rqs fake-not-a-secret /s
    done
    echo ok >host-done
) &
HOSTSIDE=$!
# shellcheck disable=SC2016 # runs in the box
PATH="$NODD" "$KIB_SRC/bin/kib" exec sh -c '
    echo "[box] kernel: $(uname -r)"
    echo "[box] .env: $(cat .env 2>&1)"
    echo "[box] host.docker.internal: $(curl -s -m5 http://host.docker.internal:8765/kib-probe.txt || echo unreachable)"
    echo from-box >box.txt
    n=0; while [ ! -e host-done ] && [ $n -lt 300 ]; do sleep 1; n=$((n+1)); done
    echo "[box] host-edit.txt: $(cat host-edit.txt 2>&1)"'
echo "kib exited: $?"
{ kill "$WWW" "$HOSTSIDE" && wait; } 2>/dev/null
check "kib installed its own Docker CLI" test -x "$D"
check "box.txt is on the host" test -e box.txt
check "the VM stopped after the last session" test "$(limactl list --format '{{.Status}}' kib-vm 2>/dev/null)" = Stopped
check "Docker Desktop is still not running" not dd_running
cd "$KIB_SRC" || exit 1

step "Done. Report: $REPORT"
sleep 1
sed -i '' "s#$HOME#~#g" "$REPORT"
