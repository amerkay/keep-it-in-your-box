#!/usr/bin/env bash
# TMP (delete at merge): the Go view's real-mount tests (guest/fuse/mount_test.go) in kib-vm,
# which has FUSE. CI runs them too. ~1 min; removes all it adds.
set -u
KR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$PATH:$HOME/.local/bin:$HOME/.local/docker" DOCKER_CONFIG="$HOME/.local/docker"
DOCKER_HOST="unix://$(limactl list --format '{{.Dir}}' kib-vm)/sock/docker.sock"
export DOCKER_HOST
docker info >/dev/null 2>&1 || {
    echo "start kib-vm first: limactl start kib-vm"
    exit 1
}
tar -C "$KR" -cf - guest/fuse guest/policy/global.kibignore tests/fixtures/redaction \
    | docker run --rm -i --device /dev/fuse --cap-add SYS_ADMIN --security-opt apparmor=unconfined \
        -e KIB_FUSE_TESTS=1 golang:1.27-trixie sh -c \
        'mkdir /k && tar -xf - -C /k && cd /k/guest/fuse && go vet ./... && go test -count=1 ./... && go test -count=1 -run TestMount -v ./... | grep -c "^    --- PASS"'
