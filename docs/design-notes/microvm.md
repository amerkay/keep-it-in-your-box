# Wrapping kib in a microVM

**Verdict: not planned.** A hypervisor closes none of kib's documented risks and costs most of its
integration surface. This note exists so the question is answered once rather than re-litigated.

**Re-confirmed 2026-07-28** against a 30-project survey
([`../competitive-review.md`](../competitive-review.md)), which hardens it twice over. The CAP gate
below is not merely hard to pass but unpassable by construction: kib serves the redaction view from
a *sidecar* container that mounts FUSE and propagates it into the agent's namespace, and a
hypervisor-per-container gives that mount nowhere to land — so adopting one deletes the only
control the survey found nothing else combines (stub-on-read, after-launch coverage, capless
agent). And the field's VM adopters bought a kernel boundary and nothing above it: `cleanroom`'s
SporeVM has no networking at all on Linux/AMD64, `matchlock` is open NAT passthrough, and
`microsandbox` allows the public internet by default.

**Changed 2026-11: the Docker engine runs in one kib-managed Lima VM, `kib-vm`, while kib stays
on the host** ([`../vm.md`](../vm.md), `host/vm.sh`, `PLAN_VM_SECURITY.md`). Always on macOS
(Docker Desktop dropped), opt-in on Linux. The CAP gate rules out a VM *per container*, not one VM
holding the agent and the FUSE sidecar together. Three choices carry it:

**Changed again 2026-11-07: the box runs on gVisor inside that VM, and the VM mounts `~`**.
The two-hop Mutagen sync, `vm-rw`/`vm-ro` and the native Linux path are
gone. Measured on Linux and macOS (`sn-frontend`):

- **virtiofs, not 9p:** 9p wrote ~6× slower than a VM disk, virtiofs ~1.5×. Linux needs
  `virtiofsd`; without it kib refuses rather than fall back.
- **Build folders on VM volumes:** `pnpm install` through FUSE over virtiofs took 130 s plain and
  280 s on gVisor; with `node_modules` on a volume, 6 s and 13 s. FUSE was the cost.
- **gVisor's cost:** `git status` ×0.8, `find` ×1.2–1.5, small-file writes ×1.6–2.0.
- **No native gVisor yet:** rootless Docker runs it only with `--ignore-cgroups`, so boxes lose
  memory and CPU limits (measured 2026-11-09, `PLAN_NFS_VIEW.md` Test 11), and rootful Docker's
  socket is root-equivalent. So one route: the VM, rootful inside, on both OSes.

**Changed 2026-11-09: the VM no longer mounts `~`, nor any raw project** (`_vm_mounts`). It shares `~/.claude` and kib's own dirs, a fixed set, so it never restarts. Each project reaches it only as its redacted view: the view runs on the host as an NFS server, VM root mounts it, the box binds that mount (`PLAN_NFS_VIEW.md`). A first try shared each opened project and restarted the VM for a new one, resuming the sessions it cut; the user lost unsent input, so it was removed. The FUSE sidecar went with it.

**Changed 2026-11-13: on Linux, rootless gVisor is the default wherever rootless Docker runs** (`engine_choice`; `vm = on` keeps the VM, `vm = off` forbids it, and Linux without rootless Docker falls back to it with a hint). Measured with `kib stats` on a Framework 13, two idle boxes: the qemu VM cost ~0.30 cores (its own overhead 0.2–0.45, 1–2 cores under load), rootless ~0.13; the laptop idled at 6.6–7 W. KVM halt-polling off changed nothing, and qemu's I/O thread (network, NFS) was ~0.05: the cost is gVisor running inside the guest. macOS's vz VM measured ~0.1 cores of overhead, so the Mac keeps the VM. The trade: one barrier, no box limits.

**Changed 2026-11-13, later: rootful Docker is a no-VM engine too, picked from a first-launch menu** (`host/engine.sh`; `kib engine` reopens it). kib never runs sudo, so rootful's one-time steps (gVisor in `/opt/kib-gvisor`, FUSE `user_allow_other`, `systemctl reload docker`) are printed and kib stops. An escape there lands as root, but on a single-user laptop the user already holds what matters (keys, logins), so the menu ranks it below rootless, above the VM, and each launch says rootless is safer. The box runs as the user, as in the VM, and keeps its cgroup limits; the view is the FUSE one with `--allow-other`. Docker 29 writes `invalid IP` for `host-gateway` there too, so the box gets the bridge's gateway. Proven: `security-test.sh` 178 passed, 0 failed, in a rootful box.

A shared lock on fd 205 counts sessions. The last one out starts a 10-minute timer; it stops the
VM only if no session holds fd 205 by then and no later close has replaced it. Views mount at
`/mnt/kib/<hash>` in the VM.

**Memory: Lima's 4 GiB, doubled after an out-of-memory kill** (`_vm_oom`: the VM's
`/proc/vmstat` read at each session close, applied at the next boot, up to half the host's RAM).
Neither engine hands memory back while the VM runs (Lima's QEMU has no balloon, and it never moves
vz's), so file cache fills any limit: a 4 GiB VM held 4.0 G of the host's `/dev/shm`. A bigger
default stays taken; a cache trimmer (`memory.reclaim` works) was judged not worth it. On Linux the
limit must stay under `/dev/shm`: QEMU backs guest RAM there for virtiofs. **zram swap at each
boot** (`_vm_zram`, half the VM's RAM): gVisor holds a box's memory as shmem, which no swap meant
nothing could move, and the OOM killer's pick is a whole box (`gvisor_sentry`), every session in
it. Measured: 4 projects, about 2 GiB of boxes, a 500 MB sentry killed.

**Disk: cleaned once a day at a project's last exit** (`disk_cleanup`), in the foreground so the user sees what it freed. The disk image only grows: BuildKit's cache had reached 20 GB of a 38 GB disk, old images stayed pinned because the post-build prune runs while boxes still use them, and volumes outlived their projects. A project's volumes go once its stamp (`$KIB_STATE_ROOT/.used/<project>`, touched at its last exit) is `cleanup_days` old; Docker refuses a volume in use. Build cache: pruned whole; the image carries an inline cache (`BUILDKIT_INLINE_CACHE=1`, `--cache-from` the current image), so a Claude upgrade still reuses every layer above it (measured: 10 s after a full prune). That needs Docker's **classic storage** (`_vm_classic_store`, set at boot, a VM moved once with its images pruned first): containerd's store reads `--cache-from` as a registry ref and silently rebuilds everything, and it keeps a compressed copy of every image (3 GB here). Measured: 37 GB → 13 GB. Keeping the last build's cache cost ~7 GB, a second copy of the image's layers, not shared with them. `--keep-storage 5GB` left 11 GB (it reserves, it never caps); a fixed age made a Claude upgrade after a quiet week a 10-minute rebuild. The view, outside the image, has no such cache, so it is built only when a hash of its sources' contents changes (`kib-view.src`; an mtime test missed an `rsync -a`). The storage move checks the driver Docker reports, not `daemon.json`, and renames the new `daemon.json` in. Image: apt `--no-install-recommends` (what a tool needed from them is named), npm and Playwright caches cleaned in their layers, the view built on `golang:*-alpine`. Containers prune with `until=1h`: a box between create and start reads as stopped. `fstrim` returns the freed blocks to the host's sparse file; containerd deletes pruned snapshots seconds after the prune returns, so the idle stop (`_vm_linger_end`) trims again. `ls` keeps showing the qcow2's old length; `du` is the real cost. Under rootless only images and volumes: the other steps would hit the user's own Docker. Its default containerd store gets no `--cache-from` (it errors there); it keeps its build cache instead, which that cleanup leaves alone.

**Docker updates only at the idle stop** (`_vm_linger_end`). Its apt repo is outside
unattended-upgrades' origins, and its restart cuts every `docker exec`, so every session, even
with `live-restore` (measured: the box stayed up, its terminal died).

**Running all of kib inside the VM was tried first and abandoned the same day.** The guest's own
`$HOME` left it with no `~/.claude`, no login and no broker. `~/.claude.json` is a file directly in
`$HOME`, and Lima mounts only directories. The ssh hop also corrupted the TUI.

## Why it is overkill

kib's risks cross the boundary through **files the host executes later**, never through the kernel:
`.git/hooks/pre-commit`, `.git/config` (`core.pager`, `alias.*`, `filter.*.clean`), `.vscode/`,
`.devcontainer/`, `.envrc`, `~/.claude/settings.json` `hooks[].command`.

Every substrate below shares the workspace back to the host at the same absolute path — that is
the product. A hypervisor changes *how* those bytes travel (virtiofs, not a bind); it does not
change that they arrive, or that the host runs them afterwards. **The view's guard remains the only
mechanism against this class, on any substrate.**

What a microVM does close is host-**kernel** exploitation. Real, but the agent already runs with an
empty capability bounding set, `no-new-privileges`, seccomp in filter mode, and read-only
`/proc/sys` and `/sys`. The residual is "an unprivileged, seccomp-filtered process finds a kernel
0-day" — not the threat kib was built for.

## Options

Four gates. A substrate that violates one is **DISQUALIFIED**, not low-rated:

| Gate | Requirement |
|---|---|
| **CAP** | Every process the agent runs keeps `CapEff=0` and **no `CAP_SYS_ADMIN`/`CAP_SETPCAP` in its bounding set** — and a *sidecar* container can still mount the FUSE view and propagate it to the agent's. kib serves it that way on both platforms (`macos.md`), so a substrate that isolates containers from each other fails here even if it grants `/dev/fuse`. |
| **OS** | One design covers Ubuntu *and* macOS. |
| **POST** | Redaction covers files created **after** launch, not only those present at start. |
| **LIVE** | The project stays a live mount at the same absolute path — Claude's configs are path-keyed. |

| Option | Added dep | CAP | OS | Verdict |
|---|---|---|---|---|
| **Docker Sandboxes** (`docker sbx`) | none | unverified | ✅ | A competing whole, not a substrate: adopting it deletes the broker, the egress design, the lifecycle manager and the clipboard proxies |
| **Lima** under Docker | Lima, Mutagen | ✅ | ✅ | **Adopted 2026-11** (above): one VM under Docker on both OSes, projects synced in |
| **Kata Containers** | KVM + containerd cfg | unverified | ❌ Linux | Per-container VM boundary, but heavy and not minimal |
| **Apple `container`** / libkrun | macOS 15+ | unverified | ❌ macOS | First-party and young; partial Docker API, and kib drives `docker` in ~40 places |
| **gVisor** (`runsc`, agent container only) | runsc + root `daemon.json` | unverified | ❌ Linux | Closest fit, still not worth it — see [gVisor](#gvisor) |
| **Stay put + tighter seccomp** (K1) | none | ✅ | ✅ | **The only row that passes all four gates** |

## What any of them would cost

Each of these is a host↔container seam a VM boundary severs or reroutes: the Wayland clipboard
proxy and the macOS pbpaste bridge (unix sockets do not cross a hypervisor — need a vsock relay),
live DNS sync, the `kib-broker` network alias and dual-homing (both Docker embedded-DNS features),
`host.docker.internal`, `docker top` readiness detection, the sleep guard's rw marker bind (the box
writes it, the host reads it), bind mounts becoming virtiofs, and
`docker exec` as the whole many-terminals-one-container attach model. Adopting any option is a
re-platforming, not a flag.

## gVisor

Adopted 2026-11-07, probed first. The broker stays on runc. The seams the 2026-10-04 review listed, and their answers:

- **Broker net:** runsc wires NICs only at start → `docker create`, `network connect`, `start`.
- **Embedded DNS (`127.0.0.11`):** unreachable → the broker is an `--add-host` entry and the box
  gets the VM's resolvers as its `resolv.conf` (`vm_resolv`).
- **inotify:** host edits raise no event → `CHOKIDAR_USEPOLLING`, `WATCHPACK_POLLING`.
- **The view:** the VM's NFS mount of it, bound in before start. The box sees a gofer mount, so the attach check asks whether the host's view process lives and lists `$PWD` from the box. gVisor checks file modes itself, since the view runs as the host user.
- **`docker top`:** gVisor cannot answer it → readiness is the entrypoint's `/run/kib-ready`.
- **Wayland socket:** gone; the clipboard is the spool bridge on both OSes, so no
  `--host-uds`. Docker's seccomp profile is enforced inside (`--oci-seccomp`).
- **macOS file owners:** Apple's virtiofs reports the asker as a file's owner (cached per inode),
  so gVisor's root gofer saw kib's `700` dirs as root's → bindfs in the VM over `~/.claude` and
  kib's state (`_vm_owners`). Never over a project: the VM's NFS client sees real owners, and bindfs over kib's own checkout hung `docker run` when kib was the project. Kib's checkout and the Node cache are world-readable, so they need none. Always
  `--multithreaded`: single-threaded, bindfs hung on the first stat of a transcript, as root and
  as the user (multithreaded: 240 files in 0.1 s). Its open-file limit is raised to 1048576: it holds an fd
  per open directory, gVisor keeps one open per cached directory, and the default 1024 ran out on
  the plugin tree (`EMFILE` naming `~/.claude/plugins/…` in the box).
- **Rootless Docker:** gVisor runs only with `--ignore-cgroups` (no limits); on Linux that is still the default (above).

## If this is ever revisited

Before any of the four options above, one cheap measurement decides it — kib without its redaction
layer is not kib:

```
# 1. Does the substrate give a guest container /dev/fuse + SYS_ADMIN long enough to mount?
docker run --rm --cap-add=SYS_ADMIN --device /dev/fuse --security-opt apparmor=unconfined \
  keep-it-in-your-box sh -c 'ls -l /dev/fuse && python3 -c "import fuse; print(\"ok\")"'

# 2. …and does that mount reach a SECOND container? Root must be substrate-internal, never a
#    host file share. A hypervisor-per-container answers no here, whatever step 1 said.
docker run --rm --privileged -v /run/kib-probe:/p:rshared alpine \
  sh -c 'mkdir -p /p/m && mount -t tmpfs none /p/m && echo ok > /p/m/f'
docker run --rm -v /run/kib-probe:/p:rslave alpine cat /p/m/f
```
