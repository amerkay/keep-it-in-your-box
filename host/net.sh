#!/usr/bin/env bash
# Networking that crosses the boundary: live DNS (below) and published ports (bottom of file).
#
# DNS: follow the host's live resolver, without editing the host.
#
# A long-lived container freezes /etc/resolv.conf at creation, so after a wifi switch or VPN
# it keeps the previous network's nameserver and every lookup in every session times out
# (routing stays fine; only DNS breaks).
#
# systemd-resolved keeps the host's real per-link upstreams in /run/systemd/resolve/resolv.conf
# and rewrites it by atomic rename on every network change. kib mounts that DIRECTORY :ro — not
# the file, which would pin the old inode — and runs guest/bin/resolv-sync.sh in-container to
# copy the upstreams into /etc/resolv.conf as they change. DNS goes straight to those real
# upstreams, never via the host/gateway, which is also what makes it work behind a
# per-connection host firewall that would hold a relay's container→gateway:53 hop.
#
# Best-effort: no systemd-resolved → no mount, no watcher, Docker's frozen default. Never worse
# than the pre-fix behaviour.
#
# Reads:  KIB_ROOT CNAME KIB_CONFIG PWD PUBLISH_LIST (set by bin/kib)
# Writes: ARGS PUBLISH_LIST PUBLISH_PINNED

RESOLV_SRC_DIR=/run/systemd/resolve # host dir systemd-resolved rewrites live
RESOLV_SRC_FILE="$RESOLV_SRC_DIR/resolv.conf"

host_has_resolved() { [ -r "$RESOLV_SRC_FILE" ]; }

# Read-only bind-mounts for the live resolver dir + the watcher, added only when the host runs
# systemd-resolved.
#
# That dir also holds systemd-resolved's Varlink control sockets, and a read-only mount does
# NOT stop a connect(): they speak to the host daemon in the host's namespace, so an
# unauthenticated connect can drive host-side resolution and dump the host's DNS/interface
# topology — a live sandbox→host channel. Shadow each with /dev/null (inert char device,
# connect() → ENOTSOCK) while the dir mount still tracks resolv.conf across renames. Docker
# applies mounts parent-first, so nested shadowing works.
#
# DISCOVERED, not enumerated: the two sockets shipped today (io.systemd.Resolve and .Monitor)
# were named literally here and again in the security suite, so a third one a future systemd
# adds would be an open channel neither side noticed. Globbing fails closed instead. `-S` is
# required — the same dir holds `netif/`, a DIRECTORY, and `-v /dev/null:…` onto it aborts the
# whole `docker run`. EVERY /dev/null mount here must stay inside this `[ -e ]`-guarded loop:
# runc cannot create a mountpoint on a read-only bind, so naming a socket that is absent at
# create time aborts the launch outright (`make mountpoint …: read-only file system`). That is
# what the literal two-name mounts did before — they were not safer, they were fail-HARD on the
# same input. The residual (a socket appearing only after create is never shadowed, since the
# glob runs once over a live directory view) is therefore unfixable by unioning in the known
# names; security-test.sh globs INSIDE the container, so it fails a `deny` there instead of
# passing silently. (clipboard-and-dns.md)
add_resolv_sync_args() {
    host_has_resolved || return 0
    ARGS+=(-v "$RESOLV_SRC_DIR:/run/host-resolve:ro")
    local _s
    for _s in "$RESOLV_SRC_DIR"/io.systemd.*; do
        # Skip the unmatched glob, and skip directories — anything else matching the prefix is
        # shadowed whether or not we recognise it, which is the fail-closed half.
        [ -e "$_s" ] || continue
        [ -d "$_s" ] && continue
        ARGS+=(-v "/dev/null:/run/host-resolve/${_s##*/}:ro")
    done
    ARGS+=(-v "$KIB_ROOT/guest/bin/resolv-sync.sh:/usr/local/bin/resolv-sync.sh:ro")
}

# Start the watcher once, on the create path only (under the boot lock), so exactly one exists
# per container; it dies with the container, so there is nothing to tear down. Root (-u 0,
# bypassing the entrypoint) because it writes /etc/resolv.conf, detached because it loops.
# Only failures notify — claude's TUI wipes stderr milliseconds after launch.
start_resolv_sync() {
    if ! host_has_resolved; then
        echo "ℹ️  DNS: no systemd-resolved on this host — keeping Docker's default resolv.conf" >&2
        echo "   (frozen at creation; sessions won't follow a wifi/VPN change)." >&2
        notify_desktop normal "kib · DNS not following the host" \
            "No systemd-resolved on this host, so the sandbox keeps Docker's default DNS and won't follow a network change."
        return 0
    fi
    if docker exec -u 0 -d "$CNAME" \
        sh /usr/local/bin/resolv-sync.sh /run/host-resolve/resolv.conf 2>/dev/null; then
        echo "🌐 DNS: syncing resolv.conf to the host live — follows wifi/VPN changes." >&2
    else
        echo "⚠️  DNS: could not start the resolv.conf watcher — DNS is frozen at creation." >&2
        notify_desktop critical "kib · DNS is NOT following the host" \
            "The resolv.conf watcher failed to start; sessions won't follow a wifi/VPN change."
    fi
    return 0
}

# ── Published ports — `kib --publish 3000` ───────────────────────
# The one host→container route there is. A kib container publishes nothing by default; the host
# also cannot reach its bridge IP at all on macOS (Docker Desktop's engine VM has no docker0 on
# the host and no L3 route in — docker/for-mac#2670, closed stale). So a dev server in the box is
# unreachable from a host browser by any other means, and the documented workarounds
# (docker-mac-net-connect, a socat sidecar) all need brew/sudo or a docker command the
# contributors this exists for are not allowed to run.
#
# ALWAYS 127.0.0.1, never a bind address the caller picks: a published port is for the host's own
# browser, and 0.0.0.0 would hand a sandbox to the LAN. Host and container port are always equal —
# nothing to mismatch, and the URL a contributor is told is the URL the framework prints.
#
# Fixed at creation, like every other mount and flag: verify_publish_attach refuses a second
# terminal whose ports the running container does not have, rather than starting a session whose
# failure looks exactly like a broken dev server. (docs/design-notes/container-lifecycle.md)
KIB_PUBLISH_CONF="${KIB_PUBLISH_CONF:-${KIB_CONFIG%/*}/published-ports}"

# READ ONLY — the pin is written by publish_ports_confirm, once the container is actually up.
# Same lesson as node_versions_remember: pinning a port that docker refused (already in use on the
# host) would make every later launch retry it and die.
publish_ports_resolve() {
    if [ -n "${PUBLISH_LIST:-}" ]; then
        PUBLISH_PINNED=1
        # `none` clears the pin, wherever it appears in the list: the way back out of a port that
        # is now taken on the host, with no table to hand-edit.
        case " $PUBLISH_LIST " in *" none "*) PUBLISH_LIST="" ;; esac
    else
        PUBLISH_PINNED=0
        PUBLISH_LIST="$(sticky_get "$KIB_PUBLISH_CONF" "$PWD")"
    fi
    _publish_validate
}

# Every token must be a port number. This reaches `docker run -p` as argv, so anything else is
# refused here rather than handed to the engine — and a typo (`kib --publish claude`) gets a
# sentence instead of a docker error. Duplicates are dropped: two -p for one port is a hard
# "port is already allocated" from docker.
_publish_validate() {
    local p seen=""
    for p in ${PUBLISH_LIST:-}; do
        case "$p" in
            '' | *[!0-9]*) die "--publish takes port numbers, not '$p'." \
                "e.g. kib --publish 3000        kib --publish 3000,5173" \
                "To stop publishing anything here: kib --publish=none" ;;
        esac
        if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
            die "--publish: $p is not a port (1-65535)."
        fi
        case " $seen " in *" $p "*) continue ;; esac
        seen="${seen:+$seen }$p"
    done
    PUBLISH_LIST="$seen"
}

add_publish_args() {
    local p
    for p in ${PUBLISH_LIST:-}; do
        ARGS+=(-p "127.0.0.1:$p:$p")
    done
}

# What the RUNNING container publishes, one `<port>` per line. HostConfig.PortBindings rather than
# NetworkSettings.Ports: the latter also lists EXPOSEd ports with no binding, which are exactly the
# unreachable ones this check exists to catch.
running_published_ports() {
    docker inspect -f '{{range $p, $b := .HostConfig.PortBindings}}{{$p}}{{"\n"}}{{end}}' \
        "$CNAME" 2>/dev/null | sed 's|/tcp$||'
}

# Attach path. Ports are fixed at creation and one container serves every terminal, so a second
# terminal asking for a port the container does not have must be told, not quietly attached: the
# symptom is otherwise indistinguishable from a dev server that failed to start.
verify_publish_attach() {
    [ -n "${PUBLISH_LIST:-}" ] || return 0
    local want missing="" have
    have=" $(running_published_ports | tr '\n' ' ') "
    for want in $PUBLISH_LIST; do
        case "$have" in *" $want "*) ;; *) missing="${missing:+$missing }$want" ;; esac
    done
    [ -n "$missing" ] || return 0
    die "this project's container does not publish port(s): $missing" \
        "Published ports are fixed when the container is created, and one container serves" \
        "every terminal on this project." \
        "Close all kib sessions for this project, then relaunch:" \
        "    kib --publish $(printf '%s' "$PUBLISH_LIST" | tr ' ' ',')"
}

# After the container is up, so a docker run that failed on a taken port pins nothing. Also the
# one place the 0.0.0.0 gotcha is said: a server bound to 127.0.0.1 INSIDE the box is unreachable
# through a published port, which looks identical to the port not being published at all.
publish_ports_confirm() {
    [ "${PUBLISH_PINNED:-0}" = 1 ] && sticky_set "$KIB_PUBLISH_CONF" "$PWD" "$PUBLISH_LIST"
    [ -n "${PUBLISH_LIST:-}" ] || return 0
    local p
    for p in $PUBLISH_LIST; do
        echo "🔌 kib: http://127.0.0.1:$p → the box (remembered for this project)." >&2
    done
    echo "   Bind the server to 0.0.0.0 in there or the host cannot reach it:" >&2
    echo "   e.g. nuxt dev --host 0.0.0.0 · vite --host · next dev -H 0.0.0.0" >&2
    return 0
}
