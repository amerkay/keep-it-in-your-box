# kib vs. navikt/cplt — security model, side by side

A head-to-head between **Keep It in Your Box** (`kib`, this repo) and
[**navikt/cplt**](https://github.com/navikt/cplt/blob/main/SECURITY.md), compared against cplt's
published `SECURITY.md` (fetched 2026-07-23).

Both assume the **agent is untrusted arbitrary code**. They attack that from opposite architectural
ends, and that single choice drives every row below:

- **kib** runs the agent **inside a Docker container** and mediates the seams back to the host (FUSE
  redaction, a Wayland clipboard proxy, host-side config validation).
- **cplt** runs the agent **on the host** and confines the process directly — Seatbelt on macOS,
  Landlock LSM + seccomp-BPF on Linux, no container.

So neither is a superset of the other. kib wins on **isolation depth and the host-config / pivot
seams**; cplt wins on **egress control and environment hygiene**. Emoji legend: ✅ clearly stronger ·
⚠️ partial / opt-in / caveated · ❌ absent or explicit accepted gap.

---

## Mega table

| Dimension | kib / Keep It in Your Box | cplt | Edge |
|---|---|---|---|
| **Core isolation model** | ✅ Docker container; agent never runs host-side. `--cap-drop=ALL`, seccomp mode 2, AppArmor `docker-default` enforce, `no-new-privileges`, private PID ns, no docker socket | ⚠️ No container. Host-process MAC: macOS Seatbelt `(deny default)`; Linux Landlock + seccomp-BPF (blocks `ptrace`/`unshare`/`setns`/`mount`/`bpf`/`io_uring`…) | **kib** — a container is a harder wall than host-process confinement |
| **Enforcement locus** | Kernel (ns/caps/seccomp/AppArmor) **+** userspace mediators (FUSE, Wayland proxy) | Kernel (Seatbelt/Landlock/seccomp) **+** optional userspace proxy & PATH-shim guards | ➖ tie — both layer kernel + userspace |
| **No-container portability** | ❌ Requires a Docker engine; macOS needs a cap-capable-at-creation container (accepted R2 trade) | ✅ Confines native host processes, zero container dependency | **cplt** |
| **Platform parity** | ⚠️ Linux full; macOS via Plan H single-container FUSE (`SYS_ADMIN`+`SETPCAP` at creation, dropped per-session via `setpriv`+`gosu`); on-hardware VERIFY items open | ⚠️ macOS (Seatbelt) most-tested; Linux Landlock younger, net filtering needs kernel 6.7+ | ➖ tie — each is strongest on a different OS |
| **FS — outside project** | ✅ **Absent by construction** — the container never mounts `~/Desktop`, `~/Documents`, browser profiles, `~/.ssh`… They *do not exist* in the agent's world, so no policy bug, allowlist gap, kernel-version shortfall, or `--allow-*` flag can ever expose them. Zero surface | ⚠️ **Deny-by-enumeration** — the files are physically on the host and reachable syscall-wise; safety rests on the Landlock/Seatbelt ruleset being airtight. Deny-default *plus* a broad allowlist (tool dirs, `~/.copilot`/`~/.claude` r/w, blanket `mach-lookup` on macOS); named dirs (`~/.ssh`/`~/.aws`/`~/.gnupg`…) denied, but Desktop/Documents/browser history are safe only if the allowlist stays tight and Landlock ABI ≥ v1 holds | **kib — by a large margin.** Nothing-mounted is a stronger guarantee than a complete-denylist promise |
| **FS — in-project secrets** | ✅ FUSE redaction (`kib/guest/fuse.py`): `.env*`/`.kibignore` → stub on read, EACCES on write, **covers files created after launch**; placeholders (`.env.example`…) pass through; honors `!` negations | ⚠️ `.env`/`.env.local`/`.env.*.local` kernel-denied by default; `--allow-env-files` opt-in. Fixed path set, no post-hoc arbitrary-secret redaction | **kib** — post-launch coverage + negation-aware |
| **Granular exec/write per dir** | ➖ Not modeled — and doesn't need to be: `~/.m2`/`~/.gradle` inside the container are **throwaway copies**, not host dirs, and a successful "stage + exec" only runs inside a `cap-drop=ALL`, no-host-egress container. The container edge is the boundary | ➖ Per-tool-dir `process-exec`/`file-map-executable`/`file-write` flags (`.gradle`/`.m2` dlopen-only, `/tmp` no-exec, scratch write+exec) — a finer scalpel it needs **because those are live host dirs** | ➖ tie — cplt needs the scalpel because it operates on real host dirs; kib doesn't expose them at all |
| **Git-hook / host-executed-config persistence** | ✅ Structural guard (`guest/policy/global.kibignore` + FUSE): `.git/hooks` read-only **and** `.git/config` content-validated — refuses new `core.hooksPath`/`fsmonitor`/`sshCommand`/`pager`/`alias.*`/`filter.*.clean`/`include(If)`; git dirs matched by **layout** not name (bare/submodule/worktree/separate-git-dir); `link()` validates source inode | ⚠️ macOS Seatbelt denies `.git/hooks`. **Linux+Landlock alone leaves `.git/hooks` writable**; Bubblewrap re-binds read-only. **`.git/config` writable on all platforms** (accepted residual → `core.hooksPath=/tmp/evil`) | **kib** — closes both hooks *and* config, structurally |
| **`.vscode` / IDE auto-exec config** | ✅ Same guard `[protect]` set (`.vscode/`,`.devcontainer/`,`.idea/`,`.envrc`) — writes EACCES | ❌ Explicitly out of scope — "IDE trust boundary, not sandbox scope." Mitigation = review `git diff` | **kib** |
| **Config-guard immunity to project override** | ✅ Guard rules immune to project negation (`_verdict` tallies guard vs project separately, guard wins); config read from FUSE view | ✅ `.cplt.toml` `[propose]` inert until `cplt trust accept`; config read from **`git HEAD`** not worktree; content-pinned SHA-256 approvals bound to canonical path | ➖ tie — both defeat self-relaxation, cleanly |
| **Network / egress** | ❌ Open egress (accepted risk H3/H4). No port/domain filtering; `host.docker.internal` routable. Rationale: build untrusted repos that fetch arbitrary registries | ✅ Outbound TCP **443-only**, localhost blocked; opt-in CONNECT proxy with allow/blocklist, DNS-rebind defense, `--proxy-forced` for kernel-mandatory routing | **cplt** — kib's single widest hole |
| **DNS posture** | ➖ Treated as **liveness**, not a filter: `guest/bin/resolv-sync.sh` tracks host wifi/VPN; systemd-resolved Varlink sockets shadowed with `/dev/null` | ✅ Treated as **attack surface**: rebinding protection (post-resolve private-IP validation, pinned SocketAddr); DNS-tunneling acknowledged as uninspected gap | **cplt** for security posture; kib solves a different (availability) problem |
| **Credential handling** | ⚠️ One shared OAuth token (`~/.claude-shared/.credentials.json`), same-uid readable, **exfiltratable under open egress** — "rotate if untrusted session ran." Per-project config dirs isolate transcripts/history/jobs | ⚠️ Per-tool auth dirs; `.gh-token` cached 0600 served-once-then-deleted (self-described "not a confidentiality boundary"); API keys never auto-passed (`--pass-env` opt-in) | **cplt** slightly — narrower default token exposure |
| **Env-var sanitization** | ➖ **Clean by construction** — the container starts from a fresh env and `kib` forwards only a small explicit `-e` allowlist (`CLAUDE_CONFIG_DIR`, `HOST_UID/GID/HOME`, git author/committer, `TERM`, `KIB_SESSION_TAG`…); **no `--env-file`, no host-shell inheritance**, so `AWS_*`/`DATABASE_URL`/`SSH_AUTH_SOCK`/`NPM_TOKEN` never reach the agent | ➖ `env_clear()` + 49-var allowlist + 9 prefixes; `ENV_ALWAYS_DENY` for `SSH_AUTH_SOCK`/`AWS_*`/`DATABASE_URL`/`VAULT_TOKEN` — needed **because it inherits the host shell env** and must strip it back down | ➖ tie — kib starts clean and adds a whitelist; cplt inherits dirty and clears back to a whitelist. Same result |
| **Supply-chain / lifecycle scripts** | ⚠️ Not specifically hardened — container blast-radius is the mitigation | ✅ `npm_config_ignore_scripts=true` + `YARN_ENABLE_SCRIPTS=false` injected unconditionally (anti-Shai-Hulud); `--allow-lifecycle-scripts` opt-out | **cplt** |
| **Clipboard** | ✅ Mediated, not handed over: `kib/guest/wayland_guard.py` sidecar (`--network none`) passes reads, **refuses every write** (write = host code-exec at next paste via `ESC[201~`); macOS one-way pbpaste bridge | ⚠️ Clipboard reachable on macOS (`com.apple.pasteboard`); `--deny-clipboard` to block. All-or-nothing, no read/write asymmetry | **kib** — models the write-as-RCE threat |
| **git / gh command guarding** | ➖ Not intercepted at command level; relies on the host-side audit gate (`kib audit`, also run at launch/teardown) + the FS guard | ⚠️ Opt-in PATH-shim `git_guard`/`gh_guard` (block force-push, DELETE API, `-c alias.*`). Honest gap: absolute-path/`env git` bypasses entirely — "not a kernel boundary" | ➖ tie — cplt has the feature but concedes it's bypassable |
| **Cross-project / cross-session pivot** | ✅ First-class: per-project `CLAUDE_CONFIG_DIR`; shared assets mounted **read-only individually**; `validate_shared_settings` refuses inline `hooks[].command`/`apiKeyHelper`/`statusLine.command` host-side each launch; `.claude.json` pruned per-project | ⚠️ Not a stated axis (per-tool config dirs r/w); `--deny-path ~/.copilot/session-state` mitigates cross-session reads | **kib** |
| **Commit safety** | ✅ Host reads every diff before it lands; policy: never commit unasked, never `--no-verify`/`--amend`; pre-commit hook is a real host control | ⚠️ Opt-in guards block force-push/cross-repo; primary reliance is "review before commit" | **kib** |
| **Auto-update integrity** | ⚠️ Background image rebuild (`tools/build-image.sh`), version pinned by build arg; trust = Docker/NodeSource/official installer chain | ⚠️ `cplt update`: mandatory SHA256, `--proto-redir=https`, atomic rename; **no GPG/Sigstore sig** (accepted); prefers Homebrew | ➖ tie — neither cryptographically signs |
| **Input-validation hardening** | ➖ Guard matching is path/rule based inside the container view | ✅ SBPL-injection defense (blocked chars, atomic `create_new` 0600 profile), unsafe-root rejection (`/`,`$HOME`,`/tmp`…), path canonicalization | **cplt** — needed because it templates host kernel policy |
| **Operational robustness** | ✅ `host/sleep-guard.sh` (busiest-process sampling, proactive lid-shut suspend), live-DNS sync, one-container-per-project lifecycle | ➖ Not in scope | **kib** (out of cplt's scope) |
| **Testing story** | ✅ `security-test.sh` — each check re-runs the real attack **and** the legit op it must not break; runs in both FUSE modes | ✅ 39 unit + 39 macOS integration (real `sandbox-exec`) + 38 E2E + 6 smoke | ➖ tie — both test enforcement, not just logic |

---

## The honest head-to-head

### Where kib is stronger
- **The host filesystem is absent, not just denied.** `~/Desktop`, `~/Documents`, browser history,
  SSH keys — none are mounted, so they don't exist in the agent's world. cplt runs the agent *on the
  host*: those files are physically present and reachable, and their safety depends on the
  Landlock/Seatbelt allowlist being airtight, the kernel being new enough, and no `--allow-*`
  over-grant. Absent-by-construction can't be defeated by a policy gap; a complete-denylist promise
  can. This is a large-margin win, not a tie.
- **Isolation depth.** Full PID/mount/net namespaces, caps dropped, no host FS present — a harder
  wall than host-process MAC. cplt's own doc concedes Linux+Landlock leaves **both** `.git/hooks`
  and `.git/config` writable without a Bubblewrap add-on; kib closes both structurally (layout-based
  git-dir detection, `include`-following, `link()` source validation).
- **Post-launch secret coverage.** FUSE redacts files created *after* launch and honors `!`
  negations gitignore-style; cplt's `.env` deny is a fixed path set.
- **Clipboard write = code-exec** is a threat kib names and neutralizes with a filtering proxy; cplt
  treats the clipboard as an all-or-nothing opt-out.
- **Cross-project pivot & shared-config poisoning** are first-class (`validate_shared_settings`,
  read-only asset mounts, per-project config dirs). Barely an axis in cplt.

### Where cplt is stronger
- **Egress control — the big one.** cplt defaults to **443-only + localhost-blocked +
  DNS-rebind-defended proxy**, with a kernel-mandatory `--proxy-forced`. kib runs **open egress by
  explicit accepted risk**, paired with a durable same-uid-readable OAuth token. That is kib's widest
  hole (audit H3/H4), and cplt's design targets it directly.
- **Supply-chain lifecycle hardening** (`ignore_scripts`) — a concrete control kib lacks.
- **No-container portability** — confines native host processes with zero Docker dependency.

### One-line summary
kib wins on **isolation depth and the host-config / pivot seams**; cplt wins on **egress and
environment hygiene**. The highest-value cross-pollination for kib would be **borrowing cplt's
egress-proxy model** (443-only + DNS-rebind validation + forced routing) to finally address the
open-egress + durable-token risk kib currently documents as accepted.
