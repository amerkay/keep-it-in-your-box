#!/usr/bin/env bash
# TMP (delete when decided): does gVisor (design C) work for kib, and how slow is it?
# Runs in kib's Lima VM, never on your host's Docker: no sudo, open sessions untouched.
# Installs runsc in the VM for the run and removes it after. Usage: tmp_gvisor_probe.sh <project>
set -u
PROJ="$(cd "${1:?usage: $0 <project dir>}" && pwd)"
KR="$(cd "$(dirname "$0")" && pwd)" # kib's checkout: the VM mounts it at this same path
export PATH="$PATH:$HOME/.local/bin:$HOME/.local/docker" DOCKER_CONFIG="$HOME/.local/docker"
VM=kib-vm IMG=keep-it-in-your-box P=kib-probe U=1000:1000 GV=/opt/kib-probe-gvisor
vm() { limactl shell --workdir / "$VM" sudo -n -- "$@" </dev/null; }
ok() { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; }
info() { printf '  ℹ %s\n' "$1"; }
check() { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got: $3)"; fi; }

[ "$(limactl list --format '{{.Status}}' "$VM" 2>/dev/null)" = Running ] \
    || limactl start --tty=false "$VM" >/dev/null 2>&1 || { echo "cannot start $VM"; exit 1; }
DOCKER_HOST="unix://$(limactl list --format '{{.Dir}}' "$VM")/sock/docker.sock"
export DOCKER_HOST
for _ in $(seq 60); do docker info >/dev/null 2>&1 && break; sleep 1; done # a fresh boot
docker image inspect "$IMG" >/dev/null || { echo "no $IMG image in the VM (error above)"; exit 1; }

# shellcheck disable=SC2046 # ids
cleanup() {
    docker rm -f $(docker ps -aq --filter name=^$P) >/dev/null 2>&1
    docker volume rm $(docker volume ls -q --filter name=^$P) >/dev/null 2>&1
    docker network rm $P-net >/dev/null 2>&1
    vm sh -c "awk '\$2 ~ \"^/mnt/$P\" { print \$2 }' /proc/mounts | sort -r | xargs -r -n1 umount -l
        rm -rf /mnt/$P /var/tmp/$P-*
        for r in runsc runsc-uds; do $GV/runsc uninstall --runtime=\$r >/dev/null 2>&1; done
        rm -rf $GV; systemctl reload docker"
    rm -f "$TAR"
}
TAR="$(mktemp)"
trap cleanup EXIT

echo "⏳ installing gVisor in the VM…"
# The release archive (runsc + gvisor-bin/) in its own dir: cleanup is one rm. No && chains, so
# set -e stops at the first failure.
vm sh -c "set -e; u=https://storage.googleapis.com/gvisor/releases/release/latest/\$(uname -m)
    rm -rf $GV; mkdir -p $GV; cd $GV
    curl -fsSLO \"\$u/gvisor.tar.bz2\"
    curl -fsSLO \"\$u/gvisor.tar.bz2.sha512\"
    sha512sum -c gvisor.tar.bz2.sha512
    python3 -c 'import tarfile; tarfile.open(\"gvisor.tar.bz2\").extractall()' # no bzip2 here
    ./runsc install
    ./runsc install --runtime=runsc-uds -- --host-uds=open
    systemctl reload docker" >/dev/null || { echo "runsc install failed (above)"; exit 1; }
sleep 2
G=(--runtime=runsc)
# kib's own box flags (host/lifecycle.sh start_container)
HARD=(--init --cap-drop=ALL --cap-add=SETUID --cap-add=SETGID --cap-add=CHOWN
    --cap-add=DAC_OVERRIDE --cap-add=FOWNER --security-opt no-new-privileges)

echo "The box itself:"
check "starts under gVisor with kib's flags, and drops to a user (gosu)" docker run --rm "${G[@]}" \
    "${HARD[@]}" --entrypoint gosu "$IMG" "$U" true
docker run -d --name $P-top "${G[@]}" "${HARD[@]}" --entrypoint sleep "$IMG" infinity >/dev/null
case "$(docker top $P-top -o args 2>/dev/null)" in
    *"sleep infinity"*) ok "docker top sees 'sleep infinity' (kib's readiness check)" ;;
    *) bad "docker top does not see 'sleep infinity' (kib's readiness check)" ;;
esac

echo "Network:"
docker network create $P-net >/dev/null
docker run -d --name $P-peer --network $P-net --network-alias kib-broker --entrypoint python3 \
    "$IMG" -m http.server 8100 >/dev/null
ip="$(docker inspect -f '{{(index .NetworkSettings.Networks "'$P-net'").IPAddress}}' $P-peer)"
vm sh -c "grep '^nameserver' /run/systemd/resolve/resolv.conf >/var/tmp/$P-resolv.conf"
docker create --name $P-gv "${G[@]}" --add-host "kib-broker:$ip" \
    -v /var/tmp/$P-resolv.conf:/etc/resolv.conf:ro --entrypoint sleep "$IMG" 300 >/dev/null
docker network connect $P-net $P-gv && docker start $P-gv >/dev/null
check "the broker net, connected before start (create → connect → start)" docker exec $P-gv true
check "kib-broker as a host entry reaches the broker's port" docker exec $P-gv \
    curl -sf -o /dev/null --max-time 10 http://kib-broker:8100/
check "our own resolv.conf reaches the internet (dual-homed)" docker exec $P-gv \
    curl -s -o /dev/null --max-time 10 https://api.anthropic.com

echo "Socket sidecars (the Wayland clipboard proxy on Linux):"
vm sh -c "mkdir -p /var/tmp/$P-sock && chmod 777 /var/tmp/$P-sock"
srv='import socket,os
s=socket.socket(socket.AF_UNIX); s.bind("/s/sock"); os.chmod("/s/sock",0o777); s.listen()
while True:
    c,_=s.accept(); c.send(b"hi"); c.close()'
cli='import socket; s=socket.socket(socket.AF_UNIX); s.connect("/s/sock"); print(s.recv(2).decode())'
docker run -d --name $P-uds -v /var/tmp/$P-sock:/s --entrypoint python3 "$IMG" -c "$srv" >/dev/null
sleep 1
if [ "$(docker run --rm "${G[@]}" -v /var/tmp/$P-sock:/s --entrypoint python3 "$IMG" -c "$cli" 2>/dev/null)" = hi ]; then
    ok "the box connects to a sidecar's unix socket"
else
    is "the box connects to a sidecar's unix socket, with --host-uds=open" hi \
        "$(docker run --rm --runtime=runsc-uds -v /var/tmp/$P-sock:/s --entrypoint python3 "$IMG" -c "$cli" 2>&1)"
fi

echo "kib's real redaction view (its FUSE sidecar) on a copy of $PROJ:"
(cd "$PROJ" && { echo .git; git ls-files; } | tar -cf "$TAR" -T - 2>/dev/null)
docker volume create $P-src >/dev/null
docker volume create $P-cache >/dev/null
docker run --rm -i -v $P-src:/w -v $P-cache:/c --entrypoint sh "$IMG" -c "tar -xf - -C /w &&
    echo SECRET=kibprobevalue >/w/.env && chown -R $U /w /c" <"$TAR"
F=/mnt/$P/f
vm sh -c "mkdir -p /mnt/$P && mount --bind /mnt/$P /mnt/$P && mount --make-rshared /mnt/$P
    mkdir -p $F/mnt && chmod 755 $F $F/mnt && chown $U $F/mnt && : >/var/tmp/$P-pat
    printf 'root:x:0:0::/root:/bin/sh\nhostuser:x:1000:1000::/tmp:/bin/sh\n' >/var/tmp/$P-passwd
    printf 'root:x:0:\nhostuser:x:1000:\n' >/var/tmp/$P-group"
docker run -d --name $P-fuse --cap-drop=ALL --cap-add=SYS_ADMIN --device /dev/fuse \
    --security-opt apparmor=unconfined --user "$U" --userns=host --network none \
    -v $P-src:/src -v /var/tmp/$P-pat:/kib-patterns:ro -v /var/tmp/$P-passwd:/etc/passwd:ro \
    -v /var/tmp/$P-group:/etc/group:ro -v "$F:$F:rshared" -v "$KR/kib:/usr/local/lib/kib:ro" \
    -v "$KR/guest/policy/global.kibignore:/usr/local/share/global.kibignore:ro" \
    --entrypoint /usr/local/bin/fuse "$IMG" --src /src --mnt "$F/mnt" --uid 1000 --gid 1000 \
    --patterns-file /kib-patterns --guard-file /usr/local/share/global.kibignore >/dev/null
for _ in $(seq 50); do vm grep -q " $F/mnt fuse" /proc/mounts && break; sleep 0.2; done
BOX=(-v "$F/mnt:/w:rslave" --user "$U" -w /w -v "$P-cache:/c" -e HOME=/tmp
    -e pnpm_config_store_dir=/c/store --entrypoint sh "$IMG" -c)
if vm grep -q " $F/mnt fuse" /proc/mounts; then
    out="$(docker run --rm "${G[@]}" "${BOX[@]}" 'cat .env' 2>&1)"
    case "$out" in
        *kibprobevalue*) bad "gVisor box reads .env: the REAL value leaked" ;;
        *"<redacted>"*) ok "gVisor box reads .env as key names only (SECRET=<redacted>)" ;;
        *) bad "gVisor box reads .env: unexpected ($out)" ;;
    esac
    case "$(docker run --rm "${G[@]}" "${BOX[@]}" 'echo x >.git/hooks/pre-commit' 2>&1)" in
        *"ermission"* | *"not permitted"*) ok "gVisor box: writing .git/hooks is refused" ;;
        *) bad "gVisor box: writing .git/hooks was NOT refused" ;;
    esac
    docker run --rm "${G[@]}" "${BOX[@]}" 'echo box >probe-write.txt' >/dev/null 2>&1
    is "gVisor box: an ordinary write lands in the project" box \
        "$(docker run --rm -v $P-src:/w --entrypoint cat "$IMG" /w/probe-write.txt 2>&1)"
    VIEW=1
else
    bad "kib's FUSE sidecar never mounted: $(docker logs $P-fuse 2>&1 | tail -3)"
    VIEW=0
fi

w='const fs=require("fs");fs.watch("/w",()=>{console.log("event");process.exit(0)});
   setTimeout(()=>{if(process.argv[1])fs.writeFileSync("/w/in","x")},1000);
   setTimeout(()=>{console.log("none");process.exit(0)},5000)'
vm mkdir -p /var/tmp/$P-w
docker run -d --name $P-watch "${G[@]}" -v /var/tmp/$P-w:/w --entrypoint node "$IMG" -e "$w" >/dev/null
sleep 1 && vm sh -c "echo x >/var/tmp/$P-w/out"
sleep 5
case "$(docker logs $P-watch 2>&1)" in
    event) ok "a host-side edit wakes a watcher in the box (hot reload works)" ;;
    *) info "a host-side edit does NOT wake a watcher in the box: dev servers need polling" ;;
esac
is "an edit inside the box wakes a watcher in the box" event \
    "$(docker run --rm "${G[@]}" -v /var/tmp/$P-w:/w --entrypoint node "$IMG" -e "$w" 1 2>&1)"

[ "$VIEW" = 1 ] || exit 1
echo "Speed through the redaction view, today's kib (plain) vs gVisor:"
secs() { local s; s=$(date +%s.%N); "$@" >/dev/null 2>&1 || printf '(failed) ' >&2
    awk -v s="$s" -v e="$(date +%s.%N)" 'BEGIN { printf "%.1f", e - s }'; }
GITOK=(-e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e "GIT_CONFIG_VALUE_0=*")
bench() { # <label> <sh command, run in the project>
    local a b
    a="$(secs docker run --rm "${GITOK[@]}" "${BOX[@]}" "$2")"
    b="$(secs docker run --rm "${G[@]}" "${GITOK[@]}" "${BOX[@]}" "$2")"
    printf '  %-36s plain %6ss   gVisor %6ss   ×%s\n' "$1" "$a" "$b" \
        "$(awk -v a="$a" -v b="$b" 'BEGIN { printf "%.1f", (a > 0 ? b / a : 0) }')"
}
bench "start a box" 'true'
bench "git status ×3" 'git status >/dev/null; git status >/dev/null; git status'
bench "list every file (find)" 'find . -path ./.git -prune -o -type f -print | wc -l'
bench "write, read, delete 3000 files" 'mkdir t && for i in $(seq 3000); do echo $i >t/$i; done
    cat t/* >/dev/null; rm -rf t'
lock="$(cd "$PROJ" && git ls-files | grep -m1 -E '(^|/)pnpm-lock\.yaml$')"
if [ -n "$lock" ]; then
    d="$(dirname "$lock")"
    echo "  (pnpm in ./$d: filling the cache once, not timed…)"
    if docker run --rm "${BOX[@]}" "cd '$d' && pnpm install --frozen-lockfile" >/dev/null 2>&1; then
        bench "pnpm install (offline, from cache)" "cd '$d' && find . -name node_modules -prune \
            -exec rm -rf {} + && pnpm install --offline --frozen-lockfile"
    else info "pnpm install failed in ./$d, so no pnpm timing"; fi
else info "no pnpm-lock.yaml tracked in $PROJ: no pnpm timing"; fi
echo "Done. gVisor and every probe container were removed from the VM."
