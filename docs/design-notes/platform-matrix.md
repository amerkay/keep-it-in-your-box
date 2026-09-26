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
| Write alert (strip or refusal) | `notify-send`, one per 30 s | `notify_clip` (`terminal-notifier`, else `osascript`), one per 30 s | `clipboard-and-dns.md`, `macos.md` | — |
| Paste trigger env | `WAYLAND_DISPLAY=kib-wl/wayland-0` + proxied socket dir | `WAYLAND_DISPLAY=kib-clip` + spool. No `DISPLAY`: Claude's `xclip \|\| wl-paste` chain reads neither | `host/desktop.sh` | ✅ |
| Reader request type | n/a — the proxy relays verbatim | `wl-paste`/`xclip` spellings both map to text/png/list; 10 s budget for osascript png extraction | `clipboard-and-dns.md` | ✅ |
| No clipboard available | No Wayland socket → info line, paste disabled (fail-soft) | No `pbpaste` → info line, paste disabled | `clipboard-and-dns.md` | — |

## Network

| Behaviour | Ubuntu / Linux | macOS | Owner | Proven |
|---|---|---|---|---|
| DNS | `resolv-sync.sh` follows the host resolver across wifi/VPN changes, keeping `127.0.0.11` first | Skipped — the engine VM tracks the host resolver; one info line at launch | `clipboard-and-dns.md` | ✅ |
| Broker | On by default, static `:ro` token, same delivery modes | Identical | `credential-broker.md` | ✅ |
| Dual-homing | Broker net + default bridge, so host dev servers and LAN stay reachable | Identical | `credential-broker.md` | ✅ |

## Sleep, power and notifications

| Behaviour | Ubuntu / Linux | macOS | Owner | Proven |
|---|---|---|---|---|
| Inhibitor | `systemd-inhibit --what=sleep` held by a background `sleep infinity` | `caffeinate -is` | `sleep-guard.md` | ✅ |
| Idle lid-shut suspend | Proactive `systemctl suspend` when idle + lid closed + no external display + no other kib lock, gated by the post-resume SETTLE window | Not applicable — macOS re-evaluates sleep itself once the assertion drops | `sleep-guard.md` | ✅ |
| Activity metric | Claude's own hook state (`kib_sleep_state`), sourced by both the guard and the diagnostic — not a measurement of output | Identical; the hooks run in the box, so the metric is platform-independent | `sleep-guard.md` | ✅ |
| Desktop notifications | `notify-send -u <urgency> -i <icon>` | `terminal-notifier` when present, else `osascript display notification` (urgency and icon dropped either way). The fallback order is load-bearing, not cosmetic: `display notification` from a *detached* process is attributed to Script Editor and dropped silently without that grant, and the loudest caller — `clipboard-bridge.sh` — runs under `detach_pgrp`. Same order as `notify_clip` | `clipboard-and-dns.md` | 🧪 |
| `kib sleep-monitor` | Full diagnostic: KDE idle clock, systemd block locks, per-guard hook state, phantom-input detection | Refuses (exit 2) and points at `pmset -g assertions` — none of its data sources exist | `sleep-guard.md` | ✅ |

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

## Rootless Docker (Linux)

Supported, and it is an **engine** difference rather than an OS one — `is_rootless` sits beside
`is_macos` in `host/portable.sh`, memoised off one `docker info` per launch. Measured by a
throwaway probe before any code was written — on docker 29.2.1 / rootlesskit 2.3.6 / kernel 7.0
(2026-09-26) — and every row below is that probe's result, which is why the script itself is gone:

| Measured | Consequence | Owner |
|---|---|---|
| `:rshared` bind **refused** — "path … is mounted on / but it is not a shared mount" | dockerd lives in RootlessKit's mount namespace, where `/` is `rslave`. `_mount_is_shared` reads *our* namespace and wrongly passes, so the root must be bind-mounted to itself and marked `--make-rshared` **inside the daemon's namespace** | `fuse_root_create` |
| After that: a mount made in one container reaches the next (`shared:847 master:1`) | the sidecar topology is unchanged — the agent's container stays capless, `/dev/fuse` passes through to the sidecar only | `fuse_root_create` |
| The host never sees the view (`master:1`, one-way) | readiness, staleness and unmount must be asked **in that namespace**, so `fuse_mounted` / `unmount_fuse` / `fuse_root_destroy` route through `engine_ns_exec` — the same shim macOS uses, with an unprivileged `nsenter` instead of a privileged container | `engine_ns_exec` |
| A bind of the project reports **uid 0** inside | the host user maps to container 0 and the subuid range (100000+) reaches nothing kib mounts, so every `--user`, `HOST_UID`, `gosu` and FUSE id remap goes through `box_uid`/`box_gid`, which answer 0 there. Guarded by `tests/check/regressions.sh` | `box_uid` |
| Both the container-setup and session passes are uid 0 | the entrypoint can no longer tell them apart by uid; `KIB_SESSION_TAG` (already set per-exec) is the discriminator, and the root refusal is lifted only for `KIB_ROOTLESS=1` | `docker-entrypoint.sh` |
| Claude itself refuses `--dangerously-skip-permissions` at uid 0 — **after** a fully successful launch | its check is `getuid() === 0 && IS_SANDBOX !== "1"`, `isRootOutsideDeliberateSandbox()` in the binary, so the box gets `-e IS_SANDBOX=1` under rootless only. Found the hard way: every sidecar came up, the banner printed, then the CLI exited 1 | `lifecycle.sh` |
| `SecurityOptions` carries no AppArmor; the label reads `runc (unconfined)` | the agent's container loses `docker-default`'s `deny mount,`. `security-test.sh` skips that assertion on `KIB_ROOTLESS=1` — the daemon lacks the privilege to load a profile, so asserting one is a guaranteed failure that says nothing — and the container is capless *and* inside a user namespace | `security-test.sh` |
| Everything under `$HOME` is resolved from `/etc/passwd`, and root's is `/root` | `usermod -d` cannot fix it (it refuses while any process runs as that user — "used by process 1", exit 8), so the entrypoint rewrites the line in place. Skipping this is not cosmetic: the shared-assembly dir, `settings.json` and the synthetic credential all live under `/home/hostuser`, and `security-test.sh` read three of them as missing — one of which reports as `REAL TOKEN ***` | `docker-entrypoint.sh` |

**What container-root does not weaken:** every guard that matters is mount-level or FUSE-level,
not DAC. `:ro` binds (the policy file, the synthetic credential, `/etc/passwd`) beat uid 0, and
redaction is the FUSE server's own `EPERM`. With no `CAP_SYS_ADMIN` the box still cannot remount
anything. What it does gain is package installs inside its own container — ephemeral, and the
policy text says so.

Two bugs the first real launch found, both in the rootless branches themselves:

- **`gosu` needs `CAP_SETUID`/`CAP_SETGID` even to switch to the uid it already is** — it calls
  setgroups/setgid/setuid unconditionally. With the caps correctly dropped, the container died at
  `error: failed switching to "0:0": operation not permitted`, taking the whole launch with it.
  Both call sites (the entrypoint's tail and `kib_run_session`) now skip gosu when there is
  nobody to switch to.
- **A bind-to-self can outlive its own mountpoint, and `grep` cannot tell the corpse apart.**
  `fuse_root_destroy` rm -rf's a directory whose bind lives in a namespace it cannot see, so the
  next launch's "is it already mounted?" check matched a mount with a deleted root, skipped the
  bind, marked the corpse shared and failed the sidecar with the same "not a shared mount" error
  the fix exists to prevent — on *every* later launch. `fuse_root_create` now binds
  **unconditionally**, after unmounting whatever is there (a loop, since launches can stack them,
  driven off umount's exit status — a path test cannot see a corpse, which /proc renders as
  `<path>\040(deleted)`). Self-healing, rather than trusting the teardown pair.

One accepted residual:

- **A host dev server on `127.0.0.1` is unreachable from the box.** `dockerd-rootless.sh` runs
  slirp4netns with `--disable-host-loopback`, so `host.docker.internal` reaches the host's LAN
  address only. Bind dev servers to `0.0.0.0`. (`DOCKERD_ROOTLESS_ROOTLESSKIT_DISABLE_HOST_LOOPBACK=false`
  in the user unit lifts it, at the cost of exposing the host's loopback to every container.)

And one thing NOT to "fix": the five caps (`SETUID/SETGID/CHOWN/DAC_OVERRIDE/FOWNER`) are added
back only when **not** rootless, and must stay that way. They exist for `useradd` + `gosu` into
hostuser, neither of which happens when the target user is already root — and because the session
runs AS root there, granting them puts them in `CapEff` instead of leaving them inert at a non-root
uid, which fails `security-test.sh`'s `CapEff=0` assertion. The rest of the entrypoint's root pass
(shims, symlinks, chowns) still runs on every container creation; only the user creation is skipped,
and its chowns target ids it already owns, so they need no capability.

## Identical on both platforms

`.kibignore` rules and the FUSE server/matcher behind them · the host-executed-config guard
(`.git/config`, hooks, `.vscode/`, `.devcontainer/`, `.envrc`) · the git audit gate at cold
start, teardown and `kib audit` · per-launch config assembly and subtree merge-out · the credential
broker and MCP interception · the verb CLI · `cap-drop=ALL` + `no-new-privileges` + seccomp on the
agent's own process · one container per project with the same lock protocol.

`tests/security-test.sh` is one suite for both, with no mode detection left in it: the only
platform-conditional assertion is the AppArmor label, which is *skipped* when the kernel has no
AppArmor at all (LinuxKit).

## TODO — checks not yet run

Tracked in `macos.md` § "Still open".

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
| Two sets of `projects/`, `.claude.json`, `↑` history | box path ≠ host path while the view was mounted in-container; the sidecar's `$PWD` bind makes them one key again, and the re-keying argument is gone | `wiring.sh`, `test_config_scope.py` |
| No `commands/` in the box | the merge farm returned early with no shared source | — (entrypoint) |
| 3 `lock_fd` failures + 2 false passes | the shim suite used GNU `flock(1)` as its own oracle | `portability.sh` now holds `shims.sh` to the contract |
| AppArmor assertion cannot pass | LinuxKit ships no AppArmor | `security-test.sh` skips when the label is empty |

## Fixed since

- `kib sleep-monitor` had no darwin guard. It is a host-global verb that `exec`s before
  `preflight_platform`, and every source it samples (`systemd-inhibit`, KDE `qdbus`, `/proc`) is
  Linux-only, so on macOS it wrote an empty diagnostic log — which reads as "nothing is holding
  the machine awake" rather than "this tool does not apply here". It now refuses with exit 2 and
  points at `pmset -g assertions`, guarded in `wiring.sh` by stubbing `uname`.
