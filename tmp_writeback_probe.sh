#!/usr/bin/env bash
# TMP (delete when decided): does the kernel's FUSE writeback cache speed up small writes without
# delaying edits? kib's Python view vs a go-fuse loopback, without and with writeback. In kib-vm,
# on an empty volume: touches none of your files, removes all it adds. ~2 min.
set -u
KR="$(cd "$(dirname "$0")" && pwd)" # kib-vm mounts kib's checkout at this same path
export PATH="$PATH:$HOME/.local/bin:$HOME/.local/docker" DOCKER_CONFIG="$HOME/.local/docker"
IMG=keep-it-in-your-box P=kibwb U="$(id -u):$(id -g)"
GOFUSE=78661f4000937c1ea0d6328a4d59cace71f29ffa # master: the INIT hook is in no release yet
DOCKER_HOST="unix://$(limactl list --format '{{.Dir}}' kib-vm)/sock/docker.sock"
export DOCKER_HOST
docker info >/dev/null 2>&1 || {
    echo "start kib-vm first: limactl start kib-vm"
    exit 1
}
vm() { limactl shell --workdir / kib-vm sudo -n -- "$@" </dev/null; }
cleanup() {
    docker volume rm $P-src $P-bin >/dev/null 2>&1
    vm rm -f /var/tmp/$P-passwd /var/tmp/$P-group
}
cleanup
trap cleanup EXIT
# fusermount refuses a uid with no /etc/passwd entry.
vm sh -c "printf 'root:x:0:0::/root:/bin/sh\nhostuser:x:${U%:*}:${U#*:}::/tmp:/bin/sh\n' >/var/tmp/$P-passwd
    printf 'root:x:0:\nhostuser:x:${U#*:}:\n' >/var/tmp/$P-group"
for v in src bin; do docker volume create $P-$v >/dev/null; done
docker run --rm -v $P-src:/w --entrypoint chown "$IMG" "$U" /w

echo "⏳ building a go-fuse loopback with a -writeback switch…"
out="$(
    docker run --rm -i -v $P-bin:/out golang:latest sh -c "mkdir /p && cd /p && cat >main.go
    go mod init probe && go get github.com/hanwen/go-fuse/v2@$GOFUSE && go mod tidy
    CGO_ENABLED=0 go build -o /out/loopback ." 2>&1 <<'EOF'
package main

import (
	"context"
	"flag"
	"log"
	"syscall"
	"time"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
)

type node struct{ fs.LoopbackNode }

// The writeback cache reads partial pages back, so a write-only open must also read.
func rw(flags uint32) uint32 {
	if flags&syscall.O_ACCMODE == syscall.O_WRONLY {
		flags = flags&^syscall.O_ACCMODE | syscall.O_RDWR
	}
	return flags
}

func (n *node) Open(ctx context.Context, flags uint32) (fs.FileHandle, uint32, syscall.Errno) {
	return n.LoopbackNode.Open(ctx, rw(flags))
}

func (n *node) Create(ctx context.Context, name string, flags, mode uint32,
	out *fuse.EntryOut) (*fs.Inode, fs.FileHandle, uint32, syscall.Errno) {
	return n.LoopbackNode.Create(ctx, name, rw(flags), mode, out)
}

func main() {
	wb := flag.Bool("writeback", false, "the kernel's writeback cache")
	flag.Parse()
	var st syscall.Stat_t
	if err := syscall.Stat(flag.Arg(1), &st); err != nil {
		log.Fatal(err)
	}
	root := &fs.LoopbackRoot{Path: flag.Arg(1), Dev: uint64(st.Dev)}
	root.NewNode = func(r *fs.LoopbackRoot, _ *fs.Inode, _ string, _ *syscall.Stat_t) fs.InodeEmbedder {
		return &node{fs.LoopbackNode{RootData: r}}
	}
	root.RootNode = root.NewNode(root, nil, "", &st)
	sec := time.Second
	opts := &fs.Options{AttrTimeout: &sec, EntryTimeout: &sec}
	if *wb {
		opts.InitHandler = func(in *fuse.InitIn, out *fuse.InitOut) {
			if in.Flags&fuse.CAP_WRITEBACK_CACHE == 0 {
				log.Fatal("the kernel offers no writeback cache")
			}
			out.Flags |= fuse.CAP_WRITEBACK_CACHE
		}
	}
	srv, err := fs.Mount(flag.Arg(0), root.RootNode, opts)
	if err != nil {
		log.Fatal(err)
	}
	srv.Wait()
}
EOF
)" || {
    echo "the build failed: $(echo "$out" | tail -n 4)"
    exit 1
}

FUSE=(--cap-drop=ALL --cap-add=SYS_ADMIN --device /dev/fuse --security-opt apparmor=unconfined
    -v "$KR/kib:/usr/local/lib/kib:ro" -v "$KR/guest/policy/global.kibignore:/g:ro"
    -v "/var/tmp/$P-passwd:/etc/passwd:ro" -v "/var/tmp/$P-group:/etc/group:ro")
WAIT='for i in $(seq 50); do grep -q " /tmp/m fuse" /proc/mounts && break; sleep 0.1; done
    grep -q " /tmp/m fuse" /proc/mounts || { tail -n 3 /tmp/d >&2; exit 1; }'
# $B is the box's view of the folder, $H the host's (the real files). Prints one number.
LIB='ms() { echo $(($(date +%s%N) / 1000000)); }
    upto() { s=$(ms); while ! eval "$1" 2>/dev/null; do
        [ $(($(ms) - s)) -lt 5000 ] || { echo 5000; return; }; done; echo $(($(ms) - s)); }
    worst() { w=0; for i in $(seq 10); do eval "$1"; t=$(upto "$2"); [ "$t" -le $w ] || w=$t; done
        echo $w; }'
NAMES=("no FUSE" "kib Python" "Go" "Go + writeback")
run() { # <column> <sh command>
    local pre="B=/src"
    case $1 in
        1) pre=": >/tmp/p && mkdir /tmp/m && { /usr/local/bin/fuse --src /src --mnt /tmp/m \
            --uid ${U%:*} --gid ${U#*:} --patterns-file /tmp/p --guard-file /g 2>/tmp/d & } && $WAIT
            B=/tmp/m" ;;
        2) pre="mkdir /tmp/m && { /b/loopback /tmp/m /src 2>/tmp/d & } && $WAIT && B=/tmp/m" ;;
        3) pre="mkdir /tmp/m && { /b/loopback -writeback /tmp/m /src 2>/tmp/d & } && $WAIT && B=/tmp/m" ;;
    esac
    local -a f=()
    [ "$1" = 0 ] || f=("${FUSE[@]}")
    docker run --rm --user "$U" ${f[@]+"${f[@]}"} -v $P-src:/src -v $P-bin:/b -e W="$2" \
        --entrypoint sh "$IMG" -ec "$pre; H=/src; $LIB; rm -rf /src/*; eval \"\$W\"" 2>&1 | tail -n 1
}
row() { # <label> <unit> <sh command>
    local i line
    line="$(printf '  %-40s' "$1")"
    for i in 0 1 2 3; do line="$line $(printf '%s %6s%s' "${NAMES[$i]}" "$(run $i "$3")" "$2")"; done
    echo "$line"
}

echo "Worst of 10 rounds, in ms (5000 = never arrived):"
row "Claude edits a file → host has it" ms \
    'worst "printf \"edit \$i\\n\" >\$B/e.txt" "[ \"\$(cat \$H/e.txt)\" = \"edit \$i\" ]"'
row "editor save (temp + rename) → host has it" ms \
    'worst "printf \"save \$i\\n\" >\$B/.s && mv \$B/.s \$B/s.txt" "[ \"\$(cat \$H/s.txt)\" = \"save \$i\" ]"'
row "host edit, new size → box reads it" ms \
    'worst "seq \$i >\$H/h.txt" "[ \"\$(cat \$B/h.txt)\" = \"\$(seq \$i)\" ]"'
row "host edit, same size → box reads it" ms \
    'worst "printf \"host %02d\\n\" \$i >\$H/g.txt" "[ \"\$(cat \$B/g.txt)\" = \"\$(printf \"host %02d\" \$i)\" ]"'
row "box appends 200 lines → host has" /200 \
    'for j in $(seq 200); do echo $j >>$B/a.txt; done; wc -l <$H/a.txt'
row "write, read, delete 3000 files" ms \
    's=$(ms); mkdir $B/t; for j in $(seq 3000); do echo $j >$B/t/$j; done; cat $B/t/* >/dev/null
    rm -rf $B/t; echo $(($(ms) - s))'
echo "Done. Everything the probe added is being removed."
