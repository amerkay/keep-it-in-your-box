# Clipboard and DNS sync

Part of the Keep It in Your Box design notes (`docs/design-notes/`). See `CLAUDE.md` for the rules
that reference this. Both subsystems mediate a host resource through a sidecar rather than handing
the raw resource to the agent.

## Clipboard

The raw Wayland socket grants clipboard **writes**, and a write is host code execution at the next terminal paste (`ESC[201~` ends bracketed paste; the rest is typed input). `kib/guest/wayland_guard.py` runs in a sidecar (`${CNAME}-wl`, `--network none`) that alone holds the real socket, relaying the wire protocol:

- **Refuses** `create_data_source`, `set_selection`, `set_primary_selection`, `start_drag` on all four clipboard interfaces (`wl_data_device{_manager}`, `zwp_primary_selection_*`, `zwlr_data_control_*`, `ext_data_control_*`) by closing the connection — dropping a `new_id` request would desynchronise the client's object space.
- **DEAD END — hides nothing from the registry.** An earlier version dropped globals from `wl_registry.global`; that broke `wl-paste` outright (KWin advertises `ext_data_control_manager_v1` not `zwlr_`; this `wl-clipboard` speaks neither and falls back to `wl_data_device_manager`). Every clipboard interface carries read and write halves together; refusing the write *requests* is exactly as strict and costs no reads.
- **Forwards everything else verbatim** including `SCM_RIGHTS` fds. Object→interface tracking needs no protocol DB — `wl_registry.bind` carries the interface name as a string.
- Host terminal select + Ctrl+Shift+C never comes through the proxy (host client) — remember this before "fixing" it.
- **Fail-soft** (unlike FUSE): no Wayland / proxy won't start → no socket mounted at all. Denials log `WLGUARD-DENY`; `start_wayland_notifier` (host-side, setsid + pid file) raises a rate-limited desktop notification.

macOS: a **pbpaste bridge**, one-way by construction — see [macos.md](macos.md).

## DNS sync

Docker freezes a container's `/etc/resolv.conf` at creation; a long-lived container loses DNS on every wifi/VPN switch. Fix: `kib` bind-mounts the host's `/run/systemd/resolve` **directory** read-only (the *directory*, not the file — resolved swaps `resolv.conf` by atomic rename, so a file mount pins the old inode) and `start_resolv_sync` launches `guest/bin/resolv-sync.sh` once per container life as a detached root `docker exec` (uid 0 to write `/etc/resolv.conf`; created only under the boot lock so exactly one watcher).

- **The directory also holds systemd-resolved's Varlink control sockets**, and a read-only mount doesn't stop `connect()` — so `kib` shadows each socket with `/dev/null` (nested bind; `connect()` → `ENOTSOCK`).
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
