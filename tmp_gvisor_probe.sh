#!/usr/bin/env bash
# TMP (delete when decided): does gVisor (design C) work for kib, and how slow is it?
# Runs in kib's Lima VM, never on your host's Docker: no sudo, open sessions untouched.
# Installs runsc in the VM for the run and removes it after. Usage: tmp_gvisor_probe.sh <project>
set -u
PROJ="$(cd "${1:?usage: $0 <project dir>}" && pwd)"
export PATH="$PATH:$HOME/.local/bin:$HOME/.local/docker" DOCKER_CONFIG="$HOME/.local/docker"
VM=kib-vm IMG=keep-it-in-your-box P=kib-probe
vm() { limactl shell --workdir / "$VM" sudo -n -- "$@" </dev/null; }
ok() { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; }
info() { printf '  ℹ %s\n' "$1"; }
check() { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

[ "$(limactl list --format '{{.Status}}' "$VM" 2>/dev/null)" = Running ] \
    || limactl start --tty=false "$VM" >/dev/null 2>&1 || { echo "cannot start $VM"; exit 1; }
DOCKER_HOST="unix://$(limactl list --format '{{.Dir}}' "$VM")/sock/docker.sock"
export DOCKER_HOST
docker image inspect "$IMG" >/dev/null 2>&1 || { echo "no $IMG image in the VM: run kib once"; exit 1; }

# shellcheck disable=SC2046 # ids
cleanup() {
    docker rm -f $(docker ps -aq --filter name=^$P) >/dev/null 2>&1
    docker volume rm $(docker volume ls -q --filter name=^$P) >/dev/null 2>&1
    docker network rm $P-net >/dev/null 2>&1
    vm sh -c "umount -l /mnt/$P 2>/dev/null; rm -rf /mnt/$P /var/tmp/$P-w; \
        runsc uninstall >/dev/null 2>&1; rm -f /usr/local/bin/runsc; systemctl reload docker"
    rm -f "$TAR"
}
TAR="$(mktemp)"
trap cleanup EXIT

echo "⏳ installing gVisor in the VM…"
vm sh -c 'set -e; a=$(uname -m); u=https://storage.googleapis.com/gvisor/releases/release/latest/$a
    cd /tmp && curl -fsSLO "$u/runsc" && curl -fsSLO "$u/runsc.sha512" && sha512sum -c runsc.sha512
    install -m 755 runsc /usr/local/bin/runsc && rm runsc runsc.sha512
    runsc install && systemctl reload docker' >/dev/null 2>&1 || { echo "runsc install failed"; exit 1; }
sleep 2
G=(--runtime=runsc)

echo "Works with kib's setup:"
check "a box starts under gVisor" docker run --rm "${G[@]}" --entrypoint true "$IMG"
check "…with kib's hardening (no caps, no-new-privileges, non-root)" docker run --rm "${G[@]}" \
    --cap-drop=ALL --security-opt no-new-privileges --user 1000:1000 --entrypoint true "$IMG"

docker network create $P-net >/dev/null
docker run -d --name $P-peer --network $P-net --network-alias kib-broker --entrypoint python3 \
    "$IMG" -m http.server 8100 >/dev/null
docker create --name $P-gv "${G[@]}" --entrypoint sleep "$IMG" 300 >/dev/null
docker network connect $P-net $P-gv && docker start $P-gv >/dev/null
check "broker net attached before start (create → connect → start)" docker exec $P-gv true
check "Docker's DNS (127.0.0.11) finds the kib-broker alias" docker exec $P-gv getent hosts kib-broker
check "…and reaches it (the broker's port)" docker exec $P-gv \
    curl -sf -o /dev/null --max-time 10 http://kib-broker:8100/
check "…and still reaches the internet (dual-homed)" docker exec $P-gv \
    curl -s -o /dev/null --max-time 10 https://api.anthropic.com
docker run -d --name $P-late "${G[@]}" --entrypoint sleep "$IMG" 300 >/dev/null
sleep 1
nics() { docker exec $P-late sh -c 'wc -l </proc/net/dev' 2>/dev/null; }
n="$(nics)"
docker network connect $P-net $P-late 2>/dev/null
if [ -n "$n" ] && [ "$(nics)" != "$n" ]; then
    info "connecting after start works too (no reorder needed)"
else info "connecting after start fails: kib must create → connect → start"; fi

# kib's FUSE sidecar (runc) mounts the redacted view; the box binds it. A tmpfs stands in.
vm sh -c "mkdir -p /mnt/$P && mount --bind /mnt/$P /mnt/$P && mount --make-rshared /mnt/$P"
docker run -d --name $P-side --privileged -v /mnt/$P:/p:rshared --entrypoint sh "$IMG" \
    -c 'mkdir -p /p/m && mount -t tmpfs none /p/m && echo view >/p/m/f && sleep 300' >/dev/null
sleep 2
check "the box reads a sidecar's mount (the redaction view)" \
    sh -c "[ \"\$(docker run --rm ${G[*]} -v /mnt/$P/m:/w --entrypoint cat $IMG /w/f)\" = view ]"
check "…and its writes land in it" sh -c "docker run --rm ${G[*]} -v /mnt/$P/m:/w --entrypoint \
    sh $IMG -c 'echo box >/w/g' && [ \"\$(docker exec $P-side cat /p/m/g)\" = box ]"

vm mkdir -p /var/tmp/$P-w
w='const fs=require("fs");fs.watch("/w",()=>{console.log("event");process.exit(0)});
   setTimeout(()=>{if(process.argv[1])fs.writeFileSync("/w/in","x")},1000);
   setTimeout(()=>{console.log("none");process.exit(0)},5000)'
docker run -d --name $P-watch "${G[@]}" -v /var/tmp/$P-w:/w --entrypoint node "$IMG" -e "$w" >/dev/null
sleep 1 && vm sh -c "echo x >/var/tmp/$P-w/out"
sleep 5
case "$(docker logs $P-watch 2>&1)" in
    event) ok "a host-side edit wakes a watcher in the box (hot reload works)" ;;
    *) info "a host-side edit does NOT wake a watcher in the box: dev servers need polling" ;;
esac
check "an edit inside the box wakes a watcher in the box" sh -c "[ \"\$(docker run --rm ${G[*]} \
    -v /var/tmp/$P-w:/w --entrypoint node $IMG -e '$w' 1)\" = event ]"

echo "Speed, plain Docker vs gVisor, on $PROJ (git-tracked files + .git):"
(cd "$PROJ" && { echo .git; git ls-files; } | tar -cf "$TAR" -T - 2>/dev/null)
secs() { local s; s=$(date +%s.%N); "$@" >/dev/null 2>&1 || printf 'failed ' >&2
    awk -v s="$s" -v e="$(date +%s.%N)" 'BEGIN { printf "%.1f", e - s }'; }
bench() { # <label> <sh command run in the project dir>
    local a b
    a="$(secs docker run --rm -v $P-runc:/w -v $P-cache:/c -w /w "${E[@]}" --entrypoint sh "$IMG" -c "$2")"
    b="$(secs docker run --rm "${G[@]}" -v $P-runsc:/w -v $P-cache:/c -w /w "${E[@]}" --entrypoint sh "$IMG" -c "$2")"
    printf '  %-34s plain %6ss   gVisor %6ss   ×%s\n' "$1" "$a" "$b" \
        "$(awk -v a="$a" -v b="$b" 'BEGIN { printf "%.1f", a > 0 ? b / a : 0 }')"
}
E=(-e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e "GIT_CONFIG_VALUE_0=*"
    -e pnpm_config_store_dir=/c/store -e HOME=/tmp)
for r in runc runsc; do docker volume create $P-$r >/dev/null; done
printf '  %-34s plain %6ss   gVisor %6ss\n' "start an empty box" \
    "$(secs docker run --rm --entrypoint true "$IMG")" "$(secs docker run --rm "${G[@]}" --entrypoint true "$IMG")"
a="$(secs docker run --rm -i -v $P-runc:/w --entrypoint tar "$IMG" -xf - -C /w <"$TAR")"
b="$(secs docker run --rm -i "${G[@]}" -v $P-runsc:/w --entrypoint tar "$IMG" -xf - -C /w <"$TAR")"
printf '  %-34s plain %6ss   gVisor %6ss\n' "unpack the project" "$a" "$b"
bench "git status ×3" 'git status >/dev/null; git status >/dev/null; git status'
bench "list every file (find)" 'find . -type f | wc -l'
if [ -f "$PROJ/pnpm-lock.yaml" ]; then
    echo "  (filling a pnpm cache once, not timed…)"
    if docker run --rm -v $P-runc:/w -v $P-cache:/c -w /w "${E[@]}" --entrypoint sh "$IMG" \
        -c 'pnpm install --frozen-lockfile' >/dev/null 2>&1; then bench "pnpm install (offline, from cache)" \
        'find . -name node_modules -prune -exec rm -rf {} +; pnpm install --offline --frozen-lockfile'
    else info "pnpm install failed here, so no pnpm timing"; fi
fi
echo "Done. gVisor and every probe container were removed from the VM."
