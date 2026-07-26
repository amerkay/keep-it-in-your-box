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

Gates are `FUTURE_TASKS.md` § The gates: **CAP** (can it still mount the FUSE view), **OS** (one
design for Ubuntu *and* macOS), **POST** (redaction survives), **LIVE** (workspace at the same
absolute path).

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
# Does the substrate give a guest container /dev/fuse + SYS_ADMIN long enough to mount?
docker run --rm --cap-add=SYS_ADMIN --device /dev/fuse --security-opt apparmor=unconfined \
  keep-it-in-your-box sh -c 'ls -l /dev/fuse && python3 -c "import fuse; print(\"ok\")"'
```
