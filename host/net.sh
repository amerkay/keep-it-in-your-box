#!/usr/bin/env bash
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
# Reads:  KIB_ROOT CNAME
# Writes: ARGS

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
