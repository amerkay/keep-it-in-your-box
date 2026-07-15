#!/bin/sh
# Keep a long-lived cc container's /etc/resolv.conf synced to the host's live upstreams.
#
# Docker freezes a container's /etc/resolv.conf at creation. cc's container is long-lived, so
# after the host switches wifi or attaches a VPN the frozen copy points at the *previous*
# network's nameserver — unreachable now — and every lookup in every attached session times
# out (routing stays fine; only DNS breaks).
#
# systemd-resolved writes the host's real per-link upstream nameservers to
# /run/systemd/resolve/resolv.conf and rewrites it on every network change. cc bind-mounts
# that directory read-only at /run/host-resolve; this watcher copies the current upstreams
# into /etc/resolv.conf whenever they change, so the container follows the host live. Talking
# DNS straight to those real upstreams (not to the host/gateway) is also what lets this work
# behind a per-connection host firewall (e.g. Portmaster) that would hold a relay's
# container->gateway:53 hop.
#
# Runs as root (it writes /etc/resolv.conf) and loops for the container's whole life; it is
# killed when the container is removed. Dependency-free: POSIX sh + coreutils only.
#
# Deliberately conservative: it writes only real nameservers. Loopback servers (127.0.0.0/8 —
# systemd-resolved's own 127.0.0.53 stub, or a host-local filter) are useless inside the
# container's netns, so they are stripped; if that would leave zero nameservers the file is
# left untouched rather than blanked (a resolv.conf with no nameserver breaks DNS outright).

set -u

# Fixed, trusted PATH: this runs as root (detached `docker exec -u 0`), so never resolve the
# bare grep/sleep below through an inherited PATH that might front a sandbox-writable dir.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

SRC="${1:-/run/host-resolve/resolv.conf}"
DST=/etc/resolv.conf
INTERVAL="${CC_RESOLV_SYNC_INTERVAL:-3}"

last=""
while :; do
    if [ -r "$SRC" ]; then
        # Drop comments and loopback nameservers; keep search/options/real nameservers.
        cur="$(grep -v '^[[:space:]]*#' "$SRC" 2>/dev/null \
               | grep -v '^[[:space:]]*nameserver[[:space:]]\+127\.' || true)"
        # Only sync when the content changed AND at least one real nameserver survives.
        if [ "$cur" != "$last" ] \
            && printf '%s\n' "$cur" | grep -q '^[[:space:]]*nameserver[[:space:]]'; then
            if printf '%s\n' "$cur" >"$DST" 2>/dev/null; then
                last="$cur"
            fi
        fi
    fi
    sleep "$INTERVAL"
done
