#!/usr/bin/env bash
# Clipboard mediation: a filtering Wayland proxy on Linux, a one-way pbpaste bridge on macOS.
#
# The socket is mounted for pasting an image *from* the host clipboard, but a raw socket also
# grants clipboard WRITES, and a *verbatim* write is host code execution at your next terminal
# paste: an embedded ESC[201~ ends bracketed paste early and the rest is interpreted as typed
# input (audit H8). So the main container never sees the real socket. A sidecar runs
# kib.guest.wayland_guard, which relays the protocol, forwards reads verbatim and strips
# control characters out of every write in flight — the content is the boundary, since nothing
# in here can tell the agent's own copy from a script's. Host-side select+copy is unaffected —
# your terminal is a host client and never comes through here.
#
# Fail-soft, unlike the FUSE sidecar: no Wayland or no proxy means no socket is mounted at all.
# Losing image paste is not a security hole; falling back to the raw socket would be.
#
# Reads:  KIB_ROOT IMAGE_NAME WL_CNAME WL_ROOT CLIP_STATE PWD
# Writes: ARGS

WL_HOST_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY:-wayland-0}"

host_has_wayland() { [ -S "$WL_HOST_SOCK" ]; }

# Mount args for the main container — only the *proxied* socket, never the real one. Always
# exposed as wayland-0 inside, whatever the host display is called.
add_wayland_args() {
    [ -S "$WL_ROOT/wayland-0" ] || return 0
    ARGS+=(
        -e XDG_RUNTIME_DIR="/run/user/$(id -u)"
        -e WAYLAND_DISPLAY=wayland-0
        -v "$WL_ROOT/wayland-0:/run/user/$(id -u)/wayland-0"
    )
}

# Raises a proxy event as a desktop notification — the sidecar has no desktop session of its
# own. STRIP is the interesting one: an ordinary copy is silent, so a line here means the box
# wrote something that CONTAINED a paste escape, which is worth seeing.
#
# setsid + a pid file so teardown kills the whole pipeline by process group (a plain kill
# leaves `docker logs -f` running). One alert per 30s, so a wl-copy loop cannot spam the desktop.
#
# 200>&- 201>&- is LOAD-BEARING: this follower outlives the kib that started it, and inheriting
# the project's shared lock would stop the last terminal out from ever taking it exclusively —
# teardown never runs and the container is stranded. Shipped that way once.
start_wayland_notifier() {
    command -v notify-send >/dev/null 2>&1 || return 0
    # shellcheck disable=SC2016  # the body is the inner sh's script — its $vars are its own
    setsid sh -c '
        last=0
        docker logs -f "$1" 2>&1 | while IFS= read -r line; do
            case "$line" in
                WLGUARD-STRIP*) t="clipboard write cleaned"
                    b="Control characters were stripped from a write by the sandbox — your next paste is safe." ;;
                WLGUARD-DENY*)  t="clipboard write blocked"
                    b="A clipboard write from the sandbox was refused — not plain text, too large, or an unrecognised clipboard protocol. Your clipboard is unchanged." ;;
                WLGUARD-ERROR*) t="clipboard proxy failed"
                    b="The proxy could not reach the compositor: paste into the sandbox will not work this session." ;;
                *) continue ;;  # READY is a breadcrumb, not a problem
            esac
            now=$(date +%s)
            [ $((now - last)) -lt 30 ] && continue
            last=$now
            notify-send -u critical -i dialog-error "kib · $t" "$b Project: $2" || true
        done' _ "$WL_CNAME" "$(basename "$PWD")" \
        >/dev/null 2>&1 200>&- 201>&- &
    echo $! >"$WL_ROOT/notify.pid"
}

_wl_socket_up() { [ -S "$WL_ROOT/wayland-0" ]; }

start_wayland_guard() {
    if ! host_has_wayland; then
        echo "ℹ️  clipboard: no Wayland socket on this host — image paste unavailable." >&2
        return 0
    fi
    mkdir -p "$WL_ROOT"
    chmod 755 "$WL_ROOT" # the main container traverses this as root before gosu

    # The real socket is mounted read-only: that does not stop a connect(), which is exactly
    # what the proxy needs and all it gets. --network none because it speaks only AF_UNIX.
    if ! docker run -d --name "$WL_CNAME" \
        --cap-drop=ALL --security-opt no-new-privileges --network none \
        --user "$(id -u):$(id -g)" --userns=host \
        -v "$WL_HOST_SOCK:/run/host-wayland.sock:ro" \
        -v "$WL_ROOT:$WL_ROOT" \
        -v /etc/passwd:/etc/passwd:ro \
        -v /etc/group:/etc/group:ro \
        -v "$KIB_ROOT/kib:/usr/local/lib/kib:ro" \
        --entrypoint /usr/local/bin/wayland-guard \
        "$IMAGE_NAME" \
        --upstream /run/host-wayland.sock \
        --listen "$WL_ROOT/wayland-0" >/dev/null 2>&1; then
        warn "could not start the clipboard proxy — image paste is unavailable this session."
        rm -rf "$WL_ROOT" 2>/dev/null || true
        return 0
    fi

    if ! wait_until 100 0.05 _wl_socket_up; then # ≤5s for the proxy to bind
        warn "the clipboard proxy never came up; image paste is unavailable. Logs:" \
            "$(docker logs "$WL_CNAME" 2>&1 | tail -5)"
        docker rm -f "$WL_CNAME" >/dev/null 2>&1 || true
        rm -rf "$WL_ROOT" 2>/dev/null || true
        return 0
    fi
    start_wayland_notifier
    echo "📋 clipboard: mediated (reads pass; writes stripped of control chars; $WL_CNAME)" >&2
}

stop_wayland_guard() {
    local pid
    pid="$(cat "$WL_ROOT/notify.pid" 2>/dev/null || true)"
    # Negative pid: the notifier is a setsid'd pipeline, so kill the whole process group.
    if [ -n "$pid" ]; then
        kill -TERM "-$pid" 2>/dev/null || true
    fi
    docker rm -f "$WL_CNAME" >/dev/null 2>&1 || true
    rm -rf "$WL_ROOT" 2>/dev/null || true
}

# ── Clipboard on macOS: a one-way pbpaste bridge, no socket ──────
# macOS has no socket to proxy, so instead of a protocol proxy a host-side watcher
# (host/clipboard-bridge.sh) serves a spool dir bind-mounted at /kib-clip: the entrypoint's
# shims drop a request file and read the response, the host answers reads with pbpaste or an
# osascript PNG extraction, and a WRITE reaches pbcopy only through kib.shared.clipboard — the
# same filter the Wayland guard applies in flight, so both platforms strip the same bytes.
start_clipboard_bridge() {
    is_macos || return 0
    command -v pbpaste >/dev/null 2>&1 || {
        echo "ℹ️  clipboard: pbpaste not found — paste from the host is unavailable." >&2
        return 0
    }
    mkdir -p "$CLIP_STATE"
    chmod 755 "$CLIP_STATE" # the container traverses this as root before gosu
    # 200>&- 201>&- is LOAD-BEARING — see start_wayland_notifier.
    detach_pgrp "$KIB_ROOT/host/clipboard-bridge.sh" "$CLIP_STATE" "$(basename "$PWD")" 200>&- 201>&-
    # The pid file is a SIBLING of the spool, not inside it: $CLIP_STATE is bind-mounted rw, so
    # a file there is sandbox-writable, and teardown `kill -TERM -<pid>`s whatever it reads —
    # a sandbox that could write 1 there would turn teardown into a host process-group kill.
    echo $! >"${CLIP_STATE}.pid"
    disown 2>/dev/null || true

    # PROVE it serves before claiming it does: the bridge is exec'd, so a lost exec bit dies
    # instantly, and this line printed unconditionally was the only signal for the life of the
    # feature. `ping` is answered without touching the pasteboard — no TCC prompt.
    _CLIP_PROBE="probe.$$"
    printf 'ping\n' >"$CLIP_STATE/req.$_CLIP_PROBE" 2>/dev/null || true
    if wait_until 60 0.05 _clip_bridge_answered; then # ≤3s
        echo "📋 clipboard: pbpaste bridge active (read-only from the sandbox)" >&2
    else
        warn "the clipboard bridge did not answer — image paste is unavailable this session." \
            "$KIB_ROOT/host/clipboard-bridge.sh must be executable."
        stop_clipboard_bridge # drops the spool, so no mount and no reader env is advertised
    fi
    rm -f "$CLIP_STATE/req.$_CLIP_PROBE" "$CLIP_STATE/resp.$_CLIP_PROBE" \
        "$CLIP_STATE/done.$_CLIP_PROBE" 2>/dev/null || true
    unset _CLIP_PROBE
}

_clip_bridge_answered() { [ -e "$CLIP_STATE/done.$_CLIP_PROBE" ]; }

add_clipboard_bridge_args() {
    [ -d "$CLIP_STATE" ] || return 0
    ARGS+=(
        -v "$CLIP_STATE:/kib-clip"
        -e KIB_CLIP_BRIDGE=1
        # No DISPLAY here on purpose. Claude's image paste is a plain `xclip … || wl-paste …`
        # chain that consults neither this nor WAYLAND_DISPLAY, and faking an X server would
        # only mislead GUI-detecting callers (chrome under chrome-devtools-mcp).
        -e WAYLAND_DISPLAY=kib-clip
        -e XDG_RUNTIME_DIR="/run/user/$(id -u)"
    )
}

stop_clipboard_bridge() {
    is_macos || return 0
    local pid
    pid="$(cat "${CLIP_STATE}.pid" 2>/dev/null || true)"
    # Numeric-only, even though the pid file is host-only: `kill -TERM -<pid>` signals a
    # whole process group, so a non-numeric or empty value must never reach it.
    case "$pid" in '' | *[!0-9]*) pid="" ;; esac
    # Negative pid: the bridge runs in its own process group (detach_pgrp).
    if [ -n "$pid" ]; then
        kill -TERM "-$pid" 2>/dev/null || true
    fi
    rm -f "${CLIP_STATE}.pid" 2>/dev/null || true
    rm -rf "$CLIP_STATE" 2>/dev/null || true
}
