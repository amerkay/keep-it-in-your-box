<p align="center">
  <img src="../assets/sandbox-comparison/hero.svg" width="100%"
       alt="Sandbox Comparison — kib measured against 30 open-source agent sandboxes. kib leads on 5 containment controls and is behind on 2. Of the 30 other projects, 0 mediate the clipboard, 3 redact in-project secrets, 4 guard host-executed config, 5 broker credentials, and 10 enforce default-deny egress.">
</p>

A survey of open-source projects that sandbox AI coding agents, compared against this
repository's `kib` on **security and containment**. Field compiled 2026-07-22; `kib`'s own row
reflects the current tree.

**Every cell about another project comes from its own documentation.** Nothing is inferred from a
project's category, and `❓` means *"the docs don't say"* — never *"the project lacks it."*

---

## The finding

`kib` is unusually strong on the threat class the industry only just started naming — files
the agent writes that the **host** executes later — and concedes exactly one control the field
has standardised: **default-deny egress**.

<p align="center">
  <img src="../assets/sandbox-comparison/control-rarity.svg" width="100%"
       alt="Bar chart of how many of 30 surveyed sandboxes implement each control. Clipboard mediation 0 of 30, kib has it. In-project secret redaction 3, kib has it. Host-executed config guard 4, kib has it. Credential brokering 5, kib has it. VM-class boundary 6, kib lacks it. Default-deny egress 10, kib lacks it. Security regression suite 13, kib has it.">
</p>

---

## Where `kib` leads

### 1. Host-executed config guard

[Pillar Security's *The Week of Sandbox Escapes*](https://www.pillar.security/blog/the-week-of-sandbox-escapes)
(2026-07-20) documented seven attack chains in which the agent **stays inside its sandbox** but
writes a file the host later executes — `kib`'s founding thesis, independently confirmed.

| Pillar attack chain | Product | Status | `kib` control |
|---|---|---|---|
| "Git directories do not have to be called `.git`" — fsmonitor indirection | Cursor | patched 3.0.0 | `_is_git_config()` detects a git dir by **layout** (`HEAD`+`objects`+`refs`), never by name |
| "The hook was already in the workspace" — `.claude` hook config | Cursor | CVE-2026-48124 | `validate_shared_settings` refuses inline `hooks[].command` |
| "A time bomb in `.vscode`" — `tasks.json` | Antigravity | **unpatched** | `guest/policy/global.kibignore` `[protect]` — writes refused |
| "One Docker socket to rule them all" | Codex, Cursor, Gemini CLI | GHSA-v4xv-rqh3-w9mc | no socket mounted |
| "GitPwned: allowlist to RCE" | Codex CLI | patched v0.95.0 | n/a — `kib` has no command allowlist to bypass |

Only **4 of 30** projects guard host-executed config at all:
[sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime) (the most complete
path enumeration in the field), [cplt](https://github.com/navikt/cplt),
[agent-seatbelt](https://github.com/CJHwong/agent-seatbelt) and
[aicontainer](https://github.com/stefanoginella/aicontainer).

**None content-validates `.git/config`.** All four deny writes outright, which `kib` rejected
because it breaks `git remote add`. `kib` appears alone in validating at the *rename*, diffing
against the current file, following `include`/`includeIf`, and handling `.git/modules/` and
`.git/worktrees/` structurally.

### 2. In-project secret redaction that survives mid-session file creation

| Project | Mechanism | Enforced below the agent? | On by default? |
|---|---|---|---|
| **`kib`** | FUSE passthrough — stub on read, `EACCES` on write | ✅ | ✅ |
| [cplt](https://github.com/navikt/cplt) | Landlock blocks `.env*`, `.pem`, `.key` | ✅ | ✅ |
| [aicontainer](https://github.com/stefanoginella/aicontainer) | `PreToolUse` hook blocks `.env*` reads | ❌ agent-level | ✅ |
| [yoloai](https://github.com/kstenerud/yoloai) | `:copy` honours `.gitignore` | ✅ by omission | ✅ |
| [fence](https://github.com/fencesandbox/fence) | `denyWrite` only — **still readable** | ✅ | ⚠️ partial |
| [yolobox](https://github.com/finbarr/yolobox) | `--exclude ".env*"` | ✅ | ❌ opt-in |
| [sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime) | `denyRead` config | ✅ | ❌ opt-in |

`kib` and `cplt` are the only two that are kernel/FS-enforced, on by default, **and** cover files
created after launch — which a launch-time bind mask structurally cannot do.

### 3. Clipboard mediation — no other implementation found

**0 of 30.** [agent-safehouse](https://github.com/eugene1g/agent-safehouse) has clipboard entries
in its policy tests, but that is a *block*. `kib`'s proxy passing reads while refusing writes
appears unique. Searches surfaced the underlying attack — bracketed-paste truncation via
`ESC[201~`, pastejacking — but no other agent sandbox mitigating it.

### 4. Credential brokering, extended past the LLM token

**5 of 30** keep the account token host-side. `kib` does too, by default: a sidecar holds a static
token, the container gets `ANTHROPIC_BASE_URL` plus a synthetic placeholder, and the broker
re-originates TLS upstream — no CA in the container. *(Two caveats: a launch with no stored token
and no interactive login falls back to mounting the real credential with a warning, and
`broker = off` restores the old exposure by choice.)*

The extension is the part nothing else in the survey documents: the same broker injects
**third-party MCP credentials** as a header the container never sees, runs client-signed creds in
their own `cap-drop=ALL` sidecar, and intercepts `claude mcp add … --header …` **host-side** so a
vendor's copy-pasted line cannot put a secret in the container's argv.

### 5. Shared agent-config pivot

Nearly every container project mounts `~/.claude`, several read-write, and only `aicontainer`
reasons about one project's session poisoning **every other project's next session**. `kib`'s
read-only asset mounts, per-project assembly and host-side `settings.json` validation are the most
developed treatment found.

---

## Where `kib` is behind

| Gap | The field | `kib` today |
|---|---|---|
| **Egress** | 10 of 30 enforce default-deny | Open — documented accepted risk; no opt-in mode |
| **Kernel boundary** | 6 use a VM/microVM | Shared kernel; Anthropic's own docs call a VM "the strongest separation" |
| **Ephemerality** | `chamber`, `yoloai`, `matchlock`, `cleanroom` reseed per run | Long-lived container by design; `KIB_FORCE_NEW_SESSION=1` is opt-in |

The egress position is defensible and deliberate: a default-deny allowlist conflicts with building
untrusted repos that fetch from arbitrary registries, and an allowlist cannot close
`api.anthropic.com` or the registries — which is where exfil actually happens. `docs/FUTURE_TASKS.md`
(E1) holds the design if that trade ever changes.

---

## The full matrix

**Legend** — ✅ documented and specific · ⚠️ partial, opt-in, or conditional ·
❌ documented as absent, or absent from an explicit enumeration · ❓ not stated in the docs

| Project | Kernel boundary | Egress control | Credential exposure | Host-config guard | In-project redaction | Clipboard | Shared-config guard | Hardening | Docker socket | Multi-session | Security tests | Platforms |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **`kib` (baseline)** | ❌ shared kernel | ❌ **open (accepted risk)** | ✅ **brokered by default — token never in the box** | ✅ **FUSE + structural git detection + content-validated `.git/config`** | ✅ **FUSE stub-on-read, covers mid-session files** | ✅ **proxy, writes refused** | ✅ RO mounts + host-side validator | ✅ cap-drop ALL, no-new-privs, seccomp, AppArmor | ❌ none | ✅ 1 container/project, N terminals | ✅ `security-test.sh`, 11 sections, both redaction modes | Linux, macOS |
| [sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime) | ❌ OS sandbox | ✅ deny-all + allowlist proxy | ⚠️ opt-in `denyRead` | ✅ mandatory deny-write: `.git/config`, `.git/hooks`, `.vscode`, `.idea`, shell rc, `.mcp.json` | ⚠️ opt-in | ❓ | n/a | ✅ seccomp BPF, nested PID ns, WFP fence | n/a | ❓ | ✅ mandatory-deny-paths suite | macOS, Linux, Win (alpha) |
| [microsandbox](https://github.com/superradcompany/microsandbox) | ✅ microVM | ✅ deny-default, DNS+TCP, airgap | ✅ **keys never enter VM** | ❓ | ❓ | ❓ | n/a | ✅ hardware-level VM | ❓ | ⚠️ named sandboxes | ✅ domain/port/secret tests | Linux, macOS, Windows |
| [matchlock](https://github.com/jingkaihe/matchlock) | ✅ microVM | ✅ deny-all, nftables + MITM | ✅ **in-flight injection; VM sees placeholder** | ❓ | ⚠️ VFS hook rules, no default | ❓ | n/a | ✅ VM + gVisor netstack | ❓ | ⚠️ `exec <vm-id>` | ❓ tests exist, not claimed | Linux (KVM), macOS AS |
| [cleanroom](https://github.com/buildkite/cleanroom) | ✅ microVM | ✅ **deny-by-default required** | ✅ host-side mediation gateway | ❓ | ❓ | ❓ | n/a | ✅ fail-closed, policy hash | ❓ | ✅ `fork --count 100` | ❓ | macOS, Linux |
| [cplt](https://github.com/navikt/cplt) | ❌ OS sandbox | ✅ 443-only + CONNECT allowlist | ✅ ssh/aws/gnupg/kube kernel-blocked | ✅ **`.git/hooks`, `.git/config`, `.gitmodules` blocked** (`.vscode` allowed — stated risk) | ✅ **`.env*`, `.pem`, `.key` blocked** | ❓ | n/a | ✅ seccomp denies `unshare`/`setns` | ❓ | ❓ | ✅ `e2e_guards.rs` | macOS, Linux 5.13+ |
| [fence](https://github.com/fencesandbox/fence) | ❌ OS sandbox | ✅ deny-all + allowlist proxy | ✅ denyRead ssh/aws/netrc; strips `LD_*` | ✅ "always-protected targets (shell configs, git hooks)" | ⚠️ **denyWrite only — readable** | ❓ | n/a | ✅ Landlock v4, seccomp, eBPF | ❓ | ❓ | ✅ seccomp + network-policy suite | macOS, Linux, WSL |
| [agent-seatbelt](https://github.com/CJHwong/agent-seatbelt) | ❌ OS sandbox | ❌ **"fully open"** | ✅ broad read-denies | ✅ **write-denies `.git/hooks`, `.git/config`, `.mcp.json`, `.vscode`, shell rc** | ⚠️ `~/.env` only | ❓ | n/a | ✅ Seatbelt + ONNX PII filter (fails open) | n/a | ❓ | ⚠️ PII filter only | macOS |
| [aicontainer](https://github.com/stefanoginella/aicontainer) | ❌ shared kernel | ⚠️ opt-in ipset; always-on metadata drop | ✅ nothing auto-forwarded | ✅ **`.devcontainer/`, `.git/config`, `.git/hooks` RO + sanitizer** | ✅ **hook blocks `.env*` reads** | ❓ | ⚠️ shared auth volume | ✅ cap-drop, no `NET_RAW`, RO rootfs sidecar | ✅ **proxied, digest-pinned** | ✅ one container/project | ✅ `test-aic-host-security.sh` | Docker Desktop/OrbStack/Colima |
| [agent-sandbox](https://github.com/mattolson/agent-sandbox) | ❌ shared kernel | ✅ mitmproxy deny + iptables | ✅ **injected in proxy; agent never sees token** | ❓ | ❌ | ❓ | n/a | ✅ cap_drop ALL, restricted sudoers | ❌ none | ❓ | ✅ proxy-enforcement pytest | Colima/Docker (Apple Silicon) |
| [yoloai](https://github.com/kstenerud/yoloai) | ⚠️ runc→gVisor→Kata | ⚠️ `--network-isolated` / `--none` / open | ✅ **broker: key stays host-side** | ❌ isolated copy; `apply` is the gate | ✅ `:copy` honours `.gitignore` | ❓ | n/a | ✅ non-root, mount refusal | ❓ | ✅ named concurrent sandboxes | ✅ broker/credential tests | Linux, macOS, WSL2 |
| [cco](https://github.com/nikvdp/cco) | ❌ OS sandbox | ❌ **"intentionally unrestricted"** | ✅ keychain extraction, RO mount | ⚠️ `~/.gitconfig`/`~/.ssh` RO; project `.git` ❌ | ❌ **explicitly not covered** | ❓ | n/a | ✅ seccomp blocks TIOCSTI/TIOCLINUX | ⚠️ opt-in ("defeats isolation") | ✅ `--persist` | ✅ sandbox/seccomp/seatbelt | macOS, Linux |
| [agent-safehouse](https://github.com/eugene1g/agent-safehouse) | ❌ OS sandbox | ❌ **"open by default"** | ✅ deny-first; ssh not granted | ❌ workdir rw, no carve-out | ❓ | ⚠️ blocked in tests | n/a | ✅ deny-all start | n/a | ❓ | ✅ `tests/policy/**/*.bats` + CI | macOS |
| [sandbox-shell](https://github.com/agentic-dev3o/sandbox-shell) | ❌ OS sandbox | ✅ blocked by default | ✅ always denies ssh/aws/docker/Documents | ❓ | ❓ | ❓ | n/a | ✅ deny-by-default reads+writes+net | n/a | ❓ | ✅ `test-security.sh` | macOS |
| [agent-seatbelt-sandbox](https://github.com/michaelneale/agent-seatbelt-sandbox) | ❌ OS sandbox | ✅ **kernel blocks all but localhost** | ⚠️ `~/.secrets` only | ❓ | ❓ | ❓ | n/a | ✅ cannot be removed from inside | n/a | ❓ | ✅ `./test.sh`, 9 tests | macOS |
| [claude-code-devcontainer](https://github.com/trailofbits/claude-code-devcontainer) | ❌ shared kernel | ⚠️ manual iptables example | ⚠️ volume; **SSH agent forwarded** | ⚠️ `.devcontainer/` RO only | ❌ | ❓ | ❓ | ❓ | ❌ not mounted | ❓ | ❌ | ❓ |
| [claudebox](https://github.com/RchGrav/claudebox) | ❌ shared kernel | ⚠️ allowlist, mechanism unstated | ⚠️ API key env; `~/.claude` RO | ❌ | ❌ | ❓ | ⚠️ `~/.claude` RO | ❓ | ❓ | ✅ multi-instance | ❌ | Linux, macOS, WSL2 |
| [container-use](https://github.com/dagger/container-use) | ❌ shared kernel | ❓ | ✅ **refs resolved in-container, stripped from logs** | ❓ | ⚠️ log stripping only | ❓ | n/a | ❓ | ❓ | ✅ container+branch per agent | ❓ | macOS, others |
| [yolobox](https://github.com/finbarr/yolobox) | ❌ shared kernel | ⚠️ `--no-network` opt-out | ✅ home not mounted unless opted in | ❌ opt-in `--git-config` | ⚠️ opt-in `--exclude` | ❓ | n/a | ⚠️ agent has root inside | ❓ | ⚠️ `fork` per agent | ❓ | ❓ |
| [packnplay](https://github.com/obra/packnplay) | ❌ shared kernel | ❌ | ❌ **`~/.claude` rw, keychain copied in** | ❌ **executes the project's `devcontainer.json`** | ❌ | ❓ | ❌ | ❌ env whitelist only | ❓ | ✅ worktree-per-agent | ❌ | macOS, Linux |
| [sculptor](https://github.com/imbue-ai/sculptor) | ⚠️ worktree | ❓ | ❓ | ❓ | ❓ | ❓ | ❓ | ❓ | ❓ | ✅ parallel workspaces | ❓ | macOS AS, Linux |
| [vibebox](https://github.com/robcholz/vibebox) | ✅ VM | ❓ | ❌ **`~/.claude`+`~/.codex` rw into VM** | ⚠️ `.git` tmpfs-masked "to discourage accidental edits" | ❓ | ❓ | ❌ | ✅ guest-kernel boundary | n/a | ✅ multi-instance | ❓ | macOS AS |
| [chamber](https://github.com/cirruslabs/chamber) | ✅ ephemeral VM | ❓ | ❓ | ❓ | ❓ | ❓ | ❓ | ✅ destroyed after run | n/a | ❓ | ❓ | macOS |
| [sandvault](https://github.com/webcoyote/sandvault) | ❌ separate user acct | ❓ | ✅ **host `$HOME` unreachable** | ❓ | ❓ | ❓ | n/a | ✅ user acct + Seatbelt | n/a | ❓ | ❓ | macOS |
| [scode](https://github.com/bindsch/scode) | ❌ OS sandbox | ⚠️ `--no-net` kills all | ⚠️ **`~/.ssh` NOT blocked by default** | ❌ | ❌ | ❓ | n/a | ⚠️ "Seatbelt, not armored vehicle" | ❓ | ⚠️ multi-harness | ✅ bats suite | macOS, Linux |
| [SandboxedClaudeCode](https://github.com/CaptainMcCrank/SandboxedClaudeCode) | ❌ OS sandbox | ❌ open | ⚠️ **`$SSH_AUTH_SOCK` rw**, `~/.claude` rw | ❌ | ❌ | ❓ | ❌ | ✅ namespaces, Firejail seccomp | ❓ | ❓ | ❌ "wanted contribution" | Linux, macOS |
| [enclave](https://github.com/kohkimakimoto/enclave) | ❌ OS sandbox | ❌ `(allow default)` | ❓ reads unrestricted | ❓ | ❓ | ❓ | n/a | ⚠️ writes limited to CWD | n/a | ❓ | ❓ | macOS |
| [sbox](https://github.com/streamingfast/sbox) | ✅ microVM | ❓ | ⚠️ `~/.claude` mounted | ❌ | ❌ | ❓ | ❌ | ❓ | ⚠️ opt-in flag | ⚠️ per-project hash | ❌ | ❓ |
| [sandclaude](https://github.com/binwiederhier/sandclaude) | ❌ shared kernel | ❓ | ❌ **host `.credentials.json` mounted** | ❌ | ❌ | ❓ | ❓ | ❓ | ❓ | ⚠️ `-r` resume | ❌ | ❓ |
| [claude-code-sandbox](https://github.com/FoamoftheSea/claude-code-sandbox) | ❌ shared kernel | ✅ internal net + Squid SNI allowlist | ✅ volume-only | ❌ **README advises manual care** | ❌ "agent can read hardcoded secrets" | ❓ | ❓ | ⚠️ pids/mem/cpu limits only | ❌ none | ❓ | ✅ `test-sandbox.sh` | ❓ |
| [claude-code-sandbox](https://github.com/textcortex/claude-code-sandbox) *(archived)* | ❌ shared kernel | ❓ | ❌ **auto-discovers keychain, `gh auth`, `GITHUB_TOKEN`** | ❌ | ❌ | ❓ | ❌ | ❓ | ❓ | ✅ branch per session | ❌ | ❓ |

---

## Project health

| # | Project | Stars | Contrib. | Created | Last activity | License | Primitive |
|---|---|---:|---:|---|---|---|---|
| — | **`kib` (this repo)** | *unpublished* | 1 | — | 2026-07-22 | none | Docker, long-lived per project |
| 1 | [microsandbox](https://github.com/superradcompany/microsandbox) | 6995 | ≥30 | 2024-10-03 | 2026-07-22 | Apache-2.0 | microVM (libkrun) |
| 2 | [sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime) | 4733 | 31 | 2025-10-20 | 2026-07-22 | Apache-2.0 | Seatbelt / bubblewrap |
| 3 | [container-use](https://github.com/dagger/container-use) | 3917 | ≥30 | 2025-05-23 | 2026-06-12 | Apache-2.0 | Container + git branch |
| 4 | [agent-safehouse](https://github.com/eugene1g/agent-safehouse) | 1927 | 16 | 2026-02-09 | 2026-07-17 | Apache-2.0 | macOS Seatbelt |
| 5 | [claudebox](https://github.com/RchGrav/claudebox) | 1124 | 7 | 2025-06-06 | 2025-08-31 | MIT | Docker |
| 6 | [claude-code-devcontainer](https://github.com/trailofbits/claude-code-devcontainer) | 896 | 10 | 2025-09-09 | 2026-07-01 | Apache-2.0 | devcontainer |
| 7 | [fence](https://github.com/fencesandbox/fence) | 864 | 15 | 2025-12-18 | 2026-07-22 | Apache-2.0 | bubblewrap+Landlock |
| 8 | [yolobox](https://github.com/finbarr/yolobox) | 623 | 11 | 2026-01-09 | 2026-07-22 | MIT | Docker / Podman |
| 9 | [matchlock](https://github.com/jingkaihe/matchlock) | 606 | 8 | 2026-02-05 | 2026-06-28 | MIT | microVM (Firecracker) |
| 10 | [cco](https://github.com/nikvdp/cco) | 423 | 8 | 2025-06-22 | 2026-06-27 | MIT | Seatbelt / bubblewrap |
| 11 | [sandvault](https://github.com/webcoyote/sandvault) | 366 | 6 | 2025-09-12 | 2026-07-20 | Apache-2.0 | macOS user account |
| 12 | [claude-code-sandbox](https://github.com/textcortex/claude-code-sandbox) ⚠️ archived | 322 | 3 | 2025-05-25 | 2026-02-20 | none | Docker (files copied) |
| 13 | [sculptor](https://github.com/imbue-ai/sculptor) | 203 | 8 | 2025-08-07 | 2026-07-22 | MIT | git worktree |
| 14 | [agent-sandbox](https://github.com/mattolson/agent-sandbox) | 192 | 3 | 2026-01-17 | 2026-06-15 | MIT | Docker + mitmproxy |
| 15 | [vibebox](https://github.com/robcholz/vibebox) | 186 | 1 | 2026-02-07 | 2026-02-18 | MIT | VM (Apple Virtualization) |
| 16 | [packnplay](https://github.com/obra/packnplay) | 172 | 9 | 2025-10-23 | 2026-03-21 | MIT\* | Docker / devcontainer |
| 17 | [yoloai](https://github.com/kstenerud/yoloai) | 170 | 3 | 2026-02-24 | 2026-07-19 | MIT | Multi-backend |
| 18 | [cplt](https://github.com/navikt/cplt) | 98 | 10 | 2026-04-09 | 2026-07-20 | MIT | Landlock+seccomp |
| 19 | [cleanroom](https://github.com/buildkite/cleanroom) | 56 | 5 | 2026-02-16 | 2026-07-22 | MIT | microVM (SporeVM) |
| 20 | [SandboxedClaudeCode](https://github.com/CaptainMcCrank/SandboxedClaudeCode) | 48 | 2 | 2026-01-26 | 2026-03-20 | MIT | bubblewrap / Firejail |
| 21 | [agent-seatbelt-sandbox](https://github.com/michaelneale/agent-seatbelt-sandbox) | 45 | 2 | 2026-02-11 | 2026-02-11 | none | Seatbelt + proxy |
| 22 | [chamber](https://github.com/cirruslabs/chamber) | 42 | 1 | 2025-07-06 | 2025-12-10 | AGPL-3.0 | Ephemeral macOS VM |
| 23 | [scode](https://github.com/bindsch/scode) | 29 | 1 | 2026-02-13 | 2026-02-25 | MIT | bubblewrap / Seatbelt |
| 24 | [sandbox-shell](https://github.com/agentic-dev3o/sandbox-shell) | 25 | 4 | 2026-01-21 | 2026-07-20 | MIT | macOS Seatbelt |
| 25 | [enclave](https://github.com/kohkimakimoto/enclave) | 24 | 1 | 2025-07-07 | 2026-06-20 | MIT | macOS Seatbelt |
| 26 | [sandclaude](https://github.com/binwiederhier/sandclaude) | 22 | 1 | 2026-03-07 | 2026-05-30 | Apache-2.0 | Docker |
| 27 | [aicontainer](https://github.com/stefanoginella/aicontainer) | 16 | 2 | 2026-05-22 | 2026-07-22 | MIT | devcontainer (Compose) |
| 28 | [sbox](https://github.com/streamingfast/sbox) | 10 | 2 | 2026-01-27 | 2026-05-12 | MIT | Docker Sandbox microVM |
| 29 | [agent-seatbelt](https://github.com/CJHwong/agent-seatbelt) | 6 | 1 | 2026-03-16 | 2026-07-09 | none | macOS Seatbelt |
| 30 | [claude-code-sandbox](https://github.com/FoamoftheSea/claude-code-sandbox) | 2 | 1 | 2026-03-01 | 2026-05-11 | MIT | Docker + Squid |

\* `packnplay` states MIT in its README but ships no LICENSE file.

**Moved:** `use-tusk/fence` → `fencesandbox/fence`; `microsandbox/microsandbox` →
`superradcompany/microsandbox`; `gbrindisi/agentbox` → `gbrindisi/littlebox`.

---

## Read these four

| Project | Why it matters to `kib` |
|---|---|
| [navikt/cplt](https://github.com/navikt/cplt) | **Closest philosophical match.** The same two rare controls — host-config guard *and* in-project secret blocking — kernel-enforced via Landlock instead of FUSE, plus the egress allowlist `kib` lacks. See `COMPARE_TO_CPLT.md`. |
| [sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime) | Anthropic's mandatory deny-write list is the most complete enumeration of host-executed config paths in the field. Worth diffing against `guest/policy/global.kibignore`. Its structured `extract` masking is the credential refinement worth copying. |
| [aicontainer](https://github.com/stefanoginella/aicontainer) | The only other **container** project treating `.git/config`, `.git/hooks` and cross-project config as first-class. Also ships a digest-pinned Docker socket proxy. |
| [yoloai](https://github.com/kstenerud/yoloai) | The other on-by-default credential broker, and a working audit trail of its own escapes — including a host-RCE via agent-controlled `.git/config` filter drivers. |

---

## Method, and what to distrust

<details>
<summary><b>How this was compiled</b></summary>

<br>

**Discovery.** ~10 web searches plus three curated indexes —
[webcoyote/awesome-AI-sandbox](https://github.com/webcoyote/awesome-AI-sandbox),
[wincent's coding-agent-sandbox gist](https://gist.github.com/wincent/2752d8d97727577050c043e4ff9e386e),
and [efij/awesome-claude-code-security](https://github.com/efij/awesome-claude-code-security).
Roughly 120 projects surfaced; 30 were in scope.

**Limitations, in order of how much they should worry you:**

1. **Feature cells come from documentation, not code.** A project may implement a control it never
   writes down. `❓` is therefore common and is *not* evidence of absence.
2. **Contributor counts may be undercounts.** 18 repos were measured directly against the GitHub
   REST API; the rest come from the `ungh.cc` mirror, **which appears to cap at 30**.
3. **Star counts are a popularity signal, not a security signal.** Two of the three most rigorous
   projects here have double-digit stars.

**Scope.** In: locally-run, open-source tools for containing a coding agent on a developer's own
machine. Out: hosted/SaaS sandboxes (E2B, Daytona, Modal, Vercel, Fly, Runloop, Northflank,
Cloudflare); sandbox *primitives* (bubblewrap, gVisor, Firecracker, Landlock, Firejail, Kata,
libkrun); policy layers that add no isolation (Cupcake, nah, predicate-secure, shannot);
closed-source vendor products (Docker `sbx`, Conductor). Eight more projects under 6★ were read
but are too small to compare.

</details>

---

## Sources

**Indexes** ·
[awesome-AI-sandbox](https://github.com/webcoyote/awesome-AI-sandbox) ·
[coding-agent-sandbox gist](https://gist.github.com/wincent/2752d8d97727577050c043e4ff9e386e) ·
[awesome-claude-code-security](https://github.com/efij/awesome-claude-code-security) ·
[awesome-agent-runtime-security](https://github.com/bureado/awesome-agent-runtime-security)

**Threat research** ·
[Pillar Security — The Week of Sandbox Escapes](https://www.pillar.security/blog/the-week-of-sandbox-escapes) (2026-07-20) ·
[BleepingComputer coverage](https://www.bleepingcomputer.com/news/security/cursor-codex-gemini-cli-antigravity-hit-by-sandbox-escapes/)

**Official** ·
[Choose a sandbox environment](https://code.claude.com/docs/en/sandbox-environments) ·
[Development containers](https://code.claude.com/docs/en/devcontainer)

Individual project documentation is linked inline throughout.
