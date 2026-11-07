#!/usr/bin/env bash
# Clipboard mediation: a spool bridge, no socket. A host-side watcher (host/clipboard-bridge.sh)
# serves a spool dir bind-mounted at /kib-clip: the entrypoint's shims drop a request file and
# read the response, the host answers reads with pbpaste or wl-paste, and a WRITE reaches the
# host clipboard only through kib.shared.clipboard, which strips control characters. A verbatim
# write is host code execution at your next terminal paste: an embedded ESC[201~ ends bracketed
# paste early and the rest is typed input (audit H8).
#
# Fail-soft, unlike the FUSE sidecar: losing image paste is not a security hole.
#
# Reads:  KIB_ROOT CLIP_STATE CLIP_HOST PWD
# Writes: ARGS

start_clipboard_bridge() {
    command -v pbpaste >/dev/null 2>&1 || command -v wl-paste >/dev/null 2>&1 || {
        echo "ℹ️  clipboard: no pbpaste or wl-paste (wl-clipboard) — host paste is unavailable." >&2
        return 0
    }
    mkdir -p "$CLIP_STATE"
    chmod 755 "$CLIP_STATE" # the container traverses this as root before gosu
    # 200>&- 201>&- is LOAD-BEARING: it outlives kib, and holding the project lock would stop
    # the last terminal out from ever tearing down.
    local s="$CLIP_STATE" p="$CLIP_HOST.priv"
    detach_pgrp "$KIB_ROOT/host/clipboard-bridge.sh" "$s" "${PWD##*/}" "$p" 200>&- 201>&- 205>&-
    # The pid file is never in the spool: $CLIP_STATE is bind-mounted rw, so
    # a file there is sandbox-writable, and teardown `kill -TERM -<pid>`s whatever it reads —
    # a sandbox that could write 1 there would turn teardown into a host process-group kill.
    echo $! >"$CLIP_HOST.pid"
    disown 2>/dev/null || true

    # PROVE it serves before claiming it does: the bridge is exec'd, so a lost exec bit dies
    # instantly, and this line printed unconditionally was the only signal for the life of the
    # feature. `ping` is answered without touching the pasteboard — no TCC prompt.
    _CLIP_PROBE="probe.$$"
    printf 'ping\n' >"$CLIP_STATE/req.$_CLIP_PROBE" 2>/dev/null || true
    if wait_until 60 0.05 _clip_bridge_answered; then # ≤3s
        echo "📋 clipboard: bridge active (writes reach the host as plain text only)" >&2
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
    kill_pgrp "$CLIP_HOST.pid" # whole group: the bridge is its own (detach_pgrp)
    # .priv is the bridge's host-private staging dir (clipboard-bridge.sh). Its own EXIT trap
    # normally clears it; this covers the SIGKILL that skips the trap.
    rm -rf "$CLIP_STATE" "$CLIP_HOST.priv" 2>/dev/null || true
}
