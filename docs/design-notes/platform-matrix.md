# Platform matrix — Ubuntu vs macOS

Part of the Keep It in Your Box design notes (`docs/design-notes/`). One row per behaviour that
differs by host OS, with the file that owns it.

**This file carries no rationale.** Every "why" lives in the note named in the row — follow the
pointer rather than restating it here. `host/portable.sh` is the only file that branches on OS;
everything else calls its shims or tests `is_macos`.

## How each row is proven

| Mark | Meaning |
|---|---|
| ✅ | Exercised on Linux by `./dev.sh check` / `tests/check/` |
| 🧪 | macOS behaviour proven **on Linux** by a test vehicle: `tests/check/portability.sh` forcing the perl/darwin paths |
| ⏳ | Needs Apple hardware — see [TODO](#todo--checks-not-yet-run) |
| — | No test; behaviour is a one-line platform branch read directly from the source |

## Redaction and container topology

**The topology itself does not differ.** Both platforms serve the redacted view from a FUSE
**sidecar** and propagate it into the agent's container over `$PWD` (`:rslave`). Only the sidecar
holds `SYS_ADMIN`, `/dev/fuse` and `apparmor=unconfined`; the agent's container is capless at
creation. What differs is only *where the propagation root lives*, and how it is reached:

| Behaviour | Ubuntu / Linux | macOS | Owner | Proven |
|---|---|---|---|---|
| Propagation root | `$KIB_STATE_ROOT/fuse.<hash>` — systemd makes `/` rshared, so it propagates already | `/run/kib/fuse.<hash>` — must be VM-internal; a virtiofs share of the Mac has no mount namespace for the event. Never `/var` (a symlink to the shared `/private/var`) | `macos.md` | ✅ |
| Preparing / destroying that root, and unmounting | Plain `mkdir`/`rm` as you; a `/proc/self/mounts` read and `fusermount3` | A throwaway `--privileged --pid=host` container `nsenter`ing the engine VM — the Mac cannot see the path at all. Deliberately **not** used on Linux, where it would target the real machine | `macos.md` | ✅ |
| Mode bits inside the project view | **Enforced** — the mount carries `default_permissions`, so the kernel checks owner/mode against the caller rather than the server | **Enforced the same way**, and this is the *only* place mode bits bite on macOS: outside the view `fakeowner` records a mode but ignores it in `access(2)` | `macos.md` | ✅ |
| Ownership in the backing store | Already the agent's, so the remap is identity | `fakeowner` reports every bind as `root:root`; without the remap git refuses the whole tree as "dubious ownership" | `macos.md` | ✅ |
| AppArmor | `docker-default` on the agent's container — its `deny mount,` costs nothing now the sidecar holds the mount | Absent — Docker Desktop's LinuxKit kernel ships no AppArmor, so the suite skips the label assertion rather than failing it | `macos.md` | ✅ |
| Sidecars per project | Up to 3 (FUSE, Wayland guard, broker) + main | Up to 2 (FUSE, broker) + main | `container-lifecycle.md` | — |

## Clipboard

| Behaviour | Ubuntu / Linux | macOS | Owner | Proven |
|---|---|---|---|---|
| Transport | Wayland proxy sidecar holds the only real compositor socket | Host watcher (`host/clipboard-bridge.sh`) over a spool dir bind-mounted at `/kib-clip` | `clipboard-and-dns.md` | — |
| Reads | Relayed verbatim by the proxy | Answered host-side with `pbpaste` / osascript PNG extraction | `clipboard-and-dns.md`, `macos.md` | — |
| Writes | Sanitised in flight at the `send` event — control characters stripped, non-text flavours refused (`WLGUARD-STRIP` / `WLGUARD-DENY`) | Sanitised host-side through `kib.shared.clipboard`, then `pbcopy`; non-text refused at the shim | `clipboard-and-dns.md` | ✅ |
| Write alert (strip or refusal) | `notify-send`, one per 30 s | None | `clipboard-and-dns.md` | — |
| Paste trigger env | `WAYLAND_DISPLAY=wayland-0` + proxied socket | `WAYLAND_DISPLAY=kib-clip` + spool. No `DISPLAY`: Claude's `xclip \|\| wl-paste` chain reads neither | `host/desktop.sh` | ✅ |
| Reader request type | n/a — the proxy relays verbatim | `wl-paste`/`xclip` spellings both map to text/png/list; 10 s budget for osascript png extraction | `clipboard-and-dns.md` | ✅ |
| No clipboard available | No Wayland socket → info line, paste disabled (fail-soft) | No `pbpaste` → info line, paste disabled | `clipboard-and-dns.md` | — |

## Network

| Behaviour | Ubuntu / Linux | macOS | Owner | Proven |
|---|---|---|---|---|
| DNS | `resolv-sync.sh` follows the host resolver across wifi/VPN changes, keeping `127.0.0.11` first | Skipped — the engine VM tracks the host resolver; one info line at launch | `clipboard-and-dns.md` | ✅ |
| Broker | On by default, static `:ro` token, same delivery modes | Identical | `credential-broker.md` | ✅ |
| Broker mid-session alerts | `docker logs -f` follower raising `notify-send` on `BROKER-FATAL`/`BROKER-ERR`, backing off after 3 | None — `start_broker_notifier` returns immediately | `credential-broker.md` | — |
| Dual-homing | Broker net + default bridge, so host dev servers and LAN stay reachable | Identical | `credential-broker.md` | ✅ |

## Sleep, power and notifications

| Behaviour | Ubuntu / Linux | macOS | Owner | Proven |
|---|---|---|---|---|
| Inhibitor | `systemd-inhibit --what=sleep` held by a background `sleep infinity` | `caffeinate -is` | `sleep-guard.md` | ✅ |
| Idle lid-shut suspend | Proactive `systemctl suspend` when idle + lid closed + no external display + no other kib lock, gated by the post-resume SETTLE window | Not applicable — macOS re-evaluates sleep itself once the assertion drops | `sleep-guard.md` | ✅ |
| Activity metric | Same sampler, sourced by both the guard and the diagnostic | Identical | `sleep-guard.md` | ✅ |
| Desktop notifications | `notify-send -u <urgency> -i <icon>` | `osascript display notification` (urgency and icon dropped) | `clipboard-and-dns.md` | 🧪 |
| `kib sleep-monitor` | Full diagnostic: KDE idle clock, systemd block locks, `/proc` sampling | Refuses (exit 2) and points at `pmset -g assertions` — none of its data sources exist | `sleep-guard.md` | ✅ |

## Launch, host toolchain and mounts

| Behaviour | Ubuntu / Linux | macOS | Owner | Proven |
|---|---|---|---|---|
| `preflight_platform` | No-op | Fails fast on: no reachable Docker engine (naming Desktop / OrbStack / Colima), missing `perl`, and an engine not sharing `$PWD` | `macos.md` | 🧪 |
| Docker engine | Any | Docker Desktop, OrbStack, or Colima | `architecture.md` | ⏳ |
| Host shell | bash 5, GNU userland used directly (`flock`, `setsid`, `sha256sum`) | bash 3.2 + BSD userland; `perl` shims for `lock_fd` / `detach_pgrp`, `shasum` for `hash8` | `macos.md` | 🧪 |
| Empty-array expansion | Tolerant | Every array ever assigned `()` must expand as `${arr[@]+"${arr[@]}"}` or the launch aborts under `set -u` | `macos.md` | ✅ |
| Host python | Modern `python3` | Stock 3.9 — `kib/host`, `kib/shared`, `kib/broker` stay 3.9-clean (enforced on **both**) | `macos.md` | ✅ |
| Nested bind mounts | Tolerated (the resolv-sync `/dev/null` masks) | Fatal — the whole `docker run` aborts; everything goes flat under `/run/kib/` via `bind_via_link` | `macos.md` | ✅ |
| `~/.claude` bootstrap | Assembled per launch from canonical | Same; on a fresh Mac `ensure_claude_home` creates a minimal skeleton first | `container-lifecycle.md` | — |

## Identical on both platforms

`.kibignore` rules and the FUSE server/matcher behind them · the host-executed-config guard
(`.git/config`, hooks, `.vscode/`, `.devcontainer/`, `.idea/`, `.envrc`) · the git audit gate at cold
start, teardown and `kib audit` · per-launch config assembly and subtree merge-out · the credential
broker and MCP interception · the verb CLI · `cap-drop=ALL` + `no-new-privileges` + seccomp on the
agent's own process · one container per project with the same lock protocol.

`tests/security-test.sh` is one suite for both, with no mode detection left in it: the only
platform-conditional assertion is the AppArmor label, which is *skipped* when the kernel has no
AppArmor at all (LinuxKit).

## TODO — checks not yet run

Tracked upstream in `docs/FUTURE_TASKS.md` § "Open questions" and `macos.md` § "Still open".

- [ ] **Image paste end-to-end (Mac hardware).** Confirmed broken on the first Mac run, three
      causes fixed (dropped `xclip` args, a 2 s budget against `osascript`, and only one trigger
      env advertised). Needs a re-test on hardware. Note that *text* paste working proves nothing
      here — a terminal pastes text over the pty and never invokes a clipboard reader.

**virtiofs file ownership** is answered: `fakeowner` reports `root:root` and treats mode bits as
advisory. It was not benign — see `macos.md` § "`fakeowner`". Everything else in this matrix is
either covered by the Linux suite or proven on Linux through the forced-darwin-path vehicle.

## Found on the first real Mac run

Recorded because none of it was reproducible on Linux, even with the same topology — these are
platform facts, not topology facts. All are fixed and regression-guarded.

| Symptom | Cause | Guard |
|---|---|---|
| Every git command refuses the repo; `dev.sh` finds no files | `fakeowner` reports the project `root:root` | `regressions.sh` (`--uid`/`--gid`), `test_fuse.py` |
| The synthetic `.credentials.json` is writable | `chmod 0400` is a no-op on a bind | `regressions.sh` (`:ro` by mount) |
| Two sets of `projects/`, `.claude.json`, `↑` history | box path ≠ host path while the view was mounted in-container; the sidecar's `$PWD` bind makes them one key again | `wiring.sh`, `test_config_scope.py` |
| No `commands/` in the box | the merge farm returned early with no shared source | — (entrypoint) |
| 3 `lock_fd` failures + 2 false passes | the shim suite used GNU `flock(1)` as its own oracle | `portability.sh` now holds `shims.sh` to the contract |
| AppArmor assertion cannot pass | LinuxKit ships no AppArmor | `security-test.sh` skips when the label is empty |

## Fixed since

- `kib sleep-monitor` had no darwin guard. It is a host-global verb that `exec`s before
  `preflight_platform`, and every source it samples (`systemd-inhibit`, KDE `qdbus`, `/proc`) is
  Linux-only, so on macOS it wrote an empty diagnostic log — which reads as "nothing is holding
  the machine awake" rather than "this tool does not apply here". It now refuses with exit 2 and
  points at `pmset -g assertions`, guarded in `wiring.sh` by stubbing `uname`.
