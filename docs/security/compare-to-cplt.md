# kib vs. navikt/cplt — security model, side by side

**Keep It in Your Box** (`kib`, this repo) against [**navikt/cplt**](https://github.com/navikt/cplt),
read from cplt's published `SECURITY.md` (fetched 2026-07-23).

Both assume the **agent is untrusted arbitrary code**, and attack that from opposite ends:

- **kib** runs the agent **inside a Docker container** and mediates the seams back to the host —
  FUSE redaction, a clipboard proxy, host-side config validation, a credential broker.
- **cplt** runs the agent **on the host** and confines the process directly — Seatbelt on macOS,
  Landlock + seccomp-BPF on Linux, no container.

Neither is a superset of the other. Legend: ✅ clearly stronger · ⚠️ partial / opt-in / caveated ·
❌ absent or an explicit accepted gap · ➖ tie.

---

| Dimension | kib | cplt | Edge |
|---|---|---|---|
| **Isolation model** | Docker container; the agent never runs host-side. `cap-drop=ALL` (five caps back for entrypoint user setup, none in the agent's own session), seccomp, AppArmor, `no-new-privileges`, private PID ns, no docker socket | No container. Host-process MAC: Seatbelt on macOS; Landlock + seccomp-BPF on Linux (blocks `ptrace`/`unshare`/`setns`/`mount`/`bpf`/`io_uring`) | **kib** — a container is a harder wall than host-process confinement |
| **No-container portability** | ❌ requires a Docker engine | ✅ confines native host processes, zero container dependency | **cplt** |
| **Platforms** | Linux and macOS, one topology (in-container FUSE, capless at runtime rather than at creation) | macOS best-tested; Linux Landlock younger, net filtering needs kernel 6.7+ | ➖ tie |
| **FS — outside the project** | ✅ **absent by construction** — `~/Desktop`, `~/Documents`, browser profiles, `~/.ssh` are never mounted, so no policy bug or `--allow-*` flag can expose them | ⚠️ **deny by enumeration** — those files are physically present and syscall-reachable; safety rests on the allowlist staying tight and Landlock ABI ≥ v1 | **kib, by a large margin** — nothing-mounted beats a complete-denylist promise |
| **FS — in-project secrets** | ✅ FUSE (`kib/guest/fuse.py`): `.env*` / `.kibignore` read as key names with values replaced (stub if the shape is unknown), `EPERM` on write, **covers files created after launch**, honours `!` negations; placeholders (`.env.example`…) pass through | ⚠️ `.env`/`.env.local`/`.env.*.local` denied by default (`--allow-env-files` opts out). Fixed path set, no post-launch coverage | **kib** |
| **Host-executed config** | ✅ `guest/policy/global.kibignore` + FUSE: `.git/hooks` read-only, `.git/config` **content-validated** (refuses newly-added `core.hooksPath`/`fsmonitor`/`sshCommand`/`pager`/`alias.*`/`filter.*.clean`/`include(If)`); git dirs matched by **layout**, not name; `link()` validates the source inode | ⚠️ macOS Seatbelt denies `.git/hooks`; **Linux+Landlock alone leaves it writable** (Bubblewrap re-binds RO). **`.git/config` writable on all platforms** — accepted residual → `core.hooksPath=/tmp/evil` | **kib** — closes both, structurally |
| **`.vscode` / IDE auto-exec** | ✅ same `[protect]` set (`.vscode/`, `.devcontainer/`, `.idea/`, `.envrc`) — writes `EACCES` | ❌ explicitly out of scope: "IDE trust boundary." Mitigation = review `git diff` | **kib** |
| **Guard immune to project override** | ✅ guard rules outrank project negations (`_verdict` tallies them separately); config read from the FUSE view | ✅ `.cplt.toml` `[propose]` inert until `cplt trust accept`; config read from `git HEAD`, content-pinned SHA-256 approvals | ➖ tie — both defeat self-relaxation cleanly |
| **Credential** | ✅ **brokered by default** — a host-side sidecar holds a static token, the container gets `ANTHROPIC_BASE_URL` plus a synthetic placeholder, and the broker re-originates TLS upstream (no CA in the container). Same broker covers third-party MCP credentials, and `claude mcp add --header …` is intercepted host-side before the secret can reach the box | ⚠️ per-tool auth dirs; the OAuth token "lives in `~/.claude/.credentials.json` … **exposed to the sandbox** … an inherent trade-off." `.gh-token` cached 0600, served once, self-described as "not a confidentiality boundary" | **kib** |
| **Network / egress** | ❌ open (accepted risk H3/H4). No port or domain filtering; `host.docker.internal` routable. Rationale: build untrusted repos that fetch arbitrary registries | ✅ outbound TCP **443-only**, localhost blocked; opt-in CONNECT proxy with allow/blocklist, DNS-rebind defence, `--proxy-forced` | **cplt** — kib's one deliberate hole |
| **DNS** | ➖ treated as **liveness**: `guest/bin/resolv-sync.sh` follows host wifi/VPN changes; systemd-resolved Varlink sockets shadowed | ✅ treated as **attack surface**: rebinding protection, pinned `SocketAddr`; DNS tunnelling acknowledged as uninspected | **cplt** on posture; kib solves a different problem |
| **Env-var hygiene** | ➖ **clean by construction** — a fresh container env plus a small explicit `-e` allowlist. No `--env-file`, no host-shell inheritance, so `AWS_*`/`DATABASE_URL`/`SSH_AUTH_SOCK`/`NPM_TOKEN` never reach the agent | ➖ `env_clear()` + a 49-var allowlist + 9 prefixes + `ENV_ALWAYS_DENY` — needed *because* it inherits the host shell env | ➖ tie — same result from opposite directions |
| **Supply-chain lifecycle scripts** | ⚠️ not specifically hardened; container blast radius is the mitigation | ✅ `npm_config_ignore_scripts=true` + `YARN_ENABLE_SCRIPTS=false` injected unconditionally, `--allow-lifecycle-scripts` opts out | **cplt** |
| **Clipboard** | ✅ mediated, not handed over: `kib/guest/wayland_guard.py` sidecar (`--network none`) passes reads and **strips control characters out of every write** — a verbatim write is host code-exec at the next paste via `ESC[201~`. macOS gets a one-way `pbpaste` bridge | ⚠️ reachable on macOS via the blanket `mach-lookup`; `--deny-clipboard` is all-or-nothing. Listed out of scope | **kib** — models the write-as-RCE threat |
| **git / gh command guarding** | ➖ not intercepted at command level; the FS guard plus the host-side audit gate (`kib audit`, also run at launch and teardown) carry it | ⚠️ opt-in PATH shims (`git_guard`/`gh_guard`); its own docs concede `\git` or an absolute path bypasses them, and they default to off | ➖ tie — cplt has the feature and concedes it is bypassable |
| **Cross-project pivot** | ✅ first-class: per-project `CLAUDE_CONFIG_DIR`, shared assets mounted `:ro` individually, `validate_shared_settings` refuses inline `hooks[].command`/`apiKeyHelper`/`statusLine.command` each launch, `.claude.json` pruned per project | ⚠️ not a stated axis; `--deny-path ~/.copilot/session-state` mitigates cross-session reads | **kib** |
| **Input-validation hardening** | ➖ rule/path matching inside the container view | ✅ SBPL-injection defence, unsafe-root rejection, path canonicalization — needed because it templates host kernel policy | **cplt** |
| **Testing** | ✅ `tests/security-test.sh` — 11 sections, each re-running the real attack **and** the legitimate operation it must not break, in both redaction modes | ✅ 39 unit + 39 macOS integration (real `sandbox-exec`) + 38 E2E + 6 smoke | ➖ tie — both test enforcement, not just logic |

---

## Where each one wins

**kib** — the host filesystem is *absent*, not denied; `.git/config` and `.git/hooks` are both
closed structurally (cplt concedes Linux+Landlock leaves both writable); redaction covers
files created after launch; the clipboard write-as-code-exec threat is named and neutralised;
cross-project config poisoning is a first-class axis; the account credential never enters the box.

**cplt** — **egress**, the one column kib concedes: 443-only, localhost blocked, DNS-rebind
defended, with a kernel-mandatory `--proxy-forced` mode. Plus unconditional lifecycle-script
suppression, and no container dependency at all.

**The cross-pollination worth doing:** cplt's egress model, as an opt-in mode. It is designed but
not scheduled — an allowlist cannot close `api.anthropic.com` or the registries, which is where
exfil actually happens, so kib shipped the credential broker instead
([`credential-broker.md`](../design-notes/credential-broker.md)).
