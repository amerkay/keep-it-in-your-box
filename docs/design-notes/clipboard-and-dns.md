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

Docker freezes a container's `/etc/resolv.conf` at creation; a long-lived container loses DNS on every wifi/VPN switch. Fix: `cc` bind-mounts the host's `/run/systemd/resolve` **directory** read-only (the *directory*, not the file — resolved swaps `resolv.conf` by atomic rename, so a file mount pins the old inode) and `start_resolv_sync` launches `guest/bin/resolv-sync.sh` once per container life as a detached root `docker exec` (uid 0 to write `/etc/resolv.conf`; created only under the boot lock so exactly one watcher).

- **The directory also holds systemd-resolved's Varlink control sockets**, and a read-only mount doesn't stop `connect()` — so `cc` shadows each socket with `/dev/null` (nested bind; `connect()` → `ENOTSOCK`).
- **DO NOT "simplify" back to a wholesale overwrite of resolv.conf.** The watcher preserves Docker's embedded resolver (`nameserver 127.0.0.11`) as the FIRST entry when present — it alone resolves container aliases like `kib-broker`, and glibc returns the first nameserver's NXDOMAIN without trying the rest. The pre-fix overwrite made the broker alias `ENOTFOUND` seconds into every session.
- Conservative: strips loopback nameservers, never writes a nameserver-less file. `KIB_RESOLV_DST` overrides the target for the check suite only.
- **Why not a relay to the `127.0.0.53` stub** (earlier design): needs a `--network host` root sidecar and a `container→gateway:53` hop that a per-connection host firewall (Portmaster) silently holds — while it *permits* the container to query real upstreams directly. Trade: less split-DNS precision, no host-netns component at all.
- Best-effort fallback: no systemd-resolved → no mount, no watcher, frozen-at-creation resolv.conf (never worse than before), and `cc` says so. `notify()` is for **problems only** — never add a launch-success notification; it trains the user to dismiss the ones that matter.
- Skipped on macOS (engine VM tracks the host resolver already).
