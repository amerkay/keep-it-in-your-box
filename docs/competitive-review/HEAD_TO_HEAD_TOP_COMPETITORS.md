<img src="../assets/sandbox-comparison/head-to-head-hero.svg" alt="Head to head — kib measured against seven agent sandboxes. Of those seven, none content-validate .git/config, none mediate the clipboard read versus write, five put the host home directory out of reach by default, two default-deny egress, and two broker credentials." width="100%">

# Eight sandboxes, side by side

The seven most credible agent sandboxes, measured against `kib` on the controls that decide whether an untrusted repo can reach the host. The original five were verified 2026-07-22; `agent-safehouse` and `claude-code-devcontainer` were added 2026-07-26 from their docs only — a shallower pass, flagged in *Method*. `kib`'s column reflects the current tree.

| | |
|---|---|
| **[fence](https://github.com/fencesandbox/fence)** | Container-free. bubblewrap + Landlock + seccomp on Linux, Seatbelt on macOS. 864★, 15 contributors. |
| **[sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime)** | Anthropic's own. bubblewrap + Seatbelt, the engine behind Claude Code's `/sandbox`. 4,733★, 31 contributors. |
| **[cplt](https://github.com/navikt/cplt)** | Landlock-first, from the Norwegian Labour and Welfare Directorate. 98★, 10 contributors. |
| **[yoloAI](https://github.com/kstenerud/yoloai)** | Six backends, up to Firecracker microVMs. Brokers credentials. 170★, 3 contributors. |
| **[aicontainer](https://github.com/stefanoginella/aicontainer)** | Devcontainer + Docker socket proxy, multi-project. 16★, 2 contributors. |
| **[agent-safehouse](https://github.com/eugene1g/agent-safehouse)** | The most popular macOS Seatbelt sandbox. Deny-all baseline, profile-composed. 1,927★, 16 contributors. |
| **[claude-code-devcontainer](https://github.com/trailofbits/claude-code-devcontainer)** | Trail of Bits' devcontainer + the `devc` CLI. 896★, 10 contributors. |
| **`kib`** | *This repo.* One Docker container per project, FUSE redaction sidecar, clipboard proxy, credential broker. |

---

## The verdict

**No single control separates `kib` from this field. The intersection does.**

Five of the seven put the host `$HOME` out of reach — that is table stakes here, not a `kib` feature. Two guard host-executed config as thoroughly as they confine the filesystem. **None does both *and* covers files that do not exist yet.** That last clause is where `kib` is actually alone:

| To be safe, a sandbox must… | Who does it |
|---|---|
| Keep the host `$HOME` unreachable by default | `kib`, cplt\*, yoloAI, aicontainer, agent-safehouse, claude-code-devcontainer *(6 of 8)* |
| **Refuse writes** to the in-repo files the **host** executes later | `kib`, fence, sandbox-runtime, cplt *(macOS only)*, aicontainer *(5 of 8)* — yoloAI neutralizes at the call site instead of refusing |
| Cover config paths that **do not exist yet** | `kib` (FUSE sees `create()`), fence (path rules) — sandbox-runtime and cplt document the opposite, and a `:ro` bind is launch-time by construction *(2 of 8 documented)* |
| Cover the **whole** host-executed set — git in any layout, submodules, worktrees, `include`s, plus `.vscode/`, `.idea/`, `.envrc`, `.devcontainer/` | **`kib` alone** |
| All four | **`kib` alone** |

\* cplt's confinement is deny-by-default with a home-shaped allowlist (`~/.cargo`, `~/.m2`, `~/.gradle` read-write) — closer than anyone else in its class, not working-directory-only.

It is also the only one that reads the bytes of a host-executed config file before deciding, and the only one that mediates the clipboard rather than granting or withholding it wholesale. It is one of three that brokers the account credential, and one of three with no egress restriction at all — the single column it concedes.

Where a project's docs are silent, this says so rather than guessing. Several of the sharpest findings are things a project documents *against itself*.

---

## The control that gates every other one: can the agent read `$HOME`?

A guard on `.git/config` and a stub over `.env` buy nothing while `~/.aws/credentials` and every unrelated repo are one `cat` away. This is the first question to ask of any of these tools, and the field splits on it by primitive.

| Project | Host `$HOME` by default | What the docs say |
|---|---|---|
| `kib` | ✅ **Unreachable** | Only `$PWD` (through the FUSE view) plus two slices of `~/.claude`: shared assets `:ro`, and `projects/<slug>` rw for `--resume` parity. No `~/.ssh`, `~/.aws`, `~/.gnupg`, no SSH-agent socket, not even `~/.gitconfig` — git identity travels as `GIT_AUTHOR_*` env. |
| aicontainer | ✅ Unreachable | *"Host home, `~/.ssh`, SSH-agent socket — **No** — not mounted, not forwarded."* `/workspace` is *"the one writable host path."* |
| agent-safehouse | ✅ Unreachable | *"Start from deny-all."* Concretely: *"`stat "$HOME"` can succeed while `ls "$HOME"` and `cat ~/secret.txt` still fail unless a more specific rule grants that path."* |
| claude-code-devcontainer | ✅ Unreachable | *"Sandboxed: Filesystem (host files inaccessible)"*, *"the blast radius is limited to `/workspace`"*, and it warns *"Avoid mounting large host directories (e.g., `$HOME`)."* Only `~/.gitconfig` and `.devcontainer/` come in, both `:ro`. |
| yoloAI | ✅ Unreachable | Workdir is an *"isolated copy"* honouring `.gitignore`; *"Refuses to mount `$HOME`, `/`, or system directories"* (with a `:force` override). Aux dirs are opt-in `-d` and *"read-only by default."* |
| cplt | ✅ Mostly | *"deny-by-default filesystem with kernel enforcement"* — but the allowlist is home-shaped: read-write to `~/.cargo`, `~/.m2`, `~/.gradle`, `~/.sdkman`; read to `~/.gitconfig` and two `gh` files. Not working-directory-only. |
| fence | ⚠️ Opt-in | *"Writes are denied by default"* — reads are not. *"`denyRead` can block reads from sensitive paths"* is the mechanism, and it is something you configure. |
| sandbox-runtime | ❌ Readable | *"By default, read access is allowed everywhere."* Workspace-only is a documented **recipe** (`denyRead: ["/Users"]` + `allowRead: ["."]`), not the default — and even then *"System paths (`/usr`, `/lib`, etc.) remain readable."* |

The two that leave `$HOME` readable are both OS sandboxes, where the agent runs as *you* and every path the profile does not name stays readable. But `cplt`, `agent-safehouse` and `sandbox-shell` (in the wider survey) prove that is a **choice, not a limit of the primitive**.

`kib`'s advantage here is structural rather than clever: a bind mount only shows what you name, so the confinement cannot drift as new secret-bearing paths appear in `$HOME`. A deny-list has to be kept current; an allowlist of one directory does not.

---

## Where `kib` stands alone

### 1. It validates `.git/config` instead of blocking it

<img src="../assets/sandbox-comparison/gitconfig-strategies.svg" alt="Four strategies for the .git/config problem: kib validates content, fence and sandbox-runtime and aicontainer and cplt-on-macOS block all writes, yoloAI neutralizes git invocations, cplt on Linux leaves it writable." width="100%">

`.git/config` is the sharpest instance of the general problem: a file the sandbox can write, that the *host* executes later, unsandboxed. `core.hooksPath`, `core.fsmonitor`, `core.sshCommand`, `core.pager`, `alias.*` and `filter.*.clean` all name commands git will run.

| Strategy | Projects | What it costs |
|---|---|---|
| **Validate** — read the file on `rename()`, diff against current, refuse only newly-added command-bearing keys | `kib` | Nothing. `git remote add` and `push -u` keep working. |
| **Block** — deny all writes | fence, sandbox-runtime, aicontainer, cplt *(macOS)* | `git remote add` fails inside the sandbox. fence ships an `allowGitConfig` escape hatch that turns the protection off entirely. |
| **Neutralize** — leave the file writable, harden every git invocation | yoloAI | Covers `hooksPath` and `fsmonitor`. Attribute-bound `filter.*` and `diff.*.textconv` drivers must still run for diff correctness — a documented residual. |
| **Leave open** — writable by design, or undocumented | cplt *(Linux)*, agent-safehouse, claude-code-devcontainer | cplt's own SECURITY.md concedes an agent *"can still set `core.hooksPath` to redirect hooks into a writable directory"*. The other two document **no** in-repo protected-path list at all — `agent-safehouse` offers `--append-profile` so you can write your own denials, and Trail of Bits protects only `.devcontainer/`. |

Two structural gaps nobody else covers:

- **A git dir does not have to be called `.git`.** `git init --bare`, `--separate-git-dir`, and a `.git` gitfile holding `gitdir: ../store` all put config and hooks elsewhere. `kib` recognises one by layout (`HEAD` + `objects` + `refs`). fence walks for directories *named* `.git` to depth 3; sandbox-runtime scans with ripgrep to depth 3; neither documents the alternate layouts. The two new entries document no git-dir handling at all.
- **`include` / `includeIf` indirection.** An included file can declare `core.hooksPath` that a validator inspecting only the main file never sees. `kib` refuses newly-added includes. Moot for the four that block writes outright; not moot for cplt on Linux.

One gap `kib` does *not* have, worth naming because it is severe and self-documented:

> "On Linux, mandatory deny paths only block files that **already exist**. Non-existent files in these patterns cannot be blocked by bubblewrap's bind-mount approach."
> — sandbox-runtime README

A bind mount cannot cover a file that isn't there yet. cplt hits the same wall (`.cplt.toml` "can still be created"), and by the same mechanical argument so does any project that protects a path with a `:ro` mount — `aicontainer`'s `.git/config` and `.git/hooks` guards are launch-time binds, so a repo cloned mid-session has no guard. *(That last point is inferred from the mechanism; aicontainer neither claims mid-session coverage nor documents its absence.)* This is the specific reason `kib` uses FUSE: a FUSE filesystem sees the `create()` call. Its guard rules are tail-matched, so `.git/config` also covers `sub/.git/config`, `.git/modules/<name>/config` and `.git/worktrees/<name>/config`, in repos that did not exist at launch.

### 2. It mediates the clipboard rather than granting it

| Project | Clipboard |
|---|---|
| `kib` | A proxy sidecar holds the only real socket. **Reads pass, writes sanitised in flight** across every Wayland clipboard protocol family the tooling can bind (`wl_data_device{_manager}`, `zwp_primary_selection_*`, `zwlr_data_control_*`, `ext_data_control_*`, `gtk_primary_selection_*`, drag included), and an unrecognised selection interface is refused at `bind` rather than passed through; denials close the connection and raise a desktop notification. macOS runs the same filter at its `pbpaste` spool before the one `pbcopy` call. |
| cplt | `--deny-clipboard` on macOS — all-or-nothing, and **reachable by default** (it rides the blanket `mach-lookup` Node.js needs). Listed under "Out of scope". |
| agent-safehouse | Clipboard entries appear in its policy tests, but as a **block**. Its README documents no clipboard behaviour. |
| fence · sandbox-runtime · claude-code-devcontainer | Not documented. |
| yoloAI | Nothing bridged. Terminal escape sequences over `attach` are explicit pass-through. |
| aicontainer | *"Clipboard / browser — **No** — nothing bridged."* |

The read/write asymmetry is the whole point. A clipboard *write* is host code execution at the user's next terminal paste — an embedded `ESC[201~` ends bracketed paste early and the rest is interpreted as typed input. A *read* is just a paste. Most of the field sidesteps this by having no display access at all; cplt has access and offers an on/off switch.

### 3. The enforcement privilege lives outside the agent's container

Newer than the rest of this document, and unique here: `kib` runs the FUSE server in its **own** sidecar container. Only that sidecar holds `SYS_ADMIN`, `/dev/fuse` and an AppArmor override; the agent's container is **capless at creation** — `cap-drop=ALL`, `no-new-privileges`, and `docker-default`'s `deny mount,` still intact — and consumes the redacted view as a propagated `:rslave` mount over `$PWD`. There is no second, unredacted path to the project.

Every other container project in this set gives the agent's own container whatever privilege its enforcement needs, or has no in-container enforcement to privilege. The distinction matters because a capless-at-creation container is a kernel fact at `docker run` time, not a state some startup script dropped into.

---

## Where `kib` is behind: egress

| Project | Default | Mechanism |
|---|---|---|
| sandbox-runtime | **Default-deny** | Network namespace removed entirely; all traffic via host proxies on Unix sockets. Optional TLS termination. |
| fence | **Default-deny** | netns / Seatbelt + HTTP and SOCKS5 proxies with `HTTP_PROXY` injection. |
| aicontainer | Open, with always-on metadata/link-local drops | Opt-in iptables allowlist (`sudo aic-firewall enable`). |
| yoloAI | Open | Opt-in `--network-isolated` (iptables + ipset). |
| cplt | Open on 443 + allow-all proxy with a blocklist | Domain allowlist opt-in; proxy-forced mode opt-in. |
| claude-code-devcontainer | Open | *"By default, containers have full outbound network access."* A manual iptables example, which *"Blocks package managers unless you allowlist registries"*. |
| agent-safehouse | Open | *"open by default."* |
| `kib` | **Open** | None. Documented accepted risk. |

Only two of seven ship default-deny, and note how thin the others' protection is even when enabled — and how candid they are:

- **cplt**: *"**By default the proxy is not mandatory** — because `*:443` is kernel-allowed, a raw socket or `env -u HTTPS_PROXY` can reach the network without traversing the proxy."*
- **yoloAI** shipped an in-container firewall the agent could flush, with the empirical proof in its own docs (`sudo iptables -F OUTPUT`, then a successful `curl`). Fixed for Docker by moving enforcement into a sidecar netns. Still IPv4-only — filed as DF104, "PARKED".
- **fence**: *"domain filtering does not inspect content. If you allow a domain, code can exfiltrate via that domain."*

`kib`'s position — a default-deny allowlist conflicts with building untrusted repos that fetch from arbitrary registries — is a real trade-off, not an oversight. It is still the minority position, and unlike cplt or yoloAI there is no opt-in mode to reach for. The proxy-sidecar design is worked out and deliberately unscheduled — kib shipped the credential broker instead, on the reasoning that removing the thing worth stealing beats fencing a channel that cannot be closed ([`credential-broker.md`](../design-notes/credential-broker.md)).

---

## Credentials: `kib` is one of three

`kib` brokers by default, for every provider in its registry rather than for Claude alone — the same path serves `ANTHROPIC_BASE_URL`, `OPENAI_BASE_URL` and `GOOGLE_GEMINI_BASE_URL`, which is exactly the gap yoloAI's own findings file records against itself. A host-side sidecar holds a static token from `kib broker login`; the container gets the provider's base-URL env pointed at the broker, a placeholder token (`CLAUDE_CODE_OAUTH_TOKEN` for Claude), and a synthetic `.credentials.json` shadowing the real file. The broker re-originates TLS upstream, so there is no CA in the container. Two caveats: a launch with **no stored token and no interactive login** falls back to mounting the real credential with a warning, and `broker = off` / `KIB_BROKER=0` restores the old exposure by choice.

Two others do the same, by the same trick:

> "Instead of placing the credential in the container, it runs a tiny per-sandbox proxy on the host (the *broker*), points the agent at it with a harmless placeholder token, and swaps in the real credential on the way to the provider." — yoloAI

> "A masked credential's real value is replaced inside the sandbox with a sentinel of the form `fake_value_<uuid4>`. The sandboxed process sees only the sentinel; the host-side proxy substitutes sentinel→real on egress." — sandbox-runtime

Caveats from their own docs: sandbox-runtime's masking **requires TLS termination** and fails closed to a broken login otherwise; yoloAI's unresolved-findings file says its broker is *"only wired for the Claude agent"* while its guide claims three.

The other five are exposed, in ascending order of how much:

- **cplt**: *"the OAuth token lives in `~/.claude/.credentials.json`… **exposed to the sandbox**… an inherent trade-off."*
- **agent-safehouse**: deny-first, and `~/.ssh` is not granted — but the agent credential itself is not brokered.
- **aicontainer**: tokens live in one volume shared across every project — *"a compromised session in **any** project can use every token you've logged in with."*
- **fence**: no brokering; its shipped `code` template puts `~/.claude*` in `allowWrite`.
- **claude-code-devcontainer**: the token is forwarded in as `CLAUDE_CODE_OAUTH_TOKEN` — *"The token is forwarded into the container"* — **and the SSH agent socket comes with it**: *"the devcontainer runtime automatically forwards your host's SSH agent socket (`SSH_AUTH_SOCK`) into the container… This lets code inside the container authenticate as you over SSH."* Keys stay on the host; the *authority* does not.

`kib` extends the same broker past the LLM token — remote MCP credentials are injected as a header the container never sees (`reverse_proxy_mcp`), client-signed creds run in their own `cap-drop=ALL` sidecar (`hosted_mcp`), and `claude mcp add … --header …` is intercepted **host-side** so a vendor's copy-pasted line cannot put a secret in the container's argv. No other project here documents an equivalent.

---

## The full matrix

### Isolation and platform

| | `kib` | fence | sandbox-runtime | cplt | yoloAI | aicontainer | agent-safehouse | cc-devcontainer |
|---|---|---|---|---|---|---|---|---|
| **Boundary** | Docker container | None (bwrap) | None (bwrap) | None (Landlock) | Container → microVM | Docker container | None (Seatbelt) | Docker container |
| **Linux primitive** | seccomp + AppArmor + `cap-drop=ALL` | bwrap + Landlock + seccomp (27 calls) | bwrap + seccomp (AF_UNIX, io_uring) | Landlock + seccomp + opt. bwrap | runc / gVisor / Kata / Firecracker | `cap-drop=ALL` + 6 back | n/a — macOS only | devcontainer defaults |
| **macOS** | ✅ same sidecar topology; only the propagation root differs | Seatbelt | Seatbelt | Seatbelt | Seatbelt / Apple Container / Tart | Docker only | ✅ native | Docker only |
| **Windows** | ❌ | WSL | Alpha (native) | ❌ | WSL2 | ❌ | ❌ | ❓ |
| **`no-new-privileges`** | ✅ | n/a | n/a | n/a | ❓ | Sidecars only | n/a | ❓ |
| **Agent container capless at creation** | ✅ enforcement privilege is in a separate sidecar | n/a | n/a | n/a | ❓ | ❌ 6 caps added back | n/a | ❌ `vscode` has passwordless sudo |
| **VM-class option** | ❌ | ❌ (explicit non-goal) | ❌ | ❌ | ✅ Kata + Firecracker | ❌ | ❌ | ❌ |

### Filesystem and secrets

| | `kib` | fence | sandbox-runtime | cplt | yoloAI | aicontainer | agent-safehouse | cc-devcontainer |
|---|---|---|---|---|---|---|---|---|
| **Host `$HOME` out of reach** | ✅ | ⚠️ opt-in `denyRead` | ❌ reads open | ✅ mostly (home allowlist) | ✅ | ✅ | ✅ | ✅ |
| **Project secrets** | Stub on read (FUSE) | `/dev/null` mask — but `.env` is `denyWrite`, **not** `denyRead`, in the shipped template | Sentinel-substituted fake file (**Linux only**; macOS degrades to deny) | Deny read — **macOS kernel-enforced only** | Never copied in (honours `.gitignore`) | File is present; blocked at the tool layer by a `PreToolUse` hook | ❓ not documented | ❌ |
| **Content masking, not just denial** | ✅ | Partial (empties) | ✅ | ❌ | ❌ | Host config JSON only | ❌ | ❌ |
| **Covers files created after launch** | ✅ FUSE sees `create()` | ✅ | ❌ **Linux: existing files only** | ❌ Linux (Landlock is allowlist-only); macOS path rules probably do, undocumented | ✅ (copy) | ⚠️ `:ro` binds are launch-time by construction — inferred from the mechanism, not a documented claim | ❓ | n/a — no in-repo guard to extend |
| **Reads default to** | Allow *inside the project only* | Allow | **Allow** | Deny for listed paths | n/a (copy) | Allow | **Deny** | Allow (in-container) |

### Host-executed config

| | `kib` | fence | sandbox-runtime | cplt | yoloAI | aicontainer | agent-safehouse | cc-devcontainer |
|---|---|---|---|---|---|---|---|---|
| **`.git/config`** | Validate content | Block (opt-out) | Block | macOS block / **Linux writable** | Neutralize at call site | Block (`:ro` mount) | ❌ none documented | ❌ none documented |
| **`.git/hooks`** | ✅ | ✅ | ✅ | macOS ✅ / Linux bwrap-only | Neutralized | ✅ | ❌ | ❌ |
| **Non-`.git` git dirs** | ✅ structural (`HEAD`+`objects`+`refs`) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Submodule / worktree git dirs** | ✅ `.git/modules/`, `.git/worktrees/` | ❌ | ❌ | ❌ documented residual | ❌ | ❌ | ❌ | ❌ |
| **`include` / `includeIf`** | ✅ refused | ❌ | ❌ | ❌ | ❌ | ✅ excluded from seeding | ❌ | ❌ |
| **`.vscode/` `.idea/`** | ✅ | ✅ | ✅ | ❌ **explicit non-goal** | ❌ | ❌ writable | ❌ | ❌ |
| **`.envrc` / direnv** | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **`.devcontainer/`** | ✅ | ❌ | ❌ | ❌ | ✅ sanitized | ✅ + host-side validation | ❌ | ⚠️ `:ro` mount only |
| **Shell rc files** | n/a — not mounted | ✅ mandatory, unoverridable | ✅ | ✅ | ❓ | ✅ root-managed profiles | ❓ | ❓ |
| **Agent settings (`hooks[].command`)** | ✅ host-side validator | Partial (`.claude/commands`, `agents`) | ✅ dir list | macOS partial; `settings.json` writable by design | ❌ | ✅ root-managed | ❓ | ❌ `~/.claude` volume is rw |
| **Immune to project override** | ✅ guard rules ignore `!` negation | ✅ *"Even if your config says `allowWrite: ["/"]`"* | ✅ mandatory list | ❓ | n/a | ✅ root-owned | n/a — user profiles compose | n/a |

### Credentials and operations

| | `kib` | fence | sandbox-runtime | cplt | yoloAI | aicontainer | agent-safehouse | cc-devcontainer |
|---|---|---|---|---|---|---|---|---|
| **Account credential** | ✅ brokered (default on) | ❌ | ✅ sentinel + TLS termination | ❌ exposed | ✅ brokered | ❌ shared volume | ❌ not brokered | ❌ env-forwarded token |
| **SSH agent** | ❌ never forwarded | ❓ | ❓ | ❓ | ❓ | ❌ never forwarded | Not granted | ⚠️ **forwarded by default** |
| **Third-party MCP credential** | ✅ header-injected / hosted sidecar | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Model** | Long-lived container per project | Per-invocation | Per-invocation | Per-invocation | Named sandbox per task | Per-project Compose stack | Per-invocation | Per-project container |
| **Concurrent sessions** | ✅ `flock` refcount, N terminals per container | n/a | n/a | n/a | ✅ (plan doc contradicts) | Implicit via Compose | n/a | ❓ two documented topologies, concurrency unstated |
| **Security regression suite** | ✅ 11 sections (`tests/security-test.sh`) | ✅ Go + `smoke_test.sh` | ✅ ~40 files, no declared policy | ✅ 4 tiers — **kernel tests macOS-only** | Targeted tests, no named suite | ✅ ~60 cases, host-side only | ✅ `tests/policy/**/*.bats` + CI | ❌ none documented |
| **Published CVE** | — | None | **CVE-2025-66479** | None | None | None | None | None |

---

## Each project in a line

- **[sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime)** — 4,733★, 31 contributors. The only genuinely multi-maintainer project here and the most capable on egress; also the only one with a published CVE (**CVE-2025-66479**, a fail-open where an empty allowlist meant *allow all*; a SOCKS5 null-byte hostname bypass was patched silently). Its mandatory deny-write list is the most complete enumeration of host-executed config paths in the field. Its Linux caveat — deny paths cover only files that already exist — is the sharpest limitation in this comparison, and its reads-open default is the second.
- **[agent-safehouse](https://github.com/eugene1g/agent-safehouse)** — 1,927★, 16 contributors. The best-documented `$HOME` confinement of any OS sandbox, and the healthiest macOS-native option. Its blind spot is the exact inverse of its strength: a deny-all *read* baseline with **no documented protected-path list inside the workdir**, so `.git/hooks` and `.vscode/tasks.json` are the user's own problem via `--append-profile`. Honest about scope — *"a hardening layer, not a perfect security boundary against a determined attacker."*
- **[claude-code-devcontainer](https://github.com/trailofbits/claude-code-devcontainer)** — 896★, 10 contributors. Credible authors, and the confinement claim is unambiguous (*"host files inaccessible"*). Then it forwards the SSH agent in by default, ships full outbound egress, protects only `.devcontainer/`, gives the container user passwordless sudo, and documents no tests. Strong on the boundary, thin on everything the boundary is supposed to protect.
- **[fence](https://github.com/fencesandbox/fence)** — 864★, 15 contributors, Go. The best-documented threat model here, and the **strongest guarantee shape** in the set: *"Even if your config says `allowWrite: ["/"]`, the mandatory paths above stay read-only."* Offset by `allowGitConfig`, which turns `.git/config` protection off entirely, and by reads that are not confined by default.
- **[cplt](https://github.com/navikt/cplt)** — 98★, 10 contributors, Rust, public-sector. The most candid SECURITY.md in the set; it documents eight of its own bypasses. The only OS sandbox shipping both confinement *and* a git guard by default. **Critical for any Linux comparison:** its "🔒 Kernel-blocked" rows are macOS-only — Landlock cannot deny a subpath inside an allowed directory. `.vscode` is an explicit non-goal.
- **[yoloAI](https://github.com/kstenerud/yoloai)** — 170★, 3 contributors, Go. The widest isolation range (runc → gVisor → Kata → Firecracker), a broker on by default, and a copy-then-`apply` model that keeps the real repo untouched until a human reviews the diff. Its design docs are a working audit trail, including a confirmed escape of its own network isolation and a host-RCE via agent-controlled `.git/config` filter drivers — but `docs/contributors/design/` mixes proposals with shipped behaviour.
- **[aicontainer](https://github.com/stefanoginella/aicontainer)** — 16★, 2 contributors, Shell. The closest match to `kib`'s thesis in the field, and the only other project treating `.git/config`, `.git/hooks` and cross-project config as first-class. Its digest-pinned Docker socket proxy (agent gets `ping` and `version`) is a control nobody else here has. Two acknowledged holes: VS Code runs a repo's `devcontainer.json` `initializeCommand` on the host before `aic` can validate anything, and its `:ro` guards cannot cover a repo cloned mid-session.

---

## If you had to hand one to someone else

Scoped narrowly: **macOS, auto mode, a non-technical operator, no `$HOME` access, safety against host-executed config RCE, egress explicitly not a criterion.** Ratings are for *that* brief only — they are not overall quality scores.

| | Rating | Why |
|---|---|---|
| **aicontainer** | ★★★★☆ | The only one that meets both hard requirements with **no configuration**. Confinement is structural; `.git/config`, `.git/hooks` and `.devcontainer/` are `:ro`. Cons: `.vscode/` unprotected (add it), `:ro` guards miss mid-session clones, and 16★/2 contributors is a real bus factor. |
| **sandbox-runtime** | ★★★★☆ | Fails requirement 1 as shipped, but documents the exact fix (`denyRead: ["/Users"]` + `allowRead: ["."]`) and has the field's most complete host-config deny list, tested. Best maintenance story by an order of magnitude. Cons: confinement lives in a config file that can drift, and system paths stay readable. |
| **yoloAI** | ★★★☆☆ | The copy-then-`apply` model is quietly the best fit for a novice: nothing touches the real repo until a human approves the diff, and `.gitignore`d secrets never enter. Cons: no editor-config guard, `.git/config` left writable by design, and 6 backends is a lot of surface to explain. |
| **fence** | ★★★☆☆ | Strongest *unoverridable* protections for hooks and shell rc. Cons: read confinement is opt-in, `allowGitConfig` is a foot-gun, and the config surface is large for a novice. |
| **cplt** | ★★★☆☆ | The only OS sandbox with both controls on by default, and macOS is its better half. Cons: `.vscode` explicitly allowed — the unpatched `tasks.json` chain, live by design — and `$HOME` is not truly out of reach (`~/.cargo`, `~/.m2`, `~/.gradle` rw). Onboarding assumes a Norwegian public-sector toolchain. |
| **agent-safehouse** | ★★☆☆☆ | Best `$HOME` confinement here and the most popular option, but no documented in-repo protected paths means the agent can write `.git/hooks/post-checkout` and you execute it later. Fails the second requirement. |
| **claude-code-devcontainer** | ★★☆☆☆ | Confines the filesystem, then forwards the SSH agent and guards nothing in-repo. Fails the second requirement, and adds a credential the others do not. |
| **`kib`** | *n/a* | On the brief itself it is the best fit — confinement, the full protected set, content-validated `.git/config`, mid-session coverage. But it is unpublished, unlicensed, single-author, and needs a host terminal, so it is not something a stranger can install. Fine for someone you support personally; not a recommendation. |

Whichever is chosen, two claims are worth verifying empirically rather than trusting: `cat ~/.ssh/id_rsa` must fail, and writes to `.git/hooks/post-commit` and `.vscode/tasks.json` must fail. That is a 30-second test and it is the whole decision.

---

## What the field agrees on

1. **Nobody claims to contain hostile code.** fence: *"assume determined attackers may escape via kernel/OS vulnerabilities."* agent-safehouse: *"a hardening layer, not a perfect security boundary."* Claude Code's own docs: *"Sandboxing reduces risk but is not a complete isolation boundary."*
2. **Domain allowlists are not exfiltration controls.** Every project that ships one says so unprompted.
3. **DNS is out of scope everywhere** — the LLM channel is a higher-bandwidth exfil path that must stay open regardless.
4. **Confinement is settled; host-executed config is not.** Six of eight keep `$HOME` out of reach. Only two guard in-repo host-executed config as thoroughly, and only three cover files that do not exist yet. The industry named this bug class in July 2026; the field has not finished responding to it.
5. **`kib` is the only single-author project in this set.** Widening the comparison from five to seven inverted the old finding: five of the seven have ten or more contributors. Against the long tail of the wider survey `kib` looks normally staffed; against these seven it does not.

---

## Where this leaves `kib`

**Keep:** the FUSE sidecar — it is what makes stub-on-read, after-launch coverage and a capless agent container possible at the same time. The `.git/config` validator. The clipboard read/write split. The broker. Confinement by bind mount rather than by deny-list. A regression suite that re-tests the *legitimate* operation alongside the attack.

**Worth stealing:**
- ~~sandbox-runtime's structured `extract` masking~~ — **taken (2026-07-27)**, as format-aware
  `[redact]`: JSON and `.env*` read as key names with values replaced, everything else keeps the
  stub. Only the masking half; sentinel substitution on egress stays shelved — the base-URL broker
  needs no CA in the container trust store, so a TLS-terminating proxy buys nothing today.
- fence's *unoverridable* framing. `kib`'s guard already ignores `!` negation from a project; saying so as a guarantee, in the docs, is free.
- yoloAI's copy-then-`apply` review gate, as an opt-in mode for genuinely untrusted repos.

**Still open:** an opt-in default-deny egress mode. Not as the default, but cplt, yoloAI and aicontainer show the shape of an opt-in that costs nothing when off.

---

<details>
<summary><b>Method and limitations</b></summary>

Five independent research passes for the original five projects, one each, quoting verbatim from primary sources and writing "NOT DOCUMENTED" rather than inferring. Sources: READMEs, SECURITY.md files, `docs/` trees, and — where a claim mattered — source files (`dangerous.go`, `sandbox-utils.ts`, `post-create.py`, `runtime.go`). Health from the GitHub REST API.

**Symbols.** ✅ documented present · ⚠️ partial, opt-in, or conditional · ❌ documented absent, or verified absent from the source the docs designate · ❓ the docs don't say. ❓ is not a synonym for ❌.

1. **`agent-safehouse` and `claude-code-devcontainer` had a shallower pass** — README and docs-site level, added 2026-07-26, with no source reading. Their ❌ cells for in-repo config protection mean *"no protected-path list appears in the documentation"*, which is weaker than the verified absences recorded for the original five.
2. **Documentation is not code.** A project may implement a control it never wrote down; that lands here as ❌ or ❓ and is unfair to it.
3. **`kib`'s column comes from its own repo**, with full source access — an asymmetry favouring `kib` wherever another project's mechanism exists but is undocumented.
4. **Version skew.** All seven are under active development.
5. **Two projects contradict themselves** — cplt on `.env` write-blocking, yoloAI on which agents are brokered — flagged inline rather than resolved.
6. **`kib` is not published.** No stars, no external contributors, no third-party review.

</details>

<details>
<summary><b>Sources</b></summary>

- fence — [README](https://github.com/fencesandbox/fence), [security-model](https://fencesandbox.com/docs/reference/security-model), [linux-security-features.md](https://github.com/fencesandbox/fence/blob/main/docs/linux-security-features.md), [dangerous.go](https://github.com/fencesandbox/fence/blob/main/internal/sandbox/dangerous.go)
- sandbox-runtime — [README](https://github.com/anthropic-experimental/sandbox-runtime), [GHSA-9gqj-5w7c-vx47](https://github.com/anthropic-experimental/sandbox-runtime/security/advisories/GHSA-9gqj-5w7c-vx47), [Claude Code sandboxing docs](https://code.claude.com/docs/en/sandboxing)
- cplt — [SECURITY.md](https://github.com/navikt/cplt/blob/main/SECURITY.md), [README](https://github.com/navikt/cplt), [known-impacts.md](https://github.com/navikt/cplt/blob/main/docs/known-impacts.md)
- yoloAI — [README](https://github.com/kstenerud/yoloai), [GUIDE.md](https://github.com/kstenerud/yoloai/blob/main/docs/GUIDE.md), [findings-unresolved.md](https://github.com/kstenerud/yoloai/blob/main/docs/contributors/design/findings-unresolved.md)
- aicontainer — [README](https://github.com/stefanoginella/aicontainer), [CHANGELOG.md](https://github.com/stefanoginella/aicontainer/blob/main/CHANGELOG.md), [post-create.py](https://github.com/stefanoginella/aicontainer/blob/main/template/post-create.py)
- agent-safehouse — [README](https://github.com/eugene1g/agent-safehouse) *(docs site not read)*
- claude-code-devcontainer — [README](https://github.com/trailofbits/claude-code-devcontainer)
- `kib` — this repository: `CLAUDE.md`, `bin/kib`, the `host/` units, `guest/policy/global.kibignore`, `kib/guest/fuse.py`, `kib/guest/wayland_guard.py`, `kib/broker/`, `tests/security-test.sh`, `docs/design-notes/platform-matrix.md`

</details>
