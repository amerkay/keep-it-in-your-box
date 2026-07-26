<img src="../assets/sandbox-comparison/head-to-head-hero.svg" alt="Head to head — kib measured against five agent sandboxes. Of those five, none content-validate .git/config, none mediate the clipboard, two default-deny egress, and two broker credentials — kib brokers too." width="100%">

# Six sandboxes, side by side

Five actively-developed agent sandboxes, measured against `kib` on the controls that decide whether an untrusted repo can reach the host. Verified 2026-07-22; `kib`'s own column reflects the current tree.

| | |
|---|---|
| **[fence](https://github.com/fencesandbox/fence)** | Container-free. bubblewrap + Landlock + seccomp on Linux, Seatbelt on macOS. |
| **[sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime)** | Anthropic's own. bubblewrap + Seatbelt, the engine behind Claude Code's `/sandbox`. |
| **[cplt](https://github.com/navikt/cplt)** | Landlock-first, from the Norwegian Labour and Welfare Directorate. |
| **[yoloAI](https://github.com/kstenerud/yoloai)** | Six backends, up to Firecracker microVMs. Brokers credentials. |
| **[aicontainer](https://github.com/stefanoginella/aicontainer)** | Devcontainer + Docker socket proxy, multi-project. |
| **`kib`** | *This repo.* One Docker container per project, FUSE redaction, clipboard proxy, credential broker. |

---

## The verdict

**`kib` is alone on two controls and outvoted on one.**

It is the only one of the six that reads the bytes of a host-executed config file before deciding, and the only one that mediates the clipboard rather than granting or withholding it wholesale. It is one of three that brokers the account credential. It remains one of three with no egress restriction at all — the single column it concedes.

Where a project's docs are silent, this says so rather than guessing. Several of the sharpest findings are things a project documents *against itself*.

---

## Where `kib` stands alone

### 1. It validates `.git/config` instead of blocking it

<img src="../assets/sandbox-comparison/gitconfig-strategies.svg" alt="Four strategies for the .git/config problem: kib validates content, fence and sandbox-runtime and aicontainer and cplt-on-macOS block all writes, yoloAI neutralizes git invocations, cplt on Linux leaves it writable." width="100%">

`.git/config` is the sharpest instance of the general problem: a file the sandbox can write, that the *host* executes later, unsandboxed. `core.hooksPath`, `core.fsmonitor`, `core.sshCommand`, `alias.*` and `filter.*.clean` all name commands git will run.

| Strategy | Projects | What it costs |
|---|---|---|
| **Validate** — read the file on `rename()`, diff against current, refuse only newly-added command-bearing keys | `kib` | Nothing. `git remote add` and `push -u` keep working. |
| **Block** — deny all writes | fence, sandbox-runtime, aicontainer, cplt *(macOS)* | `git remote add` fails inside the sandbox. fence ships an `allowGitConfig` escape hatch that turns the protection off entirely. |
| **Neutralize** — leave the file writable, harden every git invocation | yoloAI | Covers `hooksPath` and `fsmonitor`. Attribute-bound `filter.*` and `diff.*.textconv` drivers must still run for diff correctness — a documented residual. |
| **Leave open** — writable by design | cplt *(Linux)* | Its own SECURITY.md concedes an agent "can still set `core.hooksPath` to redirect hooks into a writable directory". |

Two structural gaps nobody else covers:

- **A git dir does not have to be called `.git`.** `git init --bare`, `--separate-git-dir`, and a `.git` gitfile holding `gitdir: ../store` all put config and hooks elsewhere. `kib` recognises one by layout (`HEAD` + `objects` + `refs`). fence walks for directories *named* `.git` to depth 3; sandbox-runtime scans with ripgrep to depth 3; neither documents the alternate layouts.
- **`include` / `includeIf` indirection.** An included file can declare `core.hooksPath` that a validator inspecting only the main file never sees. `kib` refuses newly-added includes. Moot for the four that block writes outright; not moot for cplt on Linux.

One gap `kib` does *not* have, worth naming because it is severe and self-documented:

> "On Linux, mandatory deny paths only block files that **already exist**. Non-existent files in these patterns cannot be blocked by bubblewrap's bind-mount approach."
> — sandbox-runtime README

A bind mount cannot cover a file that isn't there yet. cplt hits the same wall (`.cplt.toml` "can still be created"), and it is the specific reason `kib` uses FUSE: a FUSE filesystem sees the `create()` call.

### 2. It mediates the clipboard rather than granting it

| Project | Clipboard |
|---|---|
| `kib` | A proxy sidecar holds the only real socket. **Reads pass, writes refused** on all four Wayland clipboard interfaces; denials raise a desktop notification. macOS gets the same asymmetry via a one-way `pbpaste` bridge. |
| cplt | `--deny-clipboard` on macOS — all-or-nothing, and **reachable by default** (it rides the blanket `mach-lookup` Node.js needs). Listed under "Out of scope". |
| fence · sandbox-runtime | Not documented. |
| yoloAI | Nothing bridged. Terminal escape sequences over `attach` are explicit pass-through. |
| aicontainer | "Clipboard / browser — **No** — nothing bridged." |

The read/write asymmetry is the whole point. A clipboard *write* is host code execution at the user's next terminal paste — an embedded `ESC[201~` ends bracketed paste early and the rest is interpreted as typed input. A *read* is just a paste. Four of the five sidestep this by having no display access at all; cplt has access and offers an on/off switch.

---

## Where `kib` is behind: egress

| Project | Default | Mechanism |
|---|---|---|
| sandbox-runtime | **Default-deny** | Network namespace removed entirely; all traffic via host proxies on Unix sockets. Optional TLS termination. |
| fence | **Default-deny** | netns / Seatbelt + HTTP and SOCKS5 proxies with `HTTP_PROXY` injection. |
| aicontainer | Open, with always-on metadata/link-local drops | Opt-in iptables allowlist (`sudo aic-firewall enable`). |
| yoloAI | Open | Opt-in `--network-isolated` (iptables + ipset). |
| cplt | Open on 443 + allow-all proxy with a blocklist | Domain allowlist opt-in; proxy-forced mode opt-in. |
| `kib` | **Open** | None. Documented accepted risk. |

Only two of five ship default-deny, and note how thin the others' protection is even when enabled — and how candid they are:

- **cplt**: "**By default the proxy is not mandatory** — because `*:443` is kernel-allowed, a raw socket or `env -u HTTPS_PROXY` can reach the network without traversing the proxy."
- **yoloAI** shipped an in-container firewall the agent could flush, with the empirical proof in its own docs (`sudo iptables -F OUTPUT`, then a successful `curl`). Fixed for Docker by moving enforcement into a sidecar netns. Still IPv4-only — filed as DF104, "PARKED".
- **fence**: "domain filtering does not inspect content. If you allow a domain, code can exfiltrate via that domain."

`kib`'s position — a default-deny allowlist conflicts with building untrusted repos that fetch from arbitrary registries — is a real trade-off, not an oversight. It is still the minority position, and unlike cplt or yoloAI there is no opt-in mode to reach for. `docs/FUTURE_TASKS.md` (E1) holds the design.

---

## Credentials: `kib` is now one of three

`kib` brokers by default. A host-side sidecar holds a static token from `kib broker login`; the container gets `ANTHROPIC_BASE_URL` pointed at the broker, a placeholder `CLAUDE_CODE_OAUTH_TOKEN`, and a synthetic `.credentials.json` shadowing the real file. The broker re-originates TLS upstream, so there is no CA in the container. Two caveats: a launch with **no stored token and no interactive login** falls back to mounting the real credential with a warning, and `broker = off` / `KIB_BROKER=0` restores the old exposure by choice.

Two others do the same, by the same trick:

> "Instead of placing the credential in the container, it runs a tiny per-sandbox proxy on the host (the *broker*), points the agent at it with a harmless placeholder token, and swaps in the real credential on the way to the provider." — yoloAI

> "A masked credential's real value is replaced inside the sandbox with a sentinel of the form `fake_value_<uuid4>`. The sandboxed process sees only the sentinel; the host-side proxy substitutes sentinel→real on egress." — sandbox-runtime

Caveats from their own docs: sandbox-runtime's masking **requires TLS termination** and fails closed to a broken login otherwise; yoloAI's unresolved-findings file says its broker is "only wired for the Claude agent" while its guide claims three.

The remaining three are exposed. cplt: "the OAuth token lives in `~/.claude/.credentials.json`… **exposed to the sandbox**… an inherent trade-off." aicontainer's tokens live in one volume shared across every project: "a compromised session in **any** project can use every token you've logged in with."

`kib` extends the same broker past the LLM token — remote MCP credentials are injected as a header the container never sees (`reverse_proxy_mcp`), client-signed creds run in their own `cap-drop=ALL` sidecar (`hosted_mcp`), and `claude mcp add … --header …` is intercepted **host-side** so a vendor's copy-pasted line can't put a secret in the container's argv. No other project here documents an equivalent.

---

## The full matrix

### Isolation and platform

| | `kib` | fence | sandbox-runtime | cplt | yoloAI | aicontainer |
|---|---|---|---|---|---|---|
| **Boundary** | Docker container | None (bwrap) | None (bwrap) | None (Landlock) | Container → microVM | Docker container |
| **Linux primitive** | seccomp + AppArmor + `cap-drop=ALL` | bwrap + Landlock + seccomp (27 calls) | bwrap + seccomp (AF_UNIX, io_uring) | Landlock + seccomp + opt. bwrap | runc / gVisor / Kata / Firecracker | `cap-drop=ALL` + 6 back |
| **macOS** | ✅ in-container FUSE | Seatbelt | Seatbelt | Seatbelt | Seatbelt / Apple Container / Tart | Docker only |
| **Windows** | ❌ | WSL | Alpha (native) | ❌ | WSL2 | ❌ |
| **`no-new-privileges`** | ✅ | n/a | n/a | n/a | ❓ | Sidecars only |
| **VM-class option** | ❌ | ❌ (explicit non-goal) | ❌ | ❌ | ✅ Kata + Firecracker | ❌ |

### Filesystem and secrets

| | `kib` | fence | sandbox-runtime | cplt | yoloAI | aicontainer |
|---|---|---|---|---|---|---|
| **Project secrets** | Stub on read (FUSE) | `/dev/null` mask — but `.env` is `denyWrite`, **not** `denyRead`, in the shipped template | Sentinel-substituted fake file (**Linux only**; macOS degrades to deny) | Deny read — **macOS kernel-enforced only** | Never copied in (honours `.gitignore`) | File is present; blocked at the tool layer by a `PreToolUse` hook |
| **Content masking, not just denial** | ✅ | Partial (empties) | ✅ | ❌ | ❌ | Host config JSON only |
| **Covers files created after launch** | ✅ | ✅ | ❌ **Linux: existing files only** | ❌ | ✅ | ✅ |
| **Reads default to** | Allow | Allow | **Allow** | Deny for listed paths | n/a (copy) | Allow |

### Host-executed config

| | `kib` | fence | sandbox-runtime | cplt | yoloAI | aicontainer |
|---|---|---|---|---|---|---|
| **`.git/config`** | Validate content | Block (opt-out) | Block | macOS block / **Linux writable** | Neutralize at call site | Block (`:ro` mount) |
| **`.git/hooks`** | ✅ | ✅ | ✅ | macOS ✅ / Linux bwrap-only | Neutralized | ✅ |
| **Non-`.git` git dirs** | ✅ structural | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Submodule / worktree git dirs** | ✅ | ❌ | ❌ | ❌ documented residual | ❌ | ❌ |
| **`include` / `includeIf`** | ✅ refused | ❌ | ❌ | ❌ | ❌ | ✅ excluded from seeding |
| **`.vscode/` `.idea/`** | ✅ | ✅ | ✅ | ❌ **explicit non-goal** | ❌ | ❌ writable |
| **`.envrc` / direnv** | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **`.devcontainer/`** | ✅ | ❌ | ❌ | ❌ | ✅ sanitized | ✅ + host-side validation |
| **Agent settings (`hooks[].command`)** | ✅ host-side validator | Partial (`.claude/commands`, `agents`) | ✅ dir list | macOS partial; `settings.json` writable by design | ❌ | ✅ root-managed |

### Credentials and operations

| | `kib` | fence | sandbox-runtime | cplt | yoloAI | aicontainer |
|---|---|---|---|---|---|---|
| **Account credential** | ✅ brokered (default on) | ❌ | ✅ sentinel + TLS termination | ❌ exposed | ✅ brokered | ❌ shared volume |
| **Third-party MCP credential** | ✅ header-injected / hosted sidecar | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Model** | Long-lived container per project | Per-invocation | Per-invocation | Per-invocation | Named sandbox per task | Per-project Compose stack |
| **Concurrent sessions** | ✅ `flock` refcount | n/a | n/a | n/a | ✅ (plan doc contradicts) | Implicit via Compose |
| **Security regression suite** | ✅ 11 sections, run in both redaction modes | ✅ Go + `smoke_test.sh` | ✅ ~40 files, no declared policy | ✅ 4 tiers — **kernel tests macOS-only** | Targeted tests, no named suite | ✅ ~60 cases, host-side only |
| **Published CVE** | — | None | **CVE-2025-66479** | None | None | None |

---

## Each project in a line

- **[sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime)** — 4,733★, 31 contributors. The only multi-maintainer project here and the most capable on egress; also the only one with a published CVE (**CVE-2025-66479**, a fail-open where an empty allowlist meant *allow all*; a SOCKS5 null-byte hostname bypass was patched silently). Its Linux caveat — deny paths cover only files that already exist — is the sharpest limitation in this comparison.
- **[fence](https://github.com/fencesandbox/fence)** — 864★, Go, effectively single-author. The best-documented threat model here and honest about scope: *"not designed to be a strong isolation boundary against actively malicious code."* Its shipped `code` template leaves `.env` `denyWrite` but readable, and puts `~/.claude*` in `allowWrite`.
- **[cplt](https://github.com/navikt/cplt)** — 98★, Rust, public-sector. The most candid SECURITY.md in the set; it documents eight of its own bypasses. **Critical for any Linux comparison:** its "🔒 Kernel-blocked" rows are macOS-only — Landlock cannot deny a subpath inside an allowed directory.
- **[yoloAI](https://github.com/kstenerud/yoloai)** — 170★, Go. The widest isolation range (runc → gVisor → Kata → Firecracker) and a broker on by default. Its design docs are a working audit trail, including a confirmed escape of its own network isolation and a host-RCE via agent-controlled `.git/config` filter drivers — but `docs/contributors/design/` mixes proposals with shipped behaviour.
- **[aicontainer](https://github.com/stefanoginella/aicontainer)** — 16★, Shell. Its digest-pinned Docker socket proxy (agent gets `ping` and `version`) is a control nobody else here has. Acknowledged hole: VS Code runs a repo's `devcontainer.json` `initializeCommand` on the host before `aic` can validate anything.

## What the field agrees on

1. **Nobody claims to contain hostile code.** fence: *"assume determined attackers may escape via kernel/OS vulnerabilities."* Claude Code's own docs: *"Sandboxing reduces risk but is not a complete isolation boundary."*
2. **Domain allowlists are not exfiltration controls.** Every project that ships one says so unprompted.
3. **DNS is out of scope everywhere** — the LLM channel is a higher-bandwidth exfil path that must stay open regardless.
4. **Almost nobody has more than one maintainer.** Five of six — including `kib` — are effectively single-author.

## Where this leaves `kib`

**Keep:** FUSE, which is what makes stub-on-read and after-launch coverage possible. The `.git/config` validator. The clipboard read/write split. The broker. A regression suite that re-tests the *legitimate* operation alongside the attack.

**Worth stealing:** sandbox-runtime's structured `extract` masking — regex out just the credential span so a JSON file still parses.

**Still open:** an opt-in default-deny egress mode. Not as the default, but cplt, yoloAI and aicontainer show the shape of an opt-in that costs nothing when off.

---

<details>
<summary><b>Method and limitations</b></summary>

Five independent research passes, one per project, each quoting verbatim from primary sources and writing "NOT DOCUMENTED" rather than inferring. Sources: READMEs, SECURITY.md files, `docs/` trees, and — where a claim mattered — source files (`dangerous.go`, `sandbox-utils.ts`, `post-create.py`, `runtime.go`). Health from the GitHub REST API.

**Symbols.** ✅ documented present · ❌ documented absent, or verified absent from the source the docs designate · ❓ the docs don't say. ❓ is not a synonym for ❌.

1. **Documentation is not code.** A project may implement a control it never wrote down; that lands here as ❌ or ❓ and is unfair to it.
2. **`kib`'s column comes from its own repo**, with full source access — an asymmetry favouring `kib` wherever another project's mechanism exists but is undocumented.
3. **Version skew.** All five are under active development.
4. **Two projects contradict themselves** — cplt on `.env` write-blocking, yoloAI on which agents are brokered — flagged inline rather than resolved.
5. **`kib` is not published.** No stars, no external contributors, no third-party review.

</details>

<details>
<summary><b>Sources</b></summary>

- fence — [README](https://github.com/fencesandbox/fence), [security-model.md](https://github.com/fencesandbox/fence/blob/main/docs/security-model.md), [linux-security-features.md](https://github.com/fencesandbox/fence/blob/main/docs/linux-security-features.md), [dangerous.go](https://github.com/fencesandbox/fence/blob/main/internal/sandbox/dangerous.go)
- sandbox-runtime — [README](https://github.com/anthropic-experimental/sandbox-runtime), [GHSA-9gqj-5w7c-vx47](https://github.com/anthropic-experimental/sandbox-runtime/security/advisories/GHSA-9gqj-5w7c-vx47), [Claude Code sandboxing docs](https://code.claude.com/docs/en/sandboxing)
- cplt — [SECURITY.md](https://github.com/navikt/cplt/blob/main/SECURITY.md), [README](https://github.com/navikt/cplt), [known-impacts.md](https://github.com/navikt/cplt/blob/main/docs/known-impacts.md)
- yoloAI — [README](https://github.com/kstenerud/yoloai), [GUIDE.md](https://github.com/kstenerud/yoloai/blob/main/docs/GUIDE.md), [findings-unresolved.md](https://github.com/kstenerud/yoloai/blob/main/docs/contributors/design/findings-unresolved.md)
- aicontainer — [README](https://github.com/stefanoginella/aicontainer), [CHANGELOG.md](https://github.com/stefanoginella/aicontainer/blob/main/CHANGELOG.md), [post-create.py](https://github.com/stefanoginella/aicontainer/blob/main/template/post-create.py)
- `kib` — this repository: `CLAUDE.md`, `bin/kib`, the `host/` units, `kib/guest/fuse.py`, `kib/guest/wayland_guard.py`, `kib/broker/`, `tests/security-test.sh`

</details>
