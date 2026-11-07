#!/usr/bin/env bash
# Published ports. (The box's DNS is the VM's: vm_resolv in host/vm.sh.)
#
# Reads:  KIB_ROOT CNAME KIB_CONFIG PWD PUBLISH_LIST (set by bin/kib)
# Writes: ARGS PUBLISH_LIST PUBLISH_PINNED

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
