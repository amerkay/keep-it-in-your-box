#!/usr/bin/env bash
# host/node.sh — the user-level Node version cache behind `kib --node-version=NN[,NN…]`.
#
# Reads:  NODE_VERSION_LIST (set by bin/kib), IMAGE_NAME, KIB_ROOT, KIB_CONFIG
# Writes: KIB_NODE_CACHE, NODE_VERSION, ARGS (add_node_cache_args)
#
# Nothing is baked into the image: a version is fetched once per MACHINE and mounted `:ro` into
# every project. The box is never a writer — a shared store it could write is executable content
# one project hands another — so populating runs in a sterile container instead.
# Reconstructible from the network, hence XDG_CACHE_HOME rather than kib's state root.
KIB_NODE_CACHE="${KIB_NODE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/keep-it-in-your-box/node}"

# Per-project stickiness, one `<path>=<versions>` line each. Beside the host config and NOT in the
# project: a box-writable file here would let a session choose the next session's interpreter.
KIB_NODE_CONF="${KIB_NODE_CONF:-${KIB_CONFIG%/*}/node-versions}"

_node_sticky_get() {
    [ -f "$KIB_NODE_CONF" ] || return 0
    local line found=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in "$1="*) found="${line#*=}" ;; esac # last wins
    done <"$KIB_NODE_CONF"
    printf '%s' "$found"
}

_node_sticky_set() {
    local path="$1" versions="$2" tmp line
    mkdir -p "${KIB_NODE_CONF%/*}" 2>/dev/null || return 0
    tmp="$KIB_NODE_CONF.$$"
    : >"$tmp" 2>/dev/null || return 0
    if [ -f "$KIB_NODE_CONF" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in "$path="*) ;; *) printf '%s\n' "$line" >>"$tmp" ;; esac
        done <"$KIB_NODE_CONF"
    fi
    printf '%s=%s\n' "$path" "$versions" >>"$tmp"
    mv -f "$tmp" "$KIB_NODE_CONF" 2>/dev/null || rm -f "$tmp" # rename: no half-written table
}

# READ ONLY — the pin is written by node_versions_remember, after the fetch worked. Writing it
# here bricked the project on a failed fetch: every later launch retried it and died.
node_versions_resolve() {
    if [ -n "${NODE_VERSION_LIST:-}" ]; then
        NODE_VERSION_PINNED=1
    else
        NODE_VERSION_PINNED=0
        NODE_VERSION_LIST="$(_node_sticky_get "$PWD")"
        [ -z "$NODE_VERSION_LIST" ] \
            || echo "🟩 kib: Node $NODE_VERSION_LIST — remembered for this project." >&2
    fi
    # shellcheck disable=SC2034  # read by host/lifecycle.sh (kib_run_session)
    NODE_VERSION="${NODE_VERSION_LIST%% *}"
}

node_versions_remember() {
    [ "${NODE_VERSION_PINNED:-0}" = 1 ] || return 0
    _node_sticky_set "$PWD" "$NODE_VERSION_LIST"
}

# Mirrors the guest's resolve_node_version glob — opposite sides of the boundary, no shared code.
_node_cached_dir() {
    local want="${1#v}" d
    for d in "$KIB_NODE_CACHE/v$want" "$KIB_NODE_CACHE/v${want%%.*}".*; do
        [ -x "$d/bin/node" ] && {
            printf '%s\n' "$d"
            return 0
        }
    done
    return 0
}

# Unconditional, and independent of --node-version: a bind is a live view, so a version cached
# later appears in containers that already exist. That is what keeps the flag per-terminal with
# no attach-refusal, and an empty cache is a perfectly good empty directory.
add_node_cache_args() {
    mkdir -p "$KIB_NODE_CACHE" 2>/dev/null || true
    [ -d "$KIB_NODE_CACHE" ] || return 0
    ARGS+=(-v "$KIB_NODE_CACHE:/opt/nvm-versions:ro")
}

ensure_node_cached() {
    [ -n "${NODE_VERSION_LIST:-}" ] || return 0
    mkdir -p "$KIB_NODE_CACHE" || die "cannot create the Node cache at $KIB_NODE_CACHE"

    # Never unlinked: a lock file whose inode another process holds lets the next lock a fresh one.
    local lock="$KIB_NODE_CACHE/.fetch.lock" want
    : >>"$lock" 2>/dev/null || true

    for want in $NODE_VERSION_LIST; do
        [ "$want" != system ] || continue # the guest resolves this to a no-op
        [ -z "$(_node_cached_dir "$want")" ] || continue

        echo "📦 kib: caching Node $want (once per machine, shared by every project)…" >&2

        # Sterile: no project, no credentials, no broker net, no caps. --entrypoint is
        # load-bearing — the image's ENTRYPOINT is the session setup, which would run instead and
        # die on the HOST_UID this deliberately withholds. The interpreter is named rather than
        # trusted, as add_resolv_sync_args does: a bind carries the HOST file's mode.
        lock_fd -w 600 "$lock" \
            docker run --rm \
            --entrypoint bash \
            --user "$(id -u):$(id -g)" \
            --cap-drop ALL \
            --security-opt no-new-privileges \
            -e HOME=/tmp \
            -v "$KIB_NODE_CACHE:/store" \
            -v "$KIB_ROOT/guest/bin/node-fetch.sh:/usr/local/bin/node-fetch.sh:ro" \
            "$IMAGE_NAME" /usr/local/bin/node-fetch.sh "$want" \
            || die "could not cache Node $want." \
                "Nothing was pinned, so a plain \`kib\` here still works." \
                "To clear a pin that is already stored: kib --node-version=system"
    done
}
