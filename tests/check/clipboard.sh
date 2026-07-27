#!/usr/bin/env bash
# Sourced by tests/check.sh — the macOS clipboard bridge's container-side shims.
#
# The shims are heredocs inside the BAKED entrypoint, so nothing here can call the installed
# copies: they are extracted from the source exactly as `install_clipboard_shims` writes them,
# pointed at a scratch spool, and driven against the real host bridge. What is under test is the
# request TYPE each reader asks for — an image paste that silently returned the text selection
# is the failure this section exists to catch (`clipboard-and-dns.md`).

# shellcheck source=SCRIPTDIR/_guard.sh
. "${BASH_SOURCE%/*}/_guard.sh" # sourced by tests/check.sh, never run directly

section "Clipboard bridge shims (macOS reader protocol)"

_clip_tmp="$(mktemp -d)"
mkdir -p "$_clip_tmp/bin" "$_clip_tmp/spool"

for _s in wl-paste xclip wl-copy; do
    # wl-copy and pbcopy share ONE heredoc, written from a `for w in …` loop, so its start
    # marker is the loop variable rather than the shim's name. index(), not a regex, so the `$`
    # needs no escaping.
    case "$_s" in
        wl-copy) _mark="cat >\"/usr/local/bin/\$w\" <<" ;; # \$w: the entrypoint's own loop var
        *) _mark="cat >/usr/local/bin/$_s <<" ;;
    esac
    awk -v m="$_mark" 'index($0, m) {f=1; next} f && /^SHIM$/ {exit} f' \
        "$KIB_ROOT/guest/entrypoint/docker-entrypoint.sh" >"$_clip_tmp/bin/$_s"
    if [ ! -s "$_clip_tmp/bin/$_s" ]; then
        fail "extract the $_s shim" "install_clipboard_shims no longer defines it as a heredoc"
    fi
    sed -i.bak "s#DIR=/kib-clip#DIR=$_clip_tmp/spool#" "$_clip_tmp/bin/$_s"
    sed -i.bak "s#/usr/local/bin/wl-paste#$_clip_tmp/bin/wl-paste#g" "$_clip_tmp/bin/$_s"
    sed -i.bak "s#/usr/local/bin/wl-copy#$_clip_tmp/bin/wl-copy#g" "$_clip_tmp/bin/$_s"
    chmod +x "$_clip_tmp/bin/$_s"
done
rm -f "$_clip_tmp/bin"/*.bak

# The REAL host half, not a stub of it: each side was individually fine and the protocol between
# them had never been driven end to end, which is how the bridge shipped non-executable. Only the
# macOS leaf tools are stubbed, so this runs on Linux CI too.
#
# The stubs model a ⌘⌃⇧4 screenshot: on the pasteboard as TIFF ONLY, so «class PNGf» fails and
# the bytes are reachable only through the TIFF→sips fallback. Stub PNGf as available and this
# section passes against the bridge that could not read a screenshot at all.
printf '#!/bin/sh\nprintf TEXTSEL\n' >"$_clip_tmp/bin/pbpaste"
cat >"$_clip_tmp/bin/osascript" <<'STUB'
#!/bin/sh
[ "$1" = -e ] && { case "$2" in *"clipboard info"*) echo '«class TIFF», 12' ;; *) exit 1 ;; esac; }
body="$(cat)"                                   # the write-to-file heredoc
case "$body" in *PNGf*) exit 1 ;; esac          # no PNG flavour, exactly as a screenshot behaves
printf 'TIFFBYTES' > "$(printf '%s' "$body" | sed -n 's/.*POSIX file "\([^"]*\)".*/\1/p')"
STUB
# sips -s format png <in.tiff> --out <out.png>
# shellcheck disable=SC2016  # the stub's own source text: its $1/$2 must reach it unexpanded
printf '#!/bin/sh\nwhile [ "$1" != --out ]; do shift; done\nprintf PNGBYTES > "$2"\n' \
    >"$_clip_tmp/bin/sips"
chmod +x "$_clip_tmp/bin/pbpaste" "$_clip_tmp/bin/osascript" "$_clip_tmp/bin/sips"

# Exec'd, never sourced — same as detach_pgrp does it, so a lost exec bit fails here too.
PATH="$_clip_tmp/bin:$PATH" "$KIB_ROOT/host/clipboard-bridge.sh" "$_clip_tmp/spool" kibtest &
_clip_host_pid=$!

# Both readers, both questions. The xclip spellings are the regression: it used to `exec
# wl-paste` with no arguments, so every image request silently fetched the text selection.
is "wl-paste reads text by default" "TEXTSEL" "$("$_clip_tmp/bin/wl-paste")"
is "wl-paste -t image/png reads the image" "PNGBYTES" "$("$_clip_tmp/bin/wl-paste" -t image/png)"
is "wl-paste --type=image/png reads the image" "PNGBYTES" \
    "$("$_clip_tmp/bin/wl-paste" --type=image/png)"
is "wl-paste --list-types offers image/png" "image/png text/plain" \
    "$("$_clip_tmp/bin/wl-paste" --list-types | tr '\n' ' ' | sed 's/ $//')"
is "xclip -o reads text" "TEXTSEL" "$("$_clip_tmp/bin/xclip" -o)"
is "xclip -t image/png -o reads the IMAGE, not the text selection" "PNGBYTES" \
    "$("$_clip_tmp/bin/xclip" -selection clipboard -t image/png -o)"
is "xclip -t TARGETS -o lists the types" "image/png text/plain" \
    "$("$_clip_tmp/bin/xclip" -t TARGETS -o | tr '\n' ' ' | sed 's/ $//')"
# A TRAILING flag must not abort the shim. `shift` is a special builtin, so shift-then-read-$1
# left the loop's own shift with nothing to take and dash killed the shim outright: rc=2, no
# request written, no output. It falls back to text, which is the only sane answer.
is "a trailing -t degrades to text instead of aborting the shim" "TEXTSEL" \
    "$("$_clip_tmp/bin/wl-paste" -t)"

# The launch-time liveness probe (start_clipboard_bridge).
printf 'ping\n' >"$_clip_tmp/spool/req.probe1"
_clip_i=0
while [ ! -e "$_clip_tmp/spool/done.probe1" ] && [ "$_clip_i" -lt 60 ]; do
    sleep 0.05
    _clip_i=$((_clip_i + 1))
done
is "the liveness probe is answered" "pong" "$(cat "$_clip_tmp/spool/resp.probe1" 2>/dev/null)"
# Must not touch the pasteboard, or every launch is a clipboard read and a TCC prompt.
is "the liveness probe never reads the pasteboard" "0" \
    "$(sed -n 's/^ *ping)\(.*\)/\1/p' "$KIB_ROOT/host/clipboard-bridge.sh" \
        | grep -c 'pbpaste\|osascript')"
rm -f "$_clip_tmp/spool"/req.probe1 "$_clip_tmp/spool"/resp.probe1 "$_clip_tmp/spool"/done.probe1
unset _clip_i

# The WRITE path, end to end against the real host half. A write is allowed — refusing it broke
# the fullscreen TUI's select-to-copy — but it reaches pbcopy only through kib.shared.clipboard,
# the same filter the Wayland guard applies in flight on Linux. The probe carries the sequence
# that would end bracketed paste and run the rest as typed input at the user's next paste.
printf '#!/bin/sh\ncat > "%s/pasteboard"\n' "$_clip_tmp" >"$_clip_tmp/bin/pbcopy"
chmod +x "$_clip_tmp/bin/pbcopy"
printf 'kib\033[201~probe' | "$_clip_tmp/bin/wl-copy" >/dev/null 2>&1
_clip_i=0
while [ ! -f "$_clip_tmp/pasteboard" ] && [ "$_clip_i" -lt 100 ]; do
    sleep 0.05
    _clip_i=$((_clip_i + 1))
done
is "a text write reaches pbcopy with the paste escape stripped" "kib[201~probe" \
    "$(cat "$_clip_tmp/pasteboard" 2>/dev/null)"

# MAC-C1 — the transport, not the filter. The spool is bind-mounted rw into the box, so anything
# the host REDIRECTS into it follows a symlink the box planted (host file truncated and
# rewritten), and anything it re-opens by path is a race that lands unsanitised bytes on the real
# pasteboard. One property covers both: the host stages in $DIR.priv and only ever `mv`s in.
# Driven here rather than in security-test.sh because that suite's macOS section cannot run on a
# Linux host — this harness drives the real bridge on either. (`clipboard-and-dns.md`)
_clip_wait() { # _clip_wait <id>
    _clip_i=0
    while [ ! -e "$_clip_tmp/spool/done.$1" ] && [ "$_clip_i" -lt 100 ]; do
        sleep 0.05
        _clip_i=$((_clip_i + 1))
    done
}
for _n in clean err; do
    _id="mac-c1.$_n"
    printf 'ORIGINAL' >"$_clip_tmp/victim.$_n"
    ln -s "$_clip_tmp/victim.$_n" "$_clip_tmp/spool/$_n.$_id"
    printf 'kib-mac-c1-probe' >"$_clip_tmp/spool/data.$_id"
    rm -f "$_clip_tmp/pasteboard"
    printf 'write\n' >"$_clip_tmp/spool/req.$_id"
    _clip_wait "$_id"
    is "MAC-C1 a planted $_n.<id> symlink is not followed" "ORIGINAL" \
        "$(cat "$_clip_tmp/victim.$_n" 2>/dev/null)"
done
# …and the write still worked, so the fix is not "refuse everything".
is "regression: the write still reached pbcopy" "kib-mac-c1-probe" \
    "$(cat "$_clip_tmp/pasteboard" 2>/dev/null)"
# Structural half: with nothing planted, the host must still leave no staging file behind in the
# spool — that is what makes the symlink unplantable in the first place.
printf 'plain' >"$_clip_tmp/spool/data.mac-c1.bare"
printf 'write\n' >"$_clip_tmp/spool/req.mac-c1.bare"
_clip_wait mac-c1.bare
is "MAC-C1 the bridge stages nothing in the spool" "0" \
    "$(find "$_clip_tmp/spool" -maxdepth 1 -type f \( -name 'clean.*' -o -name 'err.*' \) \
        | wc -l | tr -d ' ')"
rm -f "$_clip_tmp/spool"/*.mac-c1.* "$_clip_tmp/victim."* 2>/dev/null
unset _clip_i _n _id

# Text only, exactly like the Wayland side: the filter says nothing about bytes it cannot read
# as text, so a non-text flavour is refused at the shim and leaves the marker the host alerts on.
rm -f "$_clip_tmp/spool"/deny.* "$_clip_tmp/pasteboard" 2>/dev/null
if printf x | "$_clip_tmp/bin/xclip" -t image/png -i >/dev/null 2>&1; then
    fail "an image write is refused" "the sanitiser guarantees nothing about non-text bytes"
else
    pass "an image write is refused"
fi
is "a refused write leaves a deny marker for the host" "1" \
    "$(find "$_clip_tmp/spool" -name 'deny.*' | wc -l | tr -d ' ')"
is "a refused write never reached pbcopy" "" "$(cat "$_clip_tmp/pasteboard" 2>/dev/null)"

# The png path is answered by osascript, whose cold start passed the original 2s budget.
_clip_budget="$(sed -n 's/.*"\$i" -lt \([0-9]*\).*/\1/p' "$_clip_tmp/bin/wl-paste" | head -1)"
if [ "${_clip_budget:-0}" -ge 200 ]; then
    pass "the reader waits ≥10s (osascript png extraction is not instant)"
else
    fail "the clipboard read budget is back under 10s" \
        "got ${_clip_budget:-none} × 0.05s — a large png returns empty and the paste is silent"
fi

kill "$_clip_host_pid" 2>/dev/null
rm -rf "$_clip_tmp"
wait "$_clip_host_pid" 2>/dev/null || true
unset _clip_tmp _clip_host_pid _clip_budget _s _mark _req _id
unset -f _clip_wait
