#!/usr/bin/env bash
# TMP (delete when decided): does gVisor (design C) work for kib, and how fast is it?
#   tmp_gvisor_probe.sh <project>           Linux: in kib-vm, the project on a VM volume
#   tmp_gvisor_probe.sh --mount <project>   a throwaway VM with ~ mounted (design C; always on macOS)
# No sudo: everything runs in Lima VMs.
# Works on a copy of the project; gVisor, the copy and every probe container are removed after.
set -u
MOUNT=""
if [ "${1:-}" = --mount ] || [ "$(uname -s)" = Darwin ]; then MOUNT=1; fi
[ "${1:-}" != --mount ] || shift
PROJ="$(cd "${1:?usage: $0 [--mount] <project dir>}" && pwd)" || exit 1
KR="$(cd "$(dirname "$0")" && pwd)" # kib's checkout: every VM here mounts it at this same path
export PATH="$PATH:$HOME/.local/bin:$HOME/.local/docker" DOCKER_CONFIG="$HOME/.local/docker"
IMG=keep-it-in-your-box P=kibprobe U="$(id -u):$(id -g)" GV=/opt/kibprobe-gvisor
VM=kib-vm SRC=$P-src
if [ -n "$MOUNT" ]; then VM=$P SRC="$HOME/.$P-proj"; fi
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
vm() { limactl shell --workdir / "$VM" sudo -n -- "$@" </dev/null; }
ok() { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; }
info() { printf '  ℹ %s\n' "$1"; }
check() { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got: $3)"; fi; }

sock() { echo "unix://$(limactl list --format '{{.Dir}}' "$1")/sock/docker.sock"; }
up() { # <vm> [create args…]
    [ "$(limactl list --format '{{.Status}}' "$1" 2>/dev/null)" = Running ] \
        || limactl start --tty=false "${@:2}" "$1" >/dev/null 2>&1 || {
        echo "cannot start $1"
        exit 1
    }
    for _ in $(seq 60); do
        DOCKER_HOST="$(sock "$1")" docker info >/dev/null 2>&1 && break
        sleep 1
    done
}
# shellcheck disable=SC2046 # ids
cleanup() {
    docker rm -f $(docker ps -aq --filter name=^$P) >/dev/null 2>&1
    docker volume rm $(docker volume ls -q --filter name=^$P) >/dev/null 2>&1
    docker network rm $P-net >/dev/null 2>&1
    # daemon.json back exactly as it was (or gone, if runsc created it), then a reload: no
    # running container restarts.
    vm sh -c "awk '\$2 ~ \"^/mnt/$P\" { print \$2 }' /proc/mounts | sort -r | xargs -r -n1 umount -l
        rm -rf /mnt/$P /var/tmp/$P-*
        if [ -f $GV/daemon.json.orig ]; then cp -a $GV/daemon.json.orig /etc/docker/daemon.json
        elif [ -f $GV/daemon.json.none ]; then rm -f /etc/docker/daemon.json; fi
        rm -rf $GV; systemctl reload docker"
    rm -f "$TAR" "$TAR.log" "$TAR.vm.log"
    [ -z "$MOUNT" ] || limactl delete -f $P >/dev/null 2>&1
    [ "$SRC" = $P-src ] || rm -rf "$SRC"
}
TAR="$(mktemp)"
trap cleanup EXIT

up kib-vm
if [ -n "$MOUNT" ]; then
    echo "⏳ a throwaway VM with ~ mounted, and kib's image copied in (a few minutes)…"
    limactl delete -f $P >/dev/null 2>&1 # a failed run's leftover
    # virtiofs if this host can (macOS always; Linux needs virtiofsd), else 9p as kib mounts it.
    mk() { limactl start --tty=false --name $P --mount-only "$HOME:w" "$@" template:docker-rootful \
        >"$TAR.vm.log" 2>&1; }
    if [ "$(uname -s)" = Darwin ]; then
        mk --vm-type=vz --mount-type=virtiofs && MT=virtiofs
    elif mk --vm-type=qemu --mount-type=virtiofs; then
        MT=virtiofs
    else
        limactl delete -f $P >/dev/null 2>&1
        mk --vm-type=qemu --mount-type=9p --set='.mounts[]."9p".cache = "none"' && MT=9p
    fi
    [ -n "${MT:-}" ] || {
        echo "cannot create the probe VM:"
        tail -n 5 "$TAR.vm.log"
        exit 1
    }
    echo "  ~ is mounted over $MT"
    up $P
    DOCKER_HOST="$(sock kib-vm)" docker save "$IMG" | DOCKER_HOST="$(sock $P)" docker load >/dev/null
fi
DOCKER_HOST="$(sock "$VM")"
export DOCKER_HOST
docker image inspect "$IMG" >/dev/null || {
    echo "no $IMG image here (error above)"
    exit 1
}

echo "⏳ installing gVisor…"
# The release archive (runsc + gvisor-bin/) in its own dir: cleanup is one rm. No && chains, so
# set -e stops at the first failure.
vm sh -c "set -e; u=https://storage.googleapis.com/gvisor/releases/release/latest/\$(uname -m)
    rm -rf $GV; mkdir -p $GV; cd $GV
    if [ -f /etc/docker/daemon.json ]; then cp -a /etc/docker/daemon.json daemon.json.orig
    else : >daemon.json.none; fi
    curl -fsSLO \"\$u/gvisor.tar.bz2\"
    curl -fsSLO \"\$u/gvisor.tar.bz2.sha512\"
    sha512sum -c gvisor.tar.bz2.sha512
    python3 -c 'import tarfile; tarfile.open(\"gvisor.tar.bz2\").extractall()' # no bzip2 here
    ./runsc install --runtime=$P-gvisor -- --host-uds=open
    if [ -e /dev/kvm ]; then ./runsc install --runtime=$P-kvm -- --platform=kvm --host-uds=open; fi
    systemctl reload docker" >/dev/null || {
    echo "runsc install failed (above)"
    exit 1
}
sleep 2
G=("--runtime=$P-gvisor")
COLS=("" "$P-gvisor") NAMES=(plain gVisor)
if docker run --rm --runtime=$P-kvm --entrypoint true "$IMG" >/dev/null 2>&1; then
    COLS+=("$P-kvm") NAMES+=(gVisor+KVM)
    ok "gVisor's KVM mode runs here"
else info "gVisor's KVM mode does not run here (no /dev/kvm, or nested)"; fi
# kib's own box flags (host/lifecycle.sh start_container)
HARD=(--init --cap-drop=ALL --cap-add=SETUID --cap-add=SETGID --cap-add=CHOWN
    --cap-add=DAC_OVERRIDE --cap-add=FOWNER --security-opt no-new-privileges)

echo "The box itself:"
check "starts under gVisor with kib's flags, and drops to a user (gosu)" docker run --rm "${G[@]}" \
    "${HARD[@]}" --entrypoint gosu "$IMG" "$U" true

echo "Network:"
docker network create $P-net >/dev/null
docker run -d --name $P-peer --network $P-net --network-alias kib-broker --entrypoint python3 \
    "$IMG" -m http.server 8100 >/dev/null
ip="$(docker inspect -f '{{(index .NetworkSettings.Networks "'$P-net'").IPAddress}}' $P-peer)"
vm sh -c "grep '^nameserver' /run/systemd/resolve/resolv.conf >/var/tmp/$P-resolv.conf"
docker create --name $P-gv "${G[@]}" --add-host "kib-broker:$ip" \
    -v /var/tmp/$P-resolv.conf:/etc/resolv.conf:ro --entrypoint sleep "$IMG" 300 >/dev/null
docker network connect $P-net $P-gv && docker start $P-gv >/dev/null
check "kib-broker as a host entry reaches the broker's port" docker exec $P-gv \
    curl -sf -o /dev/null --max-time 10 http://kib-broker:8100/
check "our own resolv.conf reaches the internet (dual-homed)" docker exec $P-gv \
    curl -s -o /dev/null --max-time 10 https://api.anthropic.com
vm sh -c "mkdir -p /var/tmp/$P-sock && chmod 777 /var/tmp/$P-sock"
srv='import socket,os
s=socket.socket(socket.AF_UNIX); s.bind("/s/sock"); os.chmod("/s/sock",0o777); s.listen()
while True:
    c,_=s.accept(); c.send(b"hi"); c.close()'
cli='import socket; s=socket.socket(socket.AF_UNIX); s.connect("/s/sock"); print(s.recv(2).decode())'
docker run -d --name $P-uds -v /var/tmp/$P-sock:/s --entrypoint python3 "$IMG" -c "$srv" >/dev/null
sleep 1
is "the box connects to a sidecar's unix socket (--host-uds=open)" hi \
    "$(docker run --rm "${G[@]}" -v /var/tmp/$P-sock:/s --entrypoint python3 "$IMG" -c "$cli" 2>&1)"

echo "kib's real redaction view (its FUSE sidecar) on a copy of $PROJ:"
(cd "$PROJ" && {
    echo .git
    git ls-files
} | tar -cf "$TAR" -T - 2>/dev/null)
docker volume create $P-cache >/dev/null
docker run --rm -v $P-cache:/c --entrypoint chown "$IMG" "$U" /c
if [ "$SRC" != $P-src ]; then # a plain folder under ~, as a real project would be
    rm -rf "$SRC" && mkdir -p "$SRC" && tar -xf "$TAR" -C "$SRC" && echo SECRET=kibprobevalue >"$SRC/.env"
else
    docker volume create $P-src >/dev/null
    docker run --rm -i -v $P-src:/w --entrypoint sh "$IMG" -c "tar -xf - -C /w &&
        echo SECRET=kibprobevalue >/w/.env && chown -R $U /w" <"$TAR"
fi
F=/mnt/$P/f
vm sh -c "mkdir -p /mnt/$P && mount --bind /mnt/$P /mnt/$P && mount --make-rshared /mnt/$P
    mkdir -p $F/mnt && chmod 755 $F $F/mnt && chown $U $F/mnt && : >/var/tmp/$P-pat
    printf 'root:x:0:0::/root:/bin/sh\nhostuser:x:${U%:*}:${U#*:}::/tmp:/bin/sh\n' >/var/tmp/$P-passwd
    printf 'root:x:0:\nhostuser:x:${U#*:}:\n' >/var/tmp/$P-group"
docker run -d --name $P-fuse --cap-drop=ALL --cap-add=SYS_ADMIN --device /dev/fuse \
    --security-opt apparmor=unconfined --user "$U" --userns=host --network none \
    -v "$SRC:/src" -v /var/tmp/$P-pat:/kib-patterns:ro -v /var/tmp/$P-passwd:/etc/passwd:ro \
    -v /var/tmp/$P-group:/etc/group:ro -v "$F:$F:rshared" -v "$KR/kib:/usr/local/lib/kib:ro" \
    -v "$KR/guest/policy/global.kibignore:/usr/local/share/global.kibignore:ro" \
    --entrypoint /usr/local/bin/fuse "$IMG" --src /src --mnt "$F/mnt" --uid "${U%:*}" --gid "${U#*:}" \
    --patterns-file /kib-patterns --guard-file /usr/local/share/global.kibignore >/dev/null
for _ in $(seq 50); do
    vm grep -q " $F/mnt fuse" /proc/mounts && break
    sleep 0.2
done
# As kib: ~/.cache on the cache volume, and both pnpm store names (pnpm 9 and 12).
BOX=(-v "$F/mnt:/w:rslave" --user "$U" -w /w -v "$P-cache:/c" -e HOME=/tmp -e XDG_CACHE_HOME=/c
    -e pnpm_config_store_dir=/c/store -e npm_config_store_dir=/c/store
    -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e "GIT_CONFIG_VALUE_0=*")
# Variation 4: pnpm's package files (the virtual store) on the cache volume, not in node_modules.
VSTORE=(-e pnpm_config_virtual_store_dir=/c/vstore -e npm_config_virtual_store_dir=/c/vstore)
if ! vm grep -q " $F/mnt fuse" /proc/mounts; then
    bad "kib's FUSE sidecar never mounted: $(docker logs $P-fuse 2>&1 | tail -3)"
    exit 1
fi
out="$(docker run --rm "${G[@]}" "${BOX[@]}" --entrypoint cat "$IMG" .env 2>&1)"
case "$out" in
    *kibprobevalue*) bad "gVisor box reads .env: the REAL value leaked" ;;
    *"<redacted>"*) ok "gVisor box reads .env as key names only (SECRET=<redacted>)" ;;
    *) bad "gVisor box reads .env: unexpected ($out)" ;;
esac
case "$(docker run --rm "${G[@]}" "${BOX[@]}" --entrypoint sh "$IMG" -c 'echo x >.git/hooks/pre-commit' 2>&1)" in
    *"ermission"* | *"not permitted"*) ok "gVisor box: writing .git/hooks is refused" ;;
    *) bad "gVisor box: writing .git/hooks was NOT refused" ;;
esac

echo "Speed through the redaction view:"
secs() { # the failure's last lines go to stderr, above the timing line
    local s log="$TAR.log"
    s=$(now)
    "$@" >"$log" 2>&1 || printf '    failed: %s\n' "$(tail -n 4 "$log")" >&2
    awk -v s="$s" -v e="$(now)" 'BEGIN { printf "%.1f", e - s }'
}
bench() { # <label> <sh command, run in the project> [extra docker args…]
    local i line base="" t
    local -a rt
    line="$(printf '  %-44s' "$1")"
    for i in "${!COLS[@]}"; do
        rt=()
        [ -z "${COLS[$i]}" ] || rt=(--runtime="${COLS[$i]}")
        t="$(secs docker run --rm ${rt[@]+"${rt[@]}"} "${BOX[@]}" "${@:3}" --entrypoint sh "$IMG" -c "$2")"
        base="${base:-$t}"
        line="$line $(printf '%s %6ss' "${NAMES[$i]}" "$t")"
        [ "$i" = 0 ] || line="$line $(awk -v a="$base" -v b="$t" 'BEGIN { printf "(×%.1f)", (a > 0 ? b / a : 0) }')"
    done
    echo "$line"
}
bench "git status ×3" 'git status >/dev/null; git status >/dev/null; git status'
bench "list every file (find)" 'find . -path ./.git -prune -o -type f -print | wc -l'
bench "write, read, delete 3000 files" 'mkdir t && for i in $(seq 3000); do echo $i >t/$i; done
    cat t/* >/dev/null; rm -rf t'

lock="$(cd "$PROJ" && git ls-files | grep -m1 -E '(^|/)pnpm-lock\.yaml$')"
if [ -z "$lock" ]; then
    info "no pnpm-lock.yaml tracked in $PROJ: no pnpm timing"
    exit 0
fi
d="$(dirname "$lock")"
echo "  (pnpm in ./$d: filling the cache once, not timed…)"
if ! docker run --rm "${BOX[@]}" --entrypoint sh "$IMG" -c "cd '$d' && pnpm install --frozen-lockfile" \
    >"$TAR.log" 2>&1; then
    info "pnpm install failed in ./$d, so no pnpm timing: $(tail -n 4 "$TAR.log")"
    exit 0
fi
inst="cd '$d' && rm -rf node_modules /c/vstore && pnpm install --prefer-offline --frozen-lockfile"
bench "pnpm install (warm cache)" "$inst"
bench "pnpm install, package files on the cache vol" "$inst" "${VSTORE[@]}"

# Does a Vite dev server still serve every file a page pulls in, with the package files outside
# the project? A crawl from / through every import, script and stylesheet; any 4xx is named.
if grep -q '"vite"' "$PROJ/$d/package.json" 2>/dev/null; then
    crawl='const b="http://127.0.0.1:5199",seen=new Set(),bad=[];
    async function get(u){if(seen.has(u)||seen.size>400)return;seen.add(u);
      let r;try{r=await fetch(b+u)}catch(e){bad.push("ERR "+u);return}
      if(r.status>=400){bad.push(r.status+" "+u);return}
      const t=await r.text();
      for(const re of [/(?:from|import)\s*\(?\s*["\x27](\/[^"\x27]+)["\x27]/g,
          /<(?:script|link)[^>]+(?:src|href)=["\x27](\/[^"\x27]+)["\x27]/g])
        for(const m of t.matchAll(re))await get(m[1])}
    get("/").then(()=>console.log(bad.length?"BAD "+bad.slice(0,4).join(" , "):"OK "+seen.size))'
    serve="cd '$d' && (pnpm exec vite --host 127.0.0.1 --port 5199 --strictPort >/tmp/v.log 2>&1 &)
        for i in \$(seq 90); do curl -s -o /dev/null http://127.0.0.1:5199/ && break; sleep 1; done
        node -e '$crawl' || tail -5 /tmp/v.log"
    for v in "normal layout" "package files on the cache volume"; do
        extra=()
        [ "$v" = "normal layout" ] || extra=("${VSTORE[@]}")
        docker run --rm "${BOX[@]}" ${extra[@]+"${extra[@]}"} --entrypoint sh "$IMG" -c "$inst" >/dev/null 2>&1
        r="$(docker run --rm "${G[@]}" "${BOX[@]}" ${extra[@]+"${extra[@]}"} --entrypoint sh "$IMG" \
            -c "$serve" 2>&1 | tail -1)"
        case "$r" in
            OK*) ok "Vite under gVisor serves every file a page loads, $v (${r#OK } files)" ;;
            *) bad "Vite under gVisor, $v: $r" ;;
        esac
    done
else info "no vite in ./$d/package.json: no dev-server check"; fi
echo "Done. Everything the probe added is being removed."
