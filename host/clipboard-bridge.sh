#!/bin/sh
# Host-side half of the macOS clipboard bridge (start_clipboard_bridge in host/desktop.sh has
# the why). Watches the spool dir the container writes into, answers READ requests from the
# host clipboard, and serves WRITE requests through the sanitiser before pbcopy — never
# verbatim, because a verbatim write is host code execution at the user's next terminal paste.
#
# The filter is kib.shared.clipboard, the SAME one the Wayland guard applies in flight on
# Linux; a second copy in sh would drift, and the drift is a platform where the escape
# survives. The spool is bind-mounted rw into the sandbox, so it opens O_NOFOLLOW — a symlink
# planted there would otherwise put an unreadable host file onto the clipboard, which pbpaste
# hands straight back into the box.
#
# POSIX sh, stock macOS tools. Started via detach_pgrp with fds 200/201 CLOSED (load-bearing —
# it outlives the kib that starts it); killed by process group at teardown.
#
# Protocol (files in the spool dir):
#   req.<id>   container → host: one line, the type (text | png | list | write)
#   data.<id>  container → host: the bytes to write, for a `write` request
#   resp.<id>  host → container: the answer (written via a temp + rename, so the container
#              never reads a half-written file); for a write, `ok` and only on success
#   done.<id>  host → container: empty marker, written AFTER resp — the container waits on it
#   deny.<id>  container → host: a write the SHIM itself refused (non-text); the host alerts

DIR="${1:?usage: clipboard-bridge.sh <spool-dir> <project-name>}"
NAME="${2:-project}"
LAST_ALERT=0
# Exec'd, never sourced, so `kib_py` from host/core.sh is out of reach — this mirrors it
# exactly (PYTHONPATH per-invocation, never exported; parameters in argv).
KIB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

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
}

# One alert per 30s, so a wl-copy loop cannot spam the desktop. terminal-notifier first when
# present: a `display notification` from a detached osascript is silently dropped unless the
# user has allowed notifications for Script Editor, which is why a refusal could go unseen.
notify_clip() { # $1 = title suffix, $2 = body
    now="$(date +%s)"
    [ $((now - LAST_ALERT)) -lt 30 ] && return
    LAST_ALERT="$now"
    if command -v terminal-notifier >/dev/null 2>&1; then
        terminal-notifier -title "kib · $1" -message "$2 Project: $NAME" >/dev/null 2>&1 || true
    else
        osascript -e "display notification \"$2 Project: $NAME\" with title \"kib · $1\"" \
            >/dev/null 2>&1 || true
    fi
}

# The ONLY path to pbcopy, and it never gets the container's bytes unfiltered. `resp` is
# written only on success — the shim reads its presence as the exit code.
serve_write() { # $1 = request id
    id="$1"
    rm -f "$DIR/resp.$id" "$DIR/done.$id" 2>/dev/null
    if ! command -v python3 >/dev/null 2>&1; then
        notify_clip "clipboard write blocked" "No python3 on the host, so the sandbox's write could not be sanitised. Blocked."
        return
    fi
    # The count of stripped characters comes back on STDERR, because stdout carries the bytes.
    if ! PYTHONPATH="$KIB_ROOT" python3 -m kib.shared.clipboard "$DIR/data.$id" \
        >"$DIR/clean.$id" 2>"$DIR/err.$id"; then
        notify_clip "clipboard write blocked" \
            "A clipboard write from the sandbox was refused — unreadable, a symlink, or over 1 MiB. Your clipboard is unchanged."
        rm -f "$DIR/clean.$id" "$DIR/err.$id" 2>/dev/null
        return
    fi
    stripped="$(cat "$DIR/err.$id" 2>/dev/null)"
    pbcopy <"$DIR/clean.$id" 2>/dev/null && printf 'ok\n' >"$DIR/resp.$id"
    [ "$stripped" = 0 ] || notify_clip "clipboard write cleaned" \
        "Control characters were stripped from a write by the sandbox — your next paste is safe."
    rm -f "$DIR/clean.$id" "$DIR/err.$id" 2>/dev/null
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
        case "$type" in
            write) serve_write "$id" ;;
            *) serve_read "$id" "$type" ;;
        esac
        : >"$DIR/done.$id"
        rm -f "$req" "$DIR/data.$id" 2>/dev/null
    done
    for d in "$DIR"/deny.*; do
        [ -e "$d" ] || continue
        rm -f "$d" 2>/dev/null
        notify_clip "clipboard write blocked" "The sandbox tried to write your clipboard with something that is not plain text. Blocked."
    done
    sleep 0.2
done
