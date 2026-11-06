#!/usr/bin/env bash
# TMP (delete when decided): pnpm install with node_modules on a VM volume, plain vs gVisor.
# Quick (~3 min): in kib-vm, only the manifests, no install scripts. Removes all it adds.
# Usage: tmp_nm_probe.sh <dir with package.json + pnpm-lock.yaml>
set -u
D="$(cd "${1:?usage: $0 <project dir>}" && pwd)" || exit 1
export PATH="$PATH:$HOME/.local/bin:$HOME/.local/docker" DOCKER_CONFIG="$HOME/.local/docker"
IMG=keep-it-in-your-box P=kibnm GV=/opt/kibnm-gvisor U="$(id -u):$(id -g)"
DOCKER_HOST="unix://$(limactl list --format '{{.Dir}}' kib-vm)/sock/docker.sock"
export DOCKER_HOST
vm() { limactl shell --workdir / kib-vm sudo -n -- "$@" </dev/null; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
docker info >/dev/null 2>&1 || {
    echo "start kib-vm first: limactl start kib-vm"
    exit 1
}

# shellcheck disable=SC2046 # ids
cleanup() {
    docker volume rm $(docker volume ls -q --filter name=^$P) >/dev/null 2>&1
    vm sh -c "if [ -f $GV/daemon.json.orig ]; then cp -a $GV/daemon.json.orig /etc/docker/daemon.json
        elif [ -f $GV/daemon.json.none ]; then rm -f /etc/docker/daemon.json; fi
        rm -rf $GV; systemctl reload docker"
}
trap cleanup EXIT

echo "⏳ gVisor into kib-vm…"
vm sh -c "set -e; u=https://storage.googleapis.com/gvisor/releases/release/latest/\$(uname -m)
    rm -rf $GV; mkdir -p $GV; cd $GV
    if [ -f /etc/docker/daemon.json ]; then cp -a /etc/docker/daemon.json daemon.json.orig
    else : >daemon.json.none; fi
    curl -fsSLO \"\$u/gvisor.tar.bz2\"
    curl -fsSLO \"\$u/gvisor.tar.bz2.sha512\"
    sha512sum -c gvisor.tar.bz2.sha512
    python3 -c 'import tarfile; tarfile.open(\"gvisor.tar.bz2\").extractall()'
    ./runsc install --runtime=$P-gvisor
    systemctl reload docker" >/dev/null || exit 1
sleep 2

for v in src cache; do docker volume create $P-$v >/dev/null; done
# The manifests only: an install with no scripts needs nothing else.
# shellcheck disable=SC2046 # the optional files, by name
(cd "$D" && tar -cf - package.json pnpm-lock.yaml $(ls .npmrc pnpm-workspace.yaml 2>/dev/null)) \
    | docker run --rm -i -v $P-src:/w -v $P-cache:/c --entrypoint sh "$IMG" -c "tar -xf - -C /w && chown -R $U /w /c"
BOX=(-v "$P-src:/w" -v "$P-cache:/c" --user "$U" -w /w -e HOME=/tmp -e XDG_CACHE_HOME=/c
    -e pnpm_config_store_dir=/c/store -e npm_config_store_dir=/c/store --entrypoint sh "$IMG" -c)
inst='rm -rf node_modules && pnpm install --frozen-lockfile --prefer-offline --ignore-scripts'
echo "⏳ filling the package cache once (downloads; not timed)…"
docker run --rm "${BOX[@]}" "$inst" >/dev/null 2>&1 || {
    echo "the cache fill failed"
    exit 1
}
t() { # <docker args…>: seconds for one install
    local s
    s=$(now)
    docker run --rm "$@" "${BOX[@]}" "$inst" >/dev/null 2>&1 || printf '(failed) '
    awk -v s="$s" -v e="$(now)" 'BEGIN { printf "%.1f", e - s }'
}
a="$(t)" b="$(t --runtime=$P-gvisor)"
printf 'pnpm install, node_modules on a VM volume, warm cache, no scripts:\n'
printf '  plain %ss   gVisor %ss   (×%s)\n' "$a" "$b" \
    "$(awk -v a="$a" -v b="$b" 'BEGIN { printf "%.1f", (a > 0 ? b / a : 0) }')"
