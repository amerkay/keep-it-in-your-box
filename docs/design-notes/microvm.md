# Wrapping kib in a microVM

**Verdict: not planned.** A hypervisor closes none of kib's documented risks and costs most of its
integration surface. This note exists so the question is answered once rather than re-litigated.

## Why it is overkill

kib's risks cross the boundary through **files the host executes later**, never through the kernel:
`.git/hooks/pre-commit`, `.git/config` (`core.pager`, `alias.*`, `filter.*.clean`), `.vscode/`,
`.devcontainer/`, `.envrc`, `~/.claude/settings.json` `hooks[].command`.

Every substrate below shares the workspace back to the host at the same absolute path — that is
the product. A hypervisor changes *how* those bytes travel (virtiofs, not a bind); it does not
change that they arrive, or that the host runs them afterwards. **The FUSE guard remains the only
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
| **Lima / Colima** under Docker | 1, macOS only | ✅ | ❌ | Rejected outright. The VM sits under *Docker*, not under the agent — host-kernel isolation, not per-session — and it is a second engine to support for no risk kib ranks |
| **Kata Containers** | KVM + containerd cfg | unverified | ❌ Linux | Per-container VM boundary, but heavy and not minimal |
| **Apple `container`** / libkrun | macOS 15+ | unverified | ❌ macOS | First-party and young; partial Docker API, and kib drives `docker` in ~40 places |
| **Stay put + tighter seccomp** (K1) | none | ✅ | ✅ | **The only row that passes all four gates** |

## What any of them would cost

Each of these is a host↔container seam a VM boundary severs or reroutes: the Wayland clipboard
proxy and the macOS pbpaste bridge (unix sockets do not cross a hypervisor — need a vsock relay),
live DNS sync, the `kib-broker` network alias and dual-homing (both Docker embedded-DNS features),
`host.docker.internal`, the sleep guard's `docker top` sampling, bind mounts becoming virtiofs, and
`docker exec` as the whole many-terminals-one-container attach model. Adopting any option is a
re-platforming, not a flag.

## If this is ever revisited

Swapping the macOS engine is **not** the way in. It was considered and rejected: a second engine
to support, for a threat kib does not rank. macOS stays on Docker Desktop.

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
