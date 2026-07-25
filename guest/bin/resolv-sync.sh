#!/bin/sh
# Copies the host's live upstreams from /run/host-resolve (mounted :ro by host/net.sh, which
# has the why) into /etc/resolv.conf as they change, so a long-lived container follows the host
# across wifi/VPN switches instead of keeping the frozen nameserver it was created with.
#
# Runs as root for the container's whole life; killed with the container. POSIX sh + coreutils.
#
# Conservative on purpose: loopback nameservers (127.0.0.0/8 — resolved's own stub, a host
# filter) are useless in the container netns and are stripped, and if that leaves none the file
# is left untouched rather than blanked, since a resolv.conf with no nameserver breaks DNS.

set -u

# Fixed, trusted PATH: this runs as root, so never resolve the bare grep/sleep below through an
# inherited PATH that might front a sandbox-writable dir.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

SRC="${1:-/run/host-resolve/resolv.conf}"
# DST is overridable ONLY so the check suite can point it at a temp file. The agent cannot
# influence it — the env of this detached `docker exec -u 0` is set by kib, not the session.
DST="${KIB_RESOLV_DST:-/etc/resolv.conf}"
INTERVAL="${KIB_RESOLV_SYNC_INTERVAL:-3}"

# Docker's embedded DNS (127.0.0.11) resolves user-network aliases, which the broker's
# `kib-broker` alias depends on. It exists only in the container's resolv.conf, never the
# host's, so capture it ONCE before the loop first overwrites DST and keep it FIRST in every
# write. The order is load-bearing: glibc takes the first nameserver's NXDOMAIN without trying
# the rest, so a host upstream in front would make `kib-broker` unresolvable mid-session.
# Empty when the container is on the default bridge only (broker off) — behaviour unchanged.
EMBEDDED="$(grep '^[[:space:]]*nameserver[[:space:]]\{1,\}127\.0\.0\.11' "$DST" 2>/dev/null | head -1 || true)"

last=""
while :; do
    if [ -r "$SRC" ]; then
        # Drop comments and loopback nameservers; keep search/options/real nameservers.
        cur="$(grep -v '^[[:space:]]*#' "$SRC" 2>/dev/null \
            | grep -v '^[[:space:]]*nameserver[[:space:]]\+127\.' || true)"
        # Only sync when the content changed AND at least one real nameserver survives.
        if [ "$cur" != "$last" ] \
            && printf '%s\n' "$cur" | grep -q '^[[:space:]]*nameserver[[:space:]]'; then
            # Prepend the embedded resolver (if any) so container-alias resolution survives
            # the sync while external lookups still follow the host's live upstreams.
            if [ -n "$EMBEDDED" ]; then
                out="$(printf '%s\n%s' "$EMBEDDED" "$cur")"
            else
                out="$cur"
            fi
            if printf '%s\n' "$out" >"$DST" 2>/dev/null; then
                last="$cur"
            fi
        fi
    fi
    sleep "$INTERVAL"
done
