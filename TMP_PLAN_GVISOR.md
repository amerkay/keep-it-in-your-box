# TMP plan: gVisor for the box, mounts instead of sync (delete when done)

Replaces the VM sync (`PLAN_VM_SECURITY.md`). Decided 2026-11-06 after `tmp_gvisor_probe.sh`.

## Target

| | Linux | macOS |
|---|---|---|
| Engine | Native Docker | Lima VM (kib installs it, no sudo) |
| Project | Bind mount through the FUSE view | Same; the VM mounts `~` once (virtiofs) |
| Agent box | `--runtime=runsc` (gVisor) | Same, gVisor provisioned in the VM |
| Sidecars (FUSE, broker, clipboard) | runc, as today | runc, as today |
| A kernel exploit needs | a gVisor bug + a host kernel bug | a gVisor bug + a VM kernel bug |

One code path: only where `dockerd` lives differs. No sync, no copies, no skip lists.

## Probe results (2026-11-06, in kib-vm)

- ✔ kib's flags + `gosu`; `--init`; `docker exec`
- ✔ FUSE view: `.env` redacted, `.git/hooks` refused, writes land
- ✔ Broker net when connected **before** start; `kib-broker` via `--add-host`; internet via
  our own `resolv.conf`. ✘ Docker's DNS (127.0.0.11): gVisor can't reach it, by design
- ✔ Unix-socket sidecar only with `--host-uds=open`
- ✘ `docker top` sees no processes → readiness needs another signal
- ℹ Host edits wake no watcher in the box → dev servers need polling
- Same results on macOS (2026-11-06, a Lima VM with `~` on virtiofs + gVisor)
- Speed vs runc, through the FUSE view (Linux / Mac): `git status` ×0.8 / ×0.8, `find`
  ×1.5 / ×1.3, 3000-file write ×1.7 / ×2.0. **`pnpm install`, warm cache, `sn-frontend`
  : Linux 112 s → 227 s (×2.0), Mac 109 s → 243 s (×2.2).** The 112 s is mostly the Python FUSE view, which every
  design pays

**Blocker for native Linux (2026-11-06): the user's Docker is rootless, and gVisor does not
support rootless Docker** (google/gvisor#12575: the workarounds are `--TESTONLY-unsafe-nonroot`
or `--network=host`, both unacceptable). Candidate: Lima on Linux too, as on macOS (rootful
Docker + gVisor inside the VM, `~` mounted; one route, no sudo). Open: `~` mount speed on
Linux (virtiofs needs `virtiofsd`; 9p was slow). Probe: `tmp_gvisor_probe.sh --mount`.

## Phase 0: last probes (user)

- [x] `pnpm install` timing (Linux): ×2.0
- [x] Mac: the probe in a Lima VM with `~` on virtiofs: all checks pass
- [x] Mac `pnpm install` timing: ×2.2
- [ ] Decide: C (kib runs Lima + gVisor on Mac) or D (kib runs no VM; gVisor whenever the
      user's Docker engine has it: Linux, Colima. Docker Desktop/OrbStack get none)

## Phase 1: gVisor box on native Linux

- [ ] Detect runsc: `docker info --format '{{json .Runtimes}}'`. Missing → print the one-time
      install (gVisor apt repo, `runsc install -- --host-uds=open`, `systemctl reload docker`)
      and run on runc with a warning, like today's no-Lima note
- [ ] `start_container`: `docker create` → `connect_broker_network` → `docker start`
- [ ] `--add-host kib-broker:<ip>` and one per MCP sidecar alias (`docker inspect` the IP)
- [ ] Our own `resolv.conf` bind (the host's resolvers; reuse `resolv-sync`'s source)
- [ ] Readiness: entrypoint touches `/run/kib/ready` before `exec sleep infinity`; kib polls
      `docker exec test -e`. Drop `docker top` (rebuild)
- [ ] Polling env: `CHOKIDAR_USEPOLLING=1 WATCHPACK_POLLING=true`; one line in etc-CLAUDE.md
- [ ] `security-test.sh`: the box runs on gVisor (`dmesg` says gVisor)
- [ ] Rootless Docker: runsc is experimental there → runc + warning

## Phase 2: macOS on Lima with `~` mounted

- [ ] VM mounts `~` (virtiofs, writable) instead of the fixed set; projects outside `~` refused
- [ ] Provision a pinned runsc (sha512) at VM creation, registered with `--host-uds=open`
- [ ] Keep: Lima install pins, linger, `engine_ns_exec` over `limactl shell`, note replay

## Phase 3: delete

- [ ] Linux VM mode (`vm` key, `KIB_VM`), Mutagen and its install
- [ ] `vm_sync_*`, `_vm_session`, `_vm_slow_hint`, sync cleanup in `_vm_linger_end`
- [ ] `kib/host/vmseed.py`, `rules.py` sync configs, `VM_LOCAL`, `vm_skip`
- [ ] `vm_state`, `vm-rw`/`vm-ro`, the `-vm` Node cache split (all visible under `~` anyway)
- [ ] Their tests (`tests/check/vm.sh` sync parts, `test_vmseed.py`), `tests/vm-check.sh`
- [ ] Keep the per-project package cache volume (fast reinstalls, never shared)

## Phase 4: docs

- [ ] `microvm.md`: gVisor adopted; why its old rejection no longer holds (DNS → host entries,
      NICs → create/connect/start, inotify → polling)
- [ ] `CLAUDE.md` dead ends: drop the sync one; add "never rely on Docker's DNS in the box"
- [ ] `docs/vm.md` → macOS only; `README.md`, `platform-matrix.md`, `etc-CLAUDE.md`
- [ ] Mark `PLAN_VM_SECURITY.md` superseded

## Accepted costs

- Writes ~2× slower in the box: `pnpm install` 112 s → 227 s on `sn-frontend`; reads unchanged
- Dev servers poll for host edits
- Mac: the box's Linux `node_modules` land in the real folder
- Mac: VM root (behind gVisor) could read all of `~`
- Linux: one `sudo` to install gVisor
