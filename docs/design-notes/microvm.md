# Wrapping kib in a microVM

Docker Sandboxes (`docker sbx`) runs each agent session in a microVM rather than a container, which
raises the obvious question for kib. This note is the answer: **what a hypervisor actually closes
for kib (very little), what it costs (a lot of kib's surface area), and the option matrix** for
Ubuntu + macOS with minimal added dependencies.

Nothing here is scheduled. It exists so the question is answered once, with the measurements
attached, instead of re-litigated.

---

## Why this became possible at all

kib used to serve the redacted project view from a **separate FUSE container**, reaching the agent
container over `rshared`/`rslave` **mount propagation**. Propagation is a shared-kernel feature:
two mount namespaces of the *same* kernel can share a peer group, two kernels cannot. That
topology therefore could not run on macOS (measured on Docker Desktop 4.78.0 — see `macos.md`) and
foreclosed **every** hypervisor-isolated substrate, permanently.

The redaction layer now mounts **inside** the one project container, so nothing kib does depends on
propagation. That is what makes the rest of this note discussable. The trade paid for it is
capless-at-*runtime* instead of capless-at-*creation* (`docs/FUTURE_TASKS.md` § The gates).

---

## What a microVM does NOT close

**This is the headline, and it is unintuitive.** Read it before evaluating any option below.

kib's documented risks cross the boundary through **files the host executes later**, not through
the kernel:

- the agent writes `.git/hooks/pre-commit`; **you** commit on the host and the host runs it
- the agent writes `.git/config` `core.pager` / `alias.*` / `filter.*.clean`; your next `git` runs it
- the agent writes `.vscode/tasks.json`, `.devcontainer/`, `.envrc`; your editor or `direnv` runs it
- the agent writes `~/.claude/settings.json` `hooks[].command`; **every** project's next session runs it

Every option below shares the workspace back to the host at the same absolute path — that is the
product. A hypervisor changes *how* those bytes travel (virtiofs instead of a bind mount); it does
not change that they arrive, or that the host executes them afterwards. **kib's FUSE guard remains
the only mechanism against this class**, on any substrate.

What a microVM *does* close: host **kernel** exploitation — a container escape via a kernel LPE,
a namespace/cgroup bug, an `io_uring` primitive. Real, and worth something. But kib already runs
the agent with an empty capability bounding set, `no-new-privileges`, seccomp in filter mode, and
read-only `/proc/sys` and `/sys`. The residual is "an unprivileged, seccomp-filtered process finds
a kernel 0-day", which is not the risk kib was built for.

**Net: a microVM would harden a threat kib does not currently rank, at the cost of most of the
integration surface below.** That is why K3 stays a dead end in `FUTURE_TASKS.md` even though half
its original justification (**OS**: "needs KVM, unavailable under Docker Desktop") has expired.

---

## What every option would break

kib is not only a container. Each of these is a host↔container seam that a VM boundary either
severs or forces through a different mechanism:

| Seam | Where | What a VM boundary does to it |
|---|---|---|
| Wayland clipboard proxy | `host/desktop.sh` | Binds the host's `$WAYLAND_DISPLAY` socket. A unix socket does not cross a hypervisor — needs a vsock relay. |
| macOS pbpaste bridge | `host/clipboard-bridge.sh` | Spool dir + a host-side process. Same problem, same fix. |
| Live DNS sync | `host/net.sh`, `guest/bin/resolv-sync.sh` | Rewrites the container's `resolv.conf` keeping `127.0.0.11` first. A VM has its own netstack; Docker's embedded DNS may not exist. |
| `kib-broker` network alias | `host/broker.sh` | Depends on Docker's embedded DNS on a user-defined network. |
| Broker dual-homing | `connect_broker_network` | Two Docker networks at once. No equivalent for a VM guest. |
| `--add-host=host.docker.internal` | `host/lifecycle.sh` | Host dev servers must stay reachable. Needs an explicit route. |
| Sleep guard | `host/sleep-guard.sh` | Samples the container's busiest process via `docker top`. A VM guest is opaque to that. |
| Bind mounts generally | everywhere | Become virtiofs: root:root ownership (hence `--uid/--gid` on the FUSE mount), different `flock` semantics, different latency. |
| One container, many terminals | `host/lifecycle.sh` | `docker exec` into a long-lived container is the whole attach model. A VM needs an in-guest agent instead. |

Costed honestly, adopting any option below is a **re-platforming**, not a flag.

---

## The options

Ordered by added dependency, lowest first.

### 1. Docker Sandboxes (`docker sbx`) — Ubuntu + macOS, zero new dependency

Docker's own microVM-per-session runtime. Ships with Docker Desktop / Docker Engine, so a user who
can run kib today can run this today. Private Docker daemon per sandbox, deny-by-default network
with a domain allowlist, host-side credential proxy, workspace shared at the same absolute path.

- **Pro** — no new dependency on either OS; the only option with a first-party macOS story; its
  network allowlist and credential proxy are convergent with kib's E1 and broker designs.
- **Pro** — same-absolute-path workspace sharing means the **LIVE** gate survives.
- **Con** — experimental, and its API is not stable enough to build a product seam on.
- **Con** — it is a *competing whole*, not a substrate. Adopting it means deleting the broker, the
  egress design, the lifecycle manager and the clipboard proxies, and accepting Docker's versions.
  That is not "kib in a microVM", it is "use sbx instead of kib".
- **Con** — the FUSE mount needs `/dev/fuse` and `SYS_ADMIN` in the pre-agent window. Whether a
  sandbox VM grants that is **unverified**.

### 2. Lima (macOS) + plain Docker (Ubuntu) — one new dependency, macOS only

Run the existing Docker engine inside a Lima VM on macOS; leave Ubuntu on the host engine.

- **Pro** — kib's container topology is completely unchanged; this is a substrate swap under it.
  Colima is already a supported engine, and Colima *is* Lima, so much of this path is proven.
- **Pro** — a real Linux kernel, so `/dev/fuse` and the mount work exactly as they do on Ubuntu
  (unlike LinuxKit, which is what forces `apparmor=unconfined` and skips the AppArmor assertion).
- **Con** — **one design does not cover both OSes**, so it fails the **OS** gate as a unified
  answer. It is a macOS engine recommendation, which kib already makes.
- **Con** — the VM boundary is under Docker, not under the agent: a container escape inside the
  Lima VM still reaches every other kib container. It buys host-kernel isolation, not per-session
  isolation.

### 3. Kata Containers — Ubuntu only, heavy

`--runtime=kata` transparently backs each container with a Firecracker/QEMU microVM.

- **Pro** — genuinely transparent at the `docker run` level; per-container VM boundary.
- **Con** — needs KVM, containerd configuration, and a `kata-runtime` install. Not "minimal".
- **Con** — Linux-only: fails **OS**.
- **Con** — virtiofs ownership and `/dev/fuse` passthrough into a Kata guest are both
  **unverified** for kib's mount. Likely workable, definitely not free.

### 4. Apple `container` / libkrun — macOS only, young

Apple's native container runtime (macOS 15+) puts each container in its own lightweight VM on
Hypervisor.framework.

- **Pro** — first-party, per-container VM, no Docker Desktop licence question.
- **Con** — macOS-only: fails **OS**.
- **Con** — young, and its Docker API compatibility is partial. kib drives `docker` directly in
  ~40 places; every one would need verifying.

### 5. Stay put: K1 (tighter seccomp) — the honest recommendation

The threat a microVM closes is host-kernel exploitation from an already-capless, already-filtered
process. A **tighter custom seccomp profile** (`FUTURE_TASKS.md` § K1) narrows that same syscall
surface for one JSON file, no new dependency, no OS divergence, and no re-platforming — and it is
the only item in this note that passes all four gates.

---

## Gate analysis

| Option | CAP | OS | POST | LIVE | Verdict |
|---|---|---|---|---|---|
| Docker Sandboxes | unverified (`/dev/fuse` in the VM) | ✅ | ✅ (kib's FUSE, if it mounts) | ✅ | Replaces kib rather than hosting it |
| Lima + Docker | ✅ | ❌ macOS-only | ✅ | ✅ | An engine recommendation, already made |
| Kata | unverified | ❌ Linux-only | ✅ | ✅ | Fails OS; heavy |
| Apple `container` | unverified | ❌ macOS-only | ✅ | ✅ | Fails OS; young |
| K1 seccomp | ✅ | ✅ | ✅ | ✅ | **The one that passes** |

---

## If this is ever revisited

The prerequisite for *any* of the first four is a single measurement, and it is cheap:

```
# Does the substrate give a guest container /dev/fuse + SYS_ADMIN long enough to mount?
docker run --rm --cap-add=SYS_ADMIN --device /dev/fuse --security-opt apparmor=unconfined \
  keep-it-in-your-box sh -c 'ls -l /dev/fuse && python3 -c "import fuse; print(\"ok\")"'
```

If that fails on the candidate substrate, the option is dead before any of the seams above matter —
kib without its redaction layer is not kib.
