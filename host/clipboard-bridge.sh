#!/bin/sh
# Host-side half of the macOS clipboard bridge (start_clipboard_bridge in host/desktop.sh has
# the why). Watches the spool dir the container writes into, answers READ requests from the
# host clipboard, and turns a WRITE attempt into a desktop alert. It NEVER calls pbcopy, so a
# write is impossible by construction.
#
# POSIX sh, stock macOS tools. Started via detach_pgrp with fds 200/201 CLOSED (load-bearing —
# it outlives the kib that starts it); killed by process group at teardown.
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

# Write one pasteboard flavour to a file; non-zero (and no file) if it cannot be coerced.
# The only place that speaks AppleScript, so `list` and `png` cannot disagree about what
# counts as an image — they did, and only `list` was ever right.
grab_flavour() { # $1 = AppleScript class, $2 = destination
    rm -f "$2" 2>/dev/null
    osascript >/dev/null 2>&1 <<OSA || return 1
set theData to (the clipboard as «class $1»)
set fp to open for access POSIX file "$2" with write permission
set eof of fp to 0
write theData to fp
close access fp
OSA
    [ -s "$2" ]
}

# PNG bytes from the clipboard into $1, or a non-zero return and no file.
#
# ⌘⌃⇧4 puts a screenshot on the pasteboard as TIFF — `«class PNGf»` alone fails outright on
# it, which is why the bridge answered "text/plain only" with a screenshot sitting right
# there. Try PNGf first (already the target format, no conversion), then TIFF through `sips`
# (stock macOS). Order matters only for cost, not correctness.
grab_png() { # $1 = destination
    grab_flavour PNGf "$1" && return 0
    grab_flavour TIFF "$1.tiff" || return 1
    sips -s format png "$1.tiff" --out "$1" >/dev/null 2>&1
    rm -f "$1.tiff" 2>/dev/null
    [ -s "$1" ]
}

serve_read() { # $1 = request id, $2 = type
    id="$1"
    type="$2"
    tmp="$DIR/resp.$id.tmp"
    out="$DIR/resp.$id"
    # The spool is bind-mounted rw, so the container could pre-plant these paths as symlinks to
    # host files, and `: >` would follow one and truncate the target. rm removes the symlink
    # itself, so the writes below always land on fresh regular files inside the spool.
    rm -f "$tmp" "$out" "$DIR/done.$id" 2>/dev/null
    case "$type" in
        # Liveness probe (start_clipboard_bridge). Deliberately never touches the pasteboard:
        # a launch-time clipboard read would be a TCC prompt and a needless copy of the user's
        # clipboard into the spool.
        ping) printf 'pong\n' >"$tmp" ;;
        # Every flavour the pasteboard actually holds — the diagnostic to reach for when an
        # image paste comes back empty, because it names what IS there, not what we can read.
        info) osascript -e 'clipboard info' >"$tmp" 2>&1 || : >"$tmp" ;;
        list)
            # Answered by the same extraction `png` uses, so "offered" always means "readable".
            : >"$tmp"
            if grab_png "$DIR/probe.$id"; then printf 'image/png\n' >"$tmp"; fi
            rm -f "$DIR/probe.$id" 2>/dev/null
            printf 'text/plain\n' >>"$tmp"
            ;;
        png) grab_png "$tmp" || : >"$tmp" ;;
        *) pbpaste >"$tmp" 2>/dev/null || : >"$tmp" ;;
    esac
    mv -f "$tmp" "$out" 2>/dev/null
    : >"$DIR/done.$id"
}

notify_deny() {
    now="$(date +%s)"
    [ $((now - LAST_DENY)) -lt 30 ] && return # rate-limit: one alert per 30s
    LAST_DENY="$now"
    osascript -e "display notification \"The sandbox tried to write your clipboard. Blocked — your next paste is safe. Project: $NAME\" with title \"kib · clipboard write blocked\"" >/dev/null 2>&1 || true
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
