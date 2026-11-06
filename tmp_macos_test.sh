#!/usr/bin/env bash
# tmp_: macOS facts Phase 5 needs (PLAN_VM_SECURITY.md S3, S7). Delete once Phase 5 lands.
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
ask() { # <question> — yes only on y
    local a
    printf '\n❓ %s [y/N] ' "$1"
    read -r a </dev/tty
    case "$a" in y* | Y*) ;; *) return 1 ;; esac
}
dd() { docker --context desktop-linux "$@"; }
dd_up() { dd info >/dev/null 2>&1; }
backend() { pgrep -f 'Docker.app/Contents/MacOS/com.docker.backend' >/dev/null; }
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

step "0. Environment"
sw_vers | tr '\n' ' '
echo "$(uname -m), bash $BASH_VERSION, $(python3 --version 2>&1)"
echo "kib: $(git rev-parse --abbrev-ref HEAD) $(git rev-parse --short HEAD)"
echo "Docker Desktop $(defaults read /Applications/Docker.app/Contents/Info CFBundleShortVersionString 2>&1)"
echo "docker context: $(docker context show 2>&1)"
echo "docker desktop CLI: $(docker desktop version 2>&1 | head -1)"
for t in limactl colima mutagen; do echo "$t: $(command -v "$t" || ls "$HOME/.local/bin/$t" 2>/dev/null || echo missing)"; done

step "1. S3: where Docker Desktop keeps its sharing list (key names; values only for sharing)"
GC="$HOME/Library/Group Containers/group.com.docker"
# A plain folder in ~, never ~/Documents: macOS privacy-prompts Docker for that one.
O="$HOME/kib-s3-outside"
mkdir -p "$O" && touch "$O/seen"
for f in "$GC/settings-store.json" "$GC/settings.json" \
    "/Library/Application Support/com.docker.docker/admin-settings.json"; do
    [ -f "$f" ] || {
        echo "absent: $f"
        continue
    }
    python3 - "$f" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
print(sys.argv[1] + ":\n  keys: " + " ".join(sorted(d)))
for k, v in d.items():
    if any(s in k.lower() for s in ("shar", "virt", "lock")):
        print("  " + k + " = " + json.dumps(v))
EOF
done
if dd_up; then
    echo "Docker Desktop VM's host shares:"
    dd run --rm --privileged --pid=host alpine nsenter -t 1 -m -- \
        sh -c 'mount | grep -iE "virtiofs|grpcfuse|osxfs|fakeowner" | head; ls /run/host_virtiofs 2>&1' 2>&1
    check "Docker Desktop shares any folder in ~ today (expected now; Phase 5 closes it)" \
        dd run --rm -v "$O:/o:ro" alpine test -e /o/seen
else
    echo "Docker Desktop is not running: start it and rerun for this part."
fi

# Quit, edit, start: a running Docker Desktop may write its own settings back on quit.
dd_stop() {
    docker desktop stop >/dev/null 2>&1 || osascript -e 'quit app "Docker"'
    wait_for 90 not backend
}
dd_start() {
    local t0=$SECONDS
    docker desktop start >/dev/null 2>&1 || open -ga Docker
    wait_for 180 dd_up && echo "   engine up in $((SECONDS - t0)) s"
}
F="$GC/settings-store.json"
[ -f "$F" ] || F="$GC/settings.json"
if [ -f "$F" ] && ask "S3 experiment: quit Docker Desktop (stops ALL its containers), share the defaults minus /Users plus ~/kib-s3-probe, start it, check, then restore and restart (~3 min)?"; then
    P="$HOME/kib-s3-probe"
    mkdir -p "$P" && touch "$P/seen"
    cp "$F" "$F.kib-bak" && echo "backup: $F.kib-bak"
    t0=$SECONDS
    dd_stop && echo "   stopped in $((SECONDS - t0)) s"
    python3 - "$F" "$P" <<'EOF'
import json, sys
f, probe = sys.argv[1], sys.argv[2]
d = json.load(open(f))
key = next((k for k in d if k.lower() == "filesharingdirectories"), "FilesharingDirectories")
old = d.get(key, ["/Users", "/Volumes", "/private", "/tmp", "/var/folders"])
d[key] = [p for p in old if p != "/Users"] + [probe]
json.dump(d, open(f, "w"), indent=2)
print("   wrote " + key + " = " + json.dumps(d[key]))
EOF
    dd_start
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("   after start:", [v for k,v in d.items() if k.lower()=="filesharingdirectories"])' "$F"
    check "the probe dir is shared" dd run --rm -v "$P:/p:ro" alpine test -e /p/seen
    check "a folder outside the list is refused now" not dd run --rm -v "$O:/o:ro" alpine test -e /o/seen
    dd run --rm -v "$O:/o:ro" alpine test -e /o/seen 2>&1 | head -1 | sed 's/^/   docker says: /'
    dd_stop
    cp "$F.kib-bak" "$F" && rm -f "$F.kib-bak" && rm -rf "$P"
    dd_start
    check "restored: that folder is shared again" dd run --rm -v "$O:/o:ro" alpine test -e /o/seen
fi

rm -rf "$O"

step "2. S7: a kib box in the Lima VM (vz + virtiofs)"
if ask "Run one kib box in Lima? kib may prompt to install Lima and Mutagen; the first run builds the image in the VM (~5-10 min)."; then
    T="$HOME/kib-mac-test"
    mkdir -p "$T/www" && cd "$T" || exit 1
    [ -d .git ] || git init -q
    rm -f box.txt host-done host-edit.txt
    echo hello >hello.txt && echo 'SECRET=fake-not-a-secret' >.env && echo served >www/kib-probe.txt
    python3 -m http.server 8765 --bind 127.0.0.1 --directory "$T/www" >/dev/null 2>&1 &
    WWW=$!
    L="$HOME/.lima/kib-vm/sock/docker.sock"
    ( # host side, while the box waits for host-done
        wait_for 900 test -e box.txt || exit 0
        echo "[host] ✅ box.txt reached the host"
        echo edited-on-host >host-edit.txt
        limactl shell kib-vm -- findmnt -rn -t 9p,virtiofs,fuse.sshfs -o TARGET,FSTYPE | sed 's/^/[host] vm mount: /'
        check "[host] ~/.ssh not in the VM" not limactl shell kib-vm -- test -e "$HOME/.ssh"
        check "[host] ~/Documents not in the VM" not limactl shell kib-vm -- test -e "$HOME/Documents"
        check "[host] vm-ro read-only in the VM" not limactl shell kib-vm -- touch "$HOME/.local/state/keep-it-in-your-box/vm-ro/x"
        echo "[host] volumes: $(DOCKER_HOST="unix://$L" docker volume ls -q --filter label=kib-src | tr '\n' ' ')"
        for v in $(DOCKER_HOST="unix://$L" docker volume ls -q --filter label=kib-src); do
            check "[host] the .env value is not in $v" not env DOCKER_HOST="unix://$L" \
                docker run --rm -v "$v:/s:ro" alpine grep -rqs fake-not-a-secret /s
        done
        echo ok >host-done
    ) &
    HOSTSIDE=$!
    # shellcheck disable=SC2016 # runs in the box
    KIB_VM=on "$KIB_SRC/bin/kib" exec sh -c '
        echo "[box] kernel: $(uname -r)"
        echo "[box] hello.txt: $(cat hello.txt)"
        echo "[box] .env: $(cat .env 2>&1)"
        echo "[box] host.docker.internal: $(curl -s -m5 http://host.docker.internal:8765/kib-probe.txt || echo unreachable)"
        echo from-box >box.txt
        n=0; while [ ! -e host-done ] && [ $n -lt 300 ]; do sleep 1; n=$((n+1)); done
        echo "[box] host-edit.txt: $(cat host-edit.txt 2>&1)"'
    echo "kib exited: $?"
    { kill "$WWW" "$HOSTSIDE" && wait; } 2>/dev/null
    echo "host kernel: $(uname -r)"
    check "box.txt is on the host" test -e box.txt
    check "the VM stopped after the last session" test "$(limactl list --format '{{.Status}}' kib-vm 2>/dev/null)" = Stopped
    command -v colima >/dev/null && echo "colima: $(colima status 2>&1 | head -1)"
    cd "$KIB_SRC" || exit 1
fi

step "Done. Report: $REPORT"
sleep 1
sed -i '' "s#$HOME#~#g" "$REPORT"
