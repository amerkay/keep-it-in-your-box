#!/bin/sh
# Host-side half of the macOS clipboard bridge (see start_clipboard_bridge in cc-lib.sh).
# Watches a spool dir the container writes into, answers READ requests from the host
# clipboard (pbpaste for text, an osascript PNG extraction for images), and turns a
# container WRITE attempt (a deny marker) into a desktop alert. It NEVER calls pbcopy —
# a write is impossible by construction, exactly like the Wayland guard's asymmetry.
#
# POSIX sh, stock macOS tools only. Started by cc via detach_pgrp with fds 200/201 CLOSED
# (load-bearing: it outlives the cc that starts it, so inheriting the project lock would
# stop the last terminal out from ever tearing the container down). Killed by process group
# at teardown.
#
# Protocol (files in the spool dir):
#   req.<id>   container → host: one line, the type (text | png | list)
#   resp.<id>  host → container: the answer (written via a temp + rename, so the container
#              never reads a half-written file)
#   done.<id>  host → container: empty marker, written AFTER resp — the container waits on it
#   deny.<id>  container → host: a refused write attempt; the host alerts and deletes it

DIR="${1:?usage: clipboard-bridge.sh <spool-dir> <project-name>}"
NAME="${2:-project}"
LAST_DENY=0

serve_read() { # $1 = request id, $2 = type
    id="$1"
    type="$2"
    tmp="$DIR/resp.$id.tmp"
    out="$DIR/resp.$id"
    # The spool is bind-mounted rw into the sandbox, so the container could pre-plant any of
    # these paths as a symlink to a host file — `: > "$tmp"` / `: > done` follow it and would
    # truncate the target. Unlink first: rm removes the symlink itself, so the writes below
    # always land on fresh regular files inside the spool.
    rm -f "$tmp" "$out" "$DIR/done.$id" 2>/dev/null
    case "$type" in
        list)
            : >"$tmp"
            osascript -e 'the clipboard as «class PNGf»' >/dev/null 2>&1 && printf 'image/png\n' >>"$tmp"
            printf 'text/plain\n' >>"$tmp"
            ;;
        png)
            # Raw PNG bytes from the clipboard into $tmp, or an empty file if none is set.
            osascript >/dev/null 2>&1 <<OSA || : >"$tmp"
set thePNG to (the clipboard as «class PNGf»)
set fp to open for access POSIX file "$tmp" with write permission
set eof of fp to 0
write thePNG to fp
close access fp
OSA
            ;;
        *) pbpaste >"$tmp" 2>/dev/null || : >"$tmp" ;;
    esac
    mv -f "$tmp" "$out" 2>/dev/null
    : >"$DIR/done.$id"
}

notify_deny() {
    now="$(date +%s)"
    [ $((now - LAST_DENY)) -lt 30 ] && return # rate-limit: one alert per 30s
    LAST_DENY="$now"
    osascript -e "display notification \"The sandbox tried to write your clipboard. Blocked — your next paste is safe. Project: $NAME\" with title \"cc · clipboard write blocked\"" >/dev/null 2>&1 || true
}

# The dir vanishing (teardown removed it) ends the loop; the process group is killed anyway.
while [ -d "$DIR" ]; do
    for req in "$DIR"/req.*; do
        [ -e "$req" ] || continue # no-match glob stays literal
        id="${req##*/req.}"
        # The container names req.<id>, so <id> is sandbox-controlled and ends up in spool
        # paths *and* inside an osascript string literal (serve_read png). Reject anything but
        # a safe charset: a `"` in the id would otherwise close that literal and inject
        # AppleScript the host would run. The shim's ids are always $$.<nanoseconds>.
        case "$id" in '' | *[!A-Za-z0-9._-]*)
            rm -f "$req" 2>/dev/null
            continue
            ;;
        esac
        type="$(head -n1 "$req" 2>/dev/null)"
        serve_read "$id" "$type"
        rm -f "$req" 2>/dev/null
    done
    for d in "$DIR"/deny.*; do
        [ -e "$d" ] || continue
        rm -f "$d" 2>/dev/null
        notify_deny
    done
    sleep 0.2
done
