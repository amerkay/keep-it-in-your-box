# Clipboard and DNS sync

Part of the Keep It in Your Box design notes (`docs/design-notes/`). See `CLAUDE.md` for the rules
that reference this. Both subsystems mediate a host resource through a sidecar rather than handing
the raw resource to the agent.

## Clipboard

The raw Wayland socket grants clipboard **writes**, and a *verbatim* write is host code execution at the next terminal paste (`ESC[201~` ends bracketed paste; the rest is typed input). `kib/guest/wayland_guard.py` runs in a sidecar (`${CNAME}-wl`, `--network none`) that alone holds the real socket, relaying the wire protocol:

- **Sanitises writes rather than refusing them.** The write path (`create_data_source`, `offer`, `set_selection`) is allowed; what the guard interposes on is the `send` **event**, where the compositor hands back the pipe the client writes the selection into. The client gets a pipe of the guard's instead, and `clean_text` drops every `Cc`-category character (C0, DEL, C1) bar tab and newline on the way through — so the escape cannot survive, and every visible glyph does. Over 1 MiB is dropped; a non-`text/*` flavour (`offer`) is refused, because the filter guarantees nothing about bytes it cannot read as text.
- **DEAD END — refusing writes outright.** That was the original design, and it broke the fullscreen TUI's select-to-copy (`/tui fullscreen`): Claude picks `wl-copy` whenever `WAYLAND_DISPLAY` is set, prints "copied N chars" without checking, and the user got a desktop alert instead of a clipboard. **The content is the boundary, not the caller** — and it has to be, because there is no way to tell the agent's own copy from a script's. `SO_PEERCRED` yields pid 0 across the sidecar's PID namespace; `--pid=container:` would fix that and hand the box (same uid) the ability to kill or ptrace the one process holding the real socket; a shim inside the box can be walked around, since nothing there can hold a secret from anything else there. Do not re-add an identity check.
- **DEAD END — hides nothing from the registry.** An earlier version dropped globals from `wl_registry.global`; that broke `wl-paste` outright (KWin advertises `ext_data_control_manager_v1`, which this `wl-clipboard` does not speak — it carries `zwlr_`, `zwp_`, `gtk_` and `wl_data_device_manager`, and falls back down that chain).
- **Every family wl-clipboard can bind must be in `NEW_ID`, and the omission fails OPEN.** An untracked source is never recognised as a `send`, so its fd takes the "nothing here can be a selection pipe" path and the compositor's real pipe reaches the client *unfiltered* — the whole bypass, silently, with the clipboard still appearing to work. This was live for the pre-standard `gtk_primary_selection_*` (GNOME's, still in wl-clipboard's fallback chain and compiled into the installed `wl-copy`/`wl-paste`) until an audit found it. `test_every_clipboard_family_is_interposed` drives one per family and `test_every_source_interface_has_a_send_event` pins `NEW_ID`'s sources to `SEND_EVENT`'s keys, because a half-added family is the same bypass.
- **An unaccountable fd closes the connection.** `send` is the only server→client event that carries an fd to a clipboard tool, and it carries exactly one, so an equal count pairs positionally in stream order. Anything else (a `wl_keyboard.keymap` fd in the same batch, say) is refused rather than guessed at — a mispairing would forward the compositor's real pipe to the client, unfiltered, which is the whole bypass. An fd whose message has not fully arrived is held, not refused: Wayland delivers it with the message's first bytes.
- **Forwards everything else verbatim** including `SCM_RIGHTS` fds. Object→interface tracking needs no protocol DB — `wl_registry.bind` carries the interface name as a string.
- **What this does NOT cover:** anything else the compositor exposes (`zwlr_screencopy`, virtual-keyboard, layer-shell) passes through untouched, and OSC 52 on stdout is an unmediated write channel that no proxy can see — whether it lands is the terminal emulator's policy. The guard's value is bounded to clipboard content.
- Host terminal select + Ctrl+Shift+C never comes through the proxy (host client) — remember this before "fixing" it.
- **Fail-soft** (unlike FUSE): no Wayland / proxy won't start → no socket mounted at all. Refusals log `WLGUARD-DENY`, a stripped write logs `WLGUARD-STRIP`; `start_wayland_notifier` (host-side, setsid + pid file) raises a rate-limited desktop notification for each. A clean copy is silent — a `STRIP` line means the box wrote something that *contained* a paste escape, which is worth seeing.
- **macOS runs the same filter, at the spool instead of the wire.** No socket to interpose on, so the guest write shims spool the bytes and `host/clipboard-bridge.sh` cleans them through `kib.shared.clipboard` before the one `pbcopy` call in the tree. It opens the spooled file `O_NOFOLLOW`: the spool is bind-mounted rw into the box, so a planted symlink would otherwise load a host file the box cannot read onto the clipboard, where `pbpaste` hands it straight back. One filter, two transports — a second copy in `sh` would drift, and the drift is a platform where the escape survives.
- **Nothing the host writes or re-opens may live in the spool** (audit MAC-C1). "One filter, two transports" was true of the filter and false of the transport: `serve_write` staged the *cleaned* bytes at `clean.$id` in the spool and had `pbcopy` re-open that path. The spool is bind-mounted rw, so `>clean.$id` followed a symlink the box planted — the host truncating and rewriting any file the user can write, `~/.zshrc` included — and the second `open()` was a race that put unsanitised bytes on the real pasteboard, defeating the whole guarantee on one platform. The rule is structural, not a patch: the bridge stages every answer in `$DIR.priv` (0700, a *sibling* of the spool so `mv` is a rename on the same filesystem, and never bind-mounted) and `publish`es it in. `rename(2)` replaces the destination and never follows it, so an `rm`-then-`>` window cannot reappear. The Linux guard's in-flight `SCM_RIGHTS` handoff never had this class — which is exactly why it went unnoticed until a macOS host.

## DNS sync

Docker freezes a container's `/etc/resolv.conf` at creation; a long-lived container loses DNS on every wifi/VPN switch. Fix: `kib` bind-mounts the host's `/run/systemd/resolve` **directory** read-only (the *directory*, not the file — resolved swaps `resolv.conf` by atomic rename, so a file mount pins the old inode) and `start_resolv_sync` launches `guest/bin/resolv-sync.sh` once per container life as a detached root `docker exec` (uid 0 to write `/etc/resolv.conf`; created only under the boot lock so exactly one watcher).

- **The directory also holds systemd-resolved's Varlink control sockets**, and a read-only mount doesn't stop `connect()` — so `kib` shadows each socket with `/dev/null` (nested bind; `connect()` → `ENOTSOCK`). The list is **globbed (`io.systemd.*`), not enumerated**: the two that ship today were named literally in `add_resolv_sync_args` *and* again in `security-test.sh`, so a third socket a future systemd added would have been a live sandbox→host channel neither side noticed. Directories are skipped — `netif/` is one, and `-v /dev/null:` onto a directory aborts the whole `docker run`. **Residual, two parts, both keyed on the glob running once at `docker run`:** a control socket under a *different* prefix is not covered (that needs a rule keyed on file type, which the dir's contents don't make possible without a `stat` per entry every launch); and a matching socket that is *absent at create time and appears later* is not covered either, because the `/run/host-resolve` bind is a live directory view.

  **The obvious fix — union the glob with the two known names — is impossible, not merely untested.** Probed on Docker/runc 2026-07-28:

  ```
  docker run --rm -v /run/systemd/resolve:/run/host-resolve:ro \
    -v /dev/null:/run/host-resolve/io.systemd.DoesNotExist:ro alpine ls /run/host-resolve/
  → error mounting "/dev/null" to rootfs at "/run/host-resolve/io.systemd.DoesNotExist":
    create mountpoint …: read-only file system
  ```

  runc has to *create* the mountpoint, and it cannot on a read-only bind. So an unconditional name aborts the whole launch whenever that socket is absent — which is exactly what the literal two-name mounts this replaced would have done. They were never "unconditional coverage": they were coverage **or** a cryptic launch failure, on the same input the glob now merely under-covers. The change traded a hard abort for a narrow, detected gap.

  **Detected, not prevented.** `security-test.sh` globs at *test* time, inside the container, so any unshadowed `io.systemd.*` fails its per-socket `deny` — the one moment the gap is observable. `tests/check/wiring.sh` pins every `/dev/null` shadow inside the existence-guarded loop, so the fail-hard shape cannot grow back.
- **DO NOT "simplify" back to a wholesale overwrite of resolv.conf.** The watcher preserves Docker's embedded resolver (`nameserver 127.0.0.11`) as the FIRST entry when present — it alone resolves container aliases like `kib-broker`, and glibc returns the first nameserver's NXDOMAIN without trying the rest. The pre-fix overwrite made the broker alias `ENOTFOUND` seconds into every session.
- Conservative: strips loopback nameservers, never writes a nameserver-less file. `KIB_RESOLV_DST` overrides the target for the check suite only.
- **Why not a relay to the `127.0.0.53` stub** (earlier design): needs a `--network host` root sidecar and a `container→gateway:53` hop that a per-connection host firewall (Portmaster) silently holds — while it *permits* the container to query real upstreams directly. Trade: less split-DNS precision, no host-netns component at all.
- Best-effort fallback: no systemd-resolved → no mount, no watcher, frozen-at-creation resolv.conf (never worse than before), and `kib` says so. `notify()` is for **problems only** — never add a launch-success notification; it trains the user to dismiss the ones that matter.
- Skipped on macOS (engine VM tracks the host resolver already).

## macOS reader protocol (the image-paste failure)

Three things in the container-side shims had to be true before an image paste could work, and on
the first Mac run none of them were:

- **`xclip` must forward its arguments.** It `exec`ed `/usr/local/bin/wl-paste` bare, so
  `xclip -t image/png -o` asked the host for `text` and got the text selection back. Silent: the
  caller sees a valid, wrong answer rather than an error.
- **The read budget must cover `osascript`.** It was 2 s (40 x 0.05). `pbpaste` answers text
  instantly, but a png goes through `osascript`, whose cold start plus a large image passes 2 s
  routinely; the shim then returns an empty response and the paste produces nothing. 10 s now.
- **Both reader spellings must map to the same three questions.** `wl-paste` asks with
  `-l/--list-types` and `--type`; `xclip` with `-t`/`-target` and a `TARGETS` value. The parser
  accepts both, so it does not matter which reader Claude reaches for. No `DISPLAY` is set:
  Claude's chain consults neither it nor `WAYLAND_DISPLAY`, and faking an X server would only
  mislead GUI-detecting callers.

Fixing all three still left image paste dead. Three more, host-side:

- **`clipboard-bridge.sh` was committed 100644.** It is the one file in `host/` that is `exec`ed
  rather than sourced, so `detach_pgrp` hit EACCES and the bridge died at every launch, for the
  life of the feature. The *index* mode is what other checkouts get; `tests/check/wiring.sh`
  asserts it, discovering exec'd scripts from the source rather than a list.
- **`start_clipboard_bridge` claimed success unconditionally**, unlike `start_wayland_guard`,
  which waits for its socket. That is why a dead bridge stayed invisible. It now round-trips a
  `ping` (answered without touching the pasteboard — no TCC prompt), and on no answer warns and
  drops the spool, so no reader env is advertised for a bridge that cannot serve.
- **`list` and `png` asked different questions**, and only `list` was ever right. Both go through
  `grab_png` now, so "offered" means "readable". It tries `«class PNGf»`, then TIFF via `sips` —
  the TIFF leg is DEFENSIVE, not the fix for anything observed: a ⌘⌃⇧4 screenshot does publish
  PNGf (`info` shows it), so PNGf alone would have sufficed. It costs one call, and only on the
  path that would otherwise return nothing.

`tests/check/clipboard.sh` drives the shims against **the real bridge**, stubbing only
`pbpaste`/`osascript`/`sips` and modelling a TIFF-only pasteboard. Both halves were individually
fine; the protocol between them had never been exercised, which is how all of this shipped.

**The trigger is `Ctrl+V`, not `⌘V`.** ⌘V is consumed by the host terminal, which pastes the
clipboard as text over the pty; for an image it sends nothing, so Claude never runs a clipboard
command. The docs say ⌘V also works in iTerm2; kib does not forward `TERM_PROGRAM`, so whether
that path can work in a box is UNTESTED. Terminal.app cannot send ⌘V to the pty at all.

**Text paste proves nothing about the bridge** — a terminal pastes over the pty and calls no
reader. To check it from inside the box (no answer = the host half is not running):

```
id=p.$$; printf 'ping\n' >/kib-clip/req.$id; sleep 2; cat /kib-clip/resp.$id   # -> pong
```

`info` instead of `ping` returns the pasteboard's actual flavours — the first thing to look at
when a paste comes back empty.
