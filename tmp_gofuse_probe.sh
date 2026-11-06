#!/usr/bin/env bash
# TMP (delete when decided): how fast can a compiled FUSE view be? kib's Python view vs go-fuse's
# stock loopback (no kib rules), as the user and as root (root enables FUSE passthrough).
# In kib-vm, on a volume copy (no virtiofs, no gVisor: the FUSE cost alone). Removes all it adds.
# Usage: tmp_gofuse_probe.sh <project dir>   (~5 min, most of it kib's Python pnpm install)
set -u
D="$(cd "${1:?usage: $0 <project dir>}" && pwd)" || exit 1
KR="$(cd "$(dirname "$0")" && pwd)" # kib-vm mounts kib's checkout at this same path
export PATH="$PATH:$HOME/.local/bin:$HOME/.local/docker" DOCKER_CONFIG="$HOME/.local/docker"
IMG=keep-it-in-your-box P=kibgf U="$(id -u):$(id -g)"
DOCKER_HOST="unix://$(limactl list --format '{{.Dir}}' kib-vm)/sock/docker.sock"
export DOCKER_HOST
docker info >/dev/null 2>&1 || {
    echo "start kib-vm first: limactl start kib-vm"
    exit 1
}
vm() { limactl shell --workdir / kib-vm sudo -n -- "$@" </dev/null; }
LOG="$(mktemp)"
cleanup() {
    docker volume rm $P-src $P-cache $P-bin >/dev/null 2>&1
    vm rm -f /var/tmp/$P-passwd /var/tmp/$P-group
    rm -f "$LOG"
}
cleanup
trap cleanup EXIT
# fusermount refuses a uid with no /etc/passwd entry.
vm sh -c "printf 'root:x:0:0::/root:/bin/sh\nhostuser:x:${U%:*}:${U#*:}::/tmp:/bin/sh\n' >/var/tmp/$P-passwd
    printf 'root:x:0:\nhostuser:x:${U#*:}:\n' >/var/tmp/$P-group"

echo "VM kernel $(vm uname -r) (passthrough needs 6.9+)"
echo "⏳ building go-fuse's loopback example…"
for v in src cache bin; do docker volume create $P-$v >/dev/null; done
docker run --rm -v $P-bin:/out golang:latest sh -c 'git clone -q --depth 1 \
    https://github.com/hanwen/go-fuse /s && cd /s && CGO_ENABLED=0 go build -o /out/loopback \
    ./example/loopback' >"$LOG" 2>&1 || {
    echo "the build failed: $(tail -n 4 "$LOG")"
    exit 1
}
# The whole repo, as a project may be a subfolder of one (pnpm runs in the subfolder).
TOP="$(git -C "$D" rev-parse --show-toplevel)" || exit 1
(cd "$TOP" && {
    echo .git
    git ls-files
} | tar -cf - -T - 2>/dev/null) | docker run --rm -i -v $P-src:/w -v $P-cache:/c \
    --entrypoint sh "$IMG" -c "tar -xf - -C /w && chown -R $U /w /c"

FUSE=(--cap-drop=ALL --cap-add=SYS_ADMIN --device /dev/fuse --security-opt apparmor=unconfined
    -v "$KR/kib:/usr/local/lib/kib:ro" -v "$KR/guest/policy/global.kibignore:/g:ro"
    -v "/var/tmp/$P-passwd:/etc/passwd:ro" -v "/var/tmp/$P-group:/etc/group:ro")
ENV=(-v "$P-src:/src" -v "$P-cache:/c" -v "$P-bin:/b" -e XDG_CACHE_HOME=/c -e pnpm_config_store_dir=/c/store
    -e npm_config_store_dir=/c/store -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory
    -e "GIT_CONFIG_VALUE_0=*" --entrypoint sh "$IMG" -c)
WAIT='for i in $(seq 50); do grep -q " /tmp/m fuse" /proc/mounts && break; sleep 0.1; done
    grep -q " /tmp/m fuse" /proc/mounts || { tail -n 3 /tmp/d >&2; exit 1; }; cd /tmp/m'
# Runs $W in the view, as the user; prints its seconds (a failure's tail goes to stderr).
TIMED='export HOME=/tmp; s=$(date +%s.%N); sh -c "$W" >/tmp/log 2>&1 || tail -n 4 /tmp/log >&2
    awk -v s=$s -v e=$(date +%s.%N) "BEGIN { printf \"%.1f\", e - s }"'
NAMES=("no FUSE" "kib Python" "Go" "Go as root")
run() { # <column index> <sh command>: seconds
    local -a as=(--user "$U")
    local pre run='sh -c "$TIMED"'
    case $1 in
        0) pre='cd /src' ;;
        1) pre=": >/tmp/p && mkdir /tmp/m && /usr/local/bin/fuse --src /src --mnt /tmp/m --uid ${U%:*} \
            --gid ${U#*:} --patterns-file /tmp/p --guard-file /g 2>/tmp/d & $WAIT" ;;
        2) pre="mkdir /tmp/m && /b/loopback -q /tmp/m /src 2>/tmp/d & $WAIT" ;;
        3)
            pre="mkdir /tmp/m && /b/loopback -q -allow-other /tmp/m /src 2>/tmp/d & $WAIT"
            as=(--user 0:0 --cap-add SETUID --cap-add SETGID)
            run="exec gosu $U $run"
            ;;
    esac
    [ "$1" = 0 ] || as+=("${FUSE[@]}")
    docker run --rm "${as[@]}" -e W="$2" -e TIMED="$TIMED" "${ENV[@]}" "$pre && $run"
}
bench() { # <label> <sh command>
    local i t base="" line
    line="$(printf '  %-34s' "$1")"
    for i in 0 1 2 3; do
        t="$(run $i "$2")" || t=fail
        base="${base:-$t}"
        line="$line $(printf '%s %6ss' "${NAMES[$i]}" "$t")"
        [ $i = 0 ] || [ "$t" = fail ] || line="$line$(awk -v a="$base" -v b="$t" 'BEGIN { printf " (×%.1f)", (a > 0 ? b / a : 0) }')"
    done
    echo "$line"
}

pt="$(docker run --rm --user 0:0 "${FUSE[@]}" "${ENV[@]}" "mkdir /tmp/m && /b/loopback -debug \
    -allow-other /tmp/m /src >/tmp/d 2>&1 & $WAIT && cat .git/HEAD >/dev/null; grep -c 'backing=[1-9]' /tmp/d")"
case "$pt" in
    0 | "") echo "FUSE passthrough as root: OFF (the kernel or the capability refused it)" ;;
    *) echo "FUSE passthrough as root: ON" ;;
esac

echo "Speed (×: against no FUSE):"
bench "git status ×3" 'git status >/dev/null; git status >/dev/null; git status'
bench "list every file (find)" 'find . -path ./.git -prune -o -type f -print | wc -l'
bench "write, read, delete 3000 files" 'mkdir t && for i in $(seq 3000); do echo $i >t/$i; done
    cat t/* >/dev/null; rm -rf t'
bench "read every tracked file" 'git ls-files -z | xargs -0 cat >/dev/null'

lock="$(cd "$D" && git ls-files --full-name | grep -m1 -E '(^|/)pnpm-lock\.yaml$')"
[ -n "$lock" ] || {
    echo "no pnpm-lock.yaml tracked: no pnpm timing"
    exit 0
}
d="$(dirname "$lock")"
echo "  (pnpm in ./$d: filling the cache once, not timed…)"
run 0 "cd '$d' && pnpm install --frozen-lockfile" >/dev/null
bench "pnpm install (warm cache)" \
    "cd '$d' && rm -rf node_modules && pnpm install --prefer-offline --frozen-lockfile"
echo "Done. Everything the probe added is being removed."
