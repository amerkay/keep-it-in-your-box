# TMP plan: Lima + gVisor on both OSes, mounts instead of sync (delete when done)

Replaces the VM sync (`PLAN_VM_SECURITY.md`). Comes after `TMP_PLAN_GO_FUSE.md`. Decided 2026-11-06 from `tmp_gvisor_probe.sh` and
`tmp_nm_probe.sh` runs on Linux and macOS.

## Target

| | Linux and macOS alike |
|---|---|
| Engine | Lima VM `kib-vm` (rootful Docker inside; the host's own Docker is untouched, rootless or not) |
| Project | `~` mounted into the VM once (virtiofs); the box binds the project through the FUSE view |
| VM-local folders | `node_modules`, `.venv`, … on a VM volume (`TMP_PLAN_GO_FUSE.md` Phase 3) |
| Agent box | `--runtime=runsc` (gVisor), mandatory |
| Sidecars (FUSE, broker, clipboard) | runc, as today |
| A kernel exploit needs | a gVisor bug + a VM kernel bug; then VM root sees `~` |

One route. No sync, no copies, no skip lists. Linux needs `virtiofsd` (one `sudo apt install`).

## Why (measured)

- gVisor does not support rootless Docker (google/gvisor#12575), so native Linux is out
- 9p is ~6× slower than a VM disk for writes; virtiofs ~1.5×
- Through FUSE over virtiofs, `pnpm install` (`sn-frontend`): plain 130 s, gVisor 280 s. With
  `node_modules` on a VM volume (no scripts): plain 6 s, gVisor 13 s. FUSE was the cost
- gVisor: `git status` ×0.8, `find` ×1.2–1.5, small-file writes ×1.6–2.0
- All security checks pass on both OSes: `.env` redacted, `.git/hooks` refused, broker, internet,
  sockets, FUSE view read and write
- Dead: KVM mode (no gain), pnpm's virtual store outside the project (breaks resolution)

## Phase 1: the box on gVisor (in the VM)

- [ ] Provision a pinned runsc (sha512) at VM creation: `runsc install -- --host-uds=open`
- [ ] `start_container`: `docker create` → `connect_broker_network` → `docker start`
- [ ] `--add-host kib-broker:<ip>` and one per MCP sidecar alias (Docker's DNS is unreachable)
- [ ] Own `resolv.conf` bind (the VM's resolvers)
- [ ] Readiness: entrypoint touches a marker before `exec sleep infinity`; kib polls
      `docker exec test -e`. Drop `docker top` (rebuild)
- [ ] Polling env: `CHOKIDAR_USEPOLLING=1 WATCHPACK_POLLING=true`; one line in etc-CLAUDE.md
- [ ] `security-test.sh`: the box runs on gVisor

## Phase 2: mounts instead of sync

- [ ] VM mounts `~` writable (virtiofs) instead of the fixed set; projects outside `~` refused
- [ ] Linux: no `virtiofsd` → print `sudo apt install virtiofsd`, refuse (9p is too slow)
- [ ] FUSE sidecar serves `$PWD` (the mount), not a volume

## Phase 3: delete

- [ ] Mutagen and its install; `vm_sync_*`, `_vm_session`, `_vm_slow_hint`, sync cleanup in
      `_vm_linger_end`
- [ ] `kib/host/vmseed.py`, what is left of `rules.py`/`render.py` (the sync's), `VM_LOCAL`, `vm_skip`
- [ ] `vm_state`, `vm-rw`/`vm-ro`, the `-vm` Node cache split (all under `~` now)
- [ ] The `vm` setting and the non-VM path (gVisor is mandatory, and only the VM has it)
- [ ] Their tests (`tests/check/vm.sh` sync parts, `test_vmseed.py`), `tests/vm-check.sh`
- [ ] Keep: Lima install pins, linger, `engine_ns_exec` over `limactl shell`, note replay,
      the package cache volume

## Phase 4: docs

- [ ] `microvm.md`: gVisor adopted; the old rejection's answers (DNS → host entries, NICs →
      create/connect/start, inotify → polling); rootless blocks native gVisor
- [ ] `CLAUDE.md` dead ends: drop the sync one; add "no Docker DNS in the box", "9p too slow",
      "node_modules through FUSE is the install cost"
- [ ] `docs/vm.md`, `README.md`, `platform-matrix.md`, `etc-CLAUDE.md` (node_modules is
      box-only; host edits need polling)
- [ ] Mark `PLAN_VM_SECURITY.md` superseded

## Accepted costs

- Small-file writes ~1.6–2× slower in the box (installs are fast again via the volume)
- Dev servers poll for host edits
- VM root (behind gVisor) can read all of `~`
- The box's `node_modules` is its own: one install per project, from the cache
- VM boot (~13 s) on a cold start; Linux needs `virtiofsd`
