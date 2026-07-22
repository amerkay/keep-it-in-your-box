<!-- Hero: rendered from assets/security-audit/hero.svg -->
<p align="center">
  <img src="assets/security-audit/hero.svg" width="100%"
       alt="Security Audit of the cc Claude Code Docker sandbox. Verdict: the container holds, but the git-config guard is breached. 4 critical findings, 8 high findings, 6 host-RCE paths, 0 container escapes." />
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Critical-4-da3633?style=flat-square" alt="4 critical" />
  <img src="https://img.shields.io/badge/High-8-fb8500?style=flat-square" alt="8 high" />
  <img src="https://img.shields.io/badge/Low-1-1f6feb?style=flat-square" alt="1 low" />
  <img src="https://img.shields.io/badge/Container_escapes-0-2ea043?style=flat-square" alt="0 container escapes" />
  <img src="https://img.shields.io/badge/Method-live_exploitation-8957e5?style=flat-square" alt="method: live exploitation" />
  <img src="https://img.shields.io/badge/Date-2026--07--22-30363d?style=flat-square" alt="2026-07-22" />
  <img src="https://img.shields.io/badge/P0-remediated-2ea043?style=flat-square" alt="P0 remediated" />
</p>

---

## The question

> **Can a malicious script, webpage, or GitHub repo driving this session escape the sandbox and execute code on the host?**

**As audited, yes — host code execution was achievable, and so is theft of the host OAuth token.** Six confirmed paths reached the host, four rated **Critical**. The container hardening itself is excellent — *every* classic container-escape CVE was tested and blocked — but the sandbox's own stated boundary, *"what the host runs later,"* has multiple holes in the **git-config guard**, and the shared credential/settings surface is exfiltrable by design.

> [!TIP]
> **Remediation status — `P0` shipped.** C1–C4, H1 and H2 are **fixed** in `ccignore-fuse.py` and `ccignore-precommit.py`: `include`/`includeIf` are refused, the config parser follows git's grammar, `link()` validates its source inode, and git dirs are recognised by layout rather than by the name `.git`. Every finding below is retained as the record of *why* each control exists. H3/H5/H6/H8 remain the documented accepted risks.

> [!CAUTION]
> The most important chains fire on the **host's next `git status` / `git add` / `git commit`** — i.e. the exact commands you run to *review the sandbox's diff before trusting it*. `core.fsmonitor` executes on a bare `git status`, **before a human sees anything**, and a redirected `core.hooksPath` routes git straight past the repo's own `ccignore-precommit.py` guard hook. **The review step the whole model relies on is where the payload detonates.**

<sub>**Scope:** `cc`, `cc-lib.sh`, `docker-entrypoint.sh`, `Dockerfile`, `ccignore-fuse.py`, `global.ccignore`, `ccignore-precommit.py`, `resolv-sync.sh`, `sleep-guard.sh` · **Method:** static analysis of every control + **live exploitation from inside a running sandbox**, each finding re-verified by an adversarial second pass · **Non-destructive:** proven via config *resolution* (`git config --get`), a permitted write-*open* (nothing written), `stat`, or resolved-state reads — never by running host code or reading a real secret.</sub>

---

## Findings at a glance

| # | Finding | Severity | Host impact | Status |
|:--|:--|:--|:--|:--|
| **C1** | `git config include.path` / `includeIf.*.path` indirection | 🔴 Critical | Host RCE | ✅ **Fixed** |
| **C2** | Hardlink defeats FUSE `protect`/`redact` (path-string guard) | 🔴 Critical | Host RCE + secret read | ✅ **Fixed** |
| **C3** | Inline `[section]key=value` bypass of the config validator | 🔴 Critical | Host RCE | ✅ **Fixed** |
| **C4** | `.gitattributes` filter/diff/merge driver via include | 🔴 Critical | Host RCE | ✅ **Fixed** |
| **H1** | Bare / `--separate-git-dir` repo (dir not named `.git`) | 🟠 High | Host RCE | ✅ **Fixed** |
| **H2** | gitfile / symlinked `.git` redirect to unguarded gitdir | 🟠 High | Host RCE | ✅ **Fixed** |
| **H3** | Shared OAuth token exfiltration over open egress | 🟠 High | Host credential theft | Confirmed (live) |
| **H4** | Prompt-injection → unattended token exfil (universal enabler) | 🟠 High | Host credential theft | Confirmed (live) |
| **H5** | Poison shared `settings.json` (`ANTHROPIC_BASE_URL`/`apiKeyHelper`/hooks) | 🟠 High | Host cred theft + cross-project | Confirmed (live) |
| **H6** | Poison shared `plugins`/`skills`/`agents`/`commands` | 🟠 High | Cross-project persistence | Confirmed (live) |
| **H7** | npm/pip install-time RCE arms the host-reaching chains | 🟠 High | Host cred theft (chained) | Confirmed |
| **H8** | Wayland clipboard poisoning → host paste RCE / read exfil | 🟠 High | Host RCE (on paste) | Confirmed (mechanism) |
| **L1** | Unguarded project `.claude/settings.json` & `.mcp.json` autoload | 🟡 Low | In-container only | Confirmed |
| **—** | Container-escape CVEs, FUSE-sidecar pivot, symlink escape, mount-propagation, host-resolver reach, sleep-guard injection | 🟢 Info | None | **Verified blocked** |

---

## 🧯 Master remediation matrix

Every confirmed vulnerability, its root cause, its fix, and the real-world attack class it belongs to. Fix tier (`P0`/`P1`/`P2`) is expanded under [Recommendations](#-recommendations).

| # | Vulnerability | How it reaches the host | Root cause (`file:line`) | Fix | Prior art / CVE |
|:--|:--|:--|:--|:--|:--|
| **C1** | `include.path` / `includeIf.*.path` indirection | Validator reads *literal* text, never resolves includes; `include`/`path` aren't in the danger set → included file declares `core.hooksPath`/`fsmonitor`, git resolves it on any op | `ccignore-fuse.py:41` (`DANGEROUS_GIT_KEYS` omits `include`/`includeif`/`path`) · `:353` (`_dangerous_entries` never resolves includes) · `ccignore-precommit.py:40` (`--local --list` is include-blind) | ✅ **Fixed** — `include`/`includeif` added to `DANGEROUS_GIT_SECTIONS`, so a *newly added* include is refused like any command key (pre-existing ones stay grandfathered) | Justin Steven, *buried bare repos* (2022); Pillar, *Week of Sandbox Escapes* |
| **C2** | Hardlink defeats the path-string guard | `link()` checks only the **new name**, not the **source inode**; a hardlink aliases a protected inode and the VFS doesn't re-resolve it (a symlink would) → write `core.hooksPath` directly; read a `redact`ed secret | `ccignore-fuse.py:453-455` (`link()` validates target, not source); guard keys on **path string**, not inode | ✅ **Fixed** — `link()` now calls `_deny_if_masked(source)` as well as target. (`default_permissions` deliberately not enabled — it also changes stub-inode semantics) | Kernel `protected_hardlinks` / `may_linkat`; FUSE reasons in inodes, not paths |
| **C3** | Inline `[section]key=value` parser bypass | Parser treats any `[`-line as a pure header and `continue`s, dropping a trailing inline `key=value`; **git accepts `[core]hooksPath=…` on one line** | `ccignore-fuse.py:358-363` — hand-rolled parser diverges from git's grammar | ✅ **Fixed** — `_dangerous_entries` resumes parsing after `]` instead of dropping the line, matching git's grammar | Codex `git show` allowlist bypass (Pillar) — same "parser divergence" class |
| **C4** | `.gitattributes` filter/diff/merge driver | Drivers *are* blocked on direct write, but via C1's include they're defined in an included file; `.gitattributes` (unguarded worktree file) binds them → runs on checkout/diff/merge/archive | Same as C1; `.gitattributes` is an extra trigger surface | ✅ **Fixed** — closed by C1: with the include hop refused, the drivers can no longer be defined at all | CVE-2021-21300 (clean/smudge filter RCE) |
| **H1** | Bare / `--separate-git-dir` repo (dir ≠ `.git`) | `_is_git_config`/`_git_sensitive` require a literal `.git` component; a bare or separate gitdir isn't named `.git`, so `config`/`hooks` under it are unguarded → direct `core.hooksPath` | `ccignore-fuse.py:333` / `:338` (literal `.git` match); `ccignore-precommit.py` audits top repo only | ✅ **Fixed** — `_is_gitdir()` marker probe (`HEAD`+`objects`+`refs`) in both `_is_git_config` and `_git_sensitive`; `audit_nested_gitdirs()` added host-side | CVE-2026-45033 (Copilot CLI nested bare-repo `fsmonitor` RCE); LWN, *embedded bare repos* |
| **H2** | gitfile / symlinked `.git` redirect | A `.git` **file** containing `gitdir: ../store` redirects config+hooks into an unguarded dir; only a literal `.git` *component* is treated as sensitive | `ccignore-fuse.py:338` (`_git_sensitive` component match) | ✅ **Fixed** — closed by H1: the redirect *target* is a real gitdir, so the marker probe guards it. The gitfile stays writable so `git worktree add` works | CVE-2021-21300 class; Cursor gitfile→`fsmonitor` chain (fixed Cursor 3.0.0) |
| **H3** | Shared OAuth token exfil over open egress | `~/.claude-shared/.credentials.json` (0600, **same-uid readable**, a real host mount outside FUSE) + **fully open egress** → token leaves the box | Open egress + durable credential in a container-reachable mount | **P1** — default-deny egress, allowlist the Anthropic API; broker short-lived scoped tokens host-side; **rotate** if any untrusted session ran | Documented accepted risk; generic OAuth exfil |
| **H4** | Prompt-injection → unattended token exfil | Injected content runs any in-container command with no consent (`cc:387`; subagents `bypassPermissions`); read→exfil of the host token needs *no host trigger* and arms every other chain | By design (`--dangerously-skip-permissions`) + H3 | Mitigated by H3's egress control; in-container by design | Pillar, *Week of Sandbox Escapes*; CSA prompt-injection CI/CD note |
| **H5** | Poison shared `settings.json` | Writable, **outside** FUSE; entrypoint symlinks it into every project and **folds in-session edits back** into the shared copy; no validation → `ANTHROPIC_BASE_URL`, `apiKeyHelper`, inline `hooks[].command` propagate to every project's next session | `docker-entrypoint.sh:95-110` (fold-back); no content validation | **P1** — mount shared `settings.json` read-only; per-project fold-back; refuse `ANTHROPIC_BASE_URL`/`ANTHROPIC_API_KEY`, `apiKeyHelper`, inline `hooks[].command` | **CVE-2026-21852** (`ANTHROPIC_BASE_URL` leak, fixed Claude Code v2.0.65); CVE-2025-59536; Cursor `.claude` hook CVE-2026-48124 |
| **H6** | Poison shared `plugins`/`skills`/`agents`/`commands` | 0775, writable, symlinked into every project, **not** read-only mounted → auto-run in every project's next session; with H3, exfil the token | Shared writable assets, no validation | **P1** — read-only mount; write per-project | Cymulate, *Configuration-Based Sandbox Escape* (Apr 2025) |
| **H7** | npm/pip install-time RCE | `bypassPermissions` runs lifecycle scripts with no prompt; in-container alone, but it **arms** C1–C4 (host RCE), H3 (token), H5/H6 (shared poison) | By design (the sandbox exists to build untrusted repos) | Mitigate the *targets* (P0/P1); the install itself can't be removed | Supply-chain lifecycle-script RCE |
| **H8** | Wayland clipboard poisoning | Raw RW Wayland socket (`cc:268`), no mediation → **write** the clipboard with terminal-escape / bracketed-paste-bypass (`ESC[201~`) sequences that execute on your next host paste; **read** it continuously (`wl-paste --watch`) | `cc:268` — unmediated read-write socket mount | **P2** — clipboard proxy: permit host→container *image* paste only, deny clipboard writes | Pastejacking (Ayrey); bracketed-paste bypass; `wl-copy` passes arbitrary bytes verbatim |
| **L1** | Unguarded project `.claude/` & `.mcp.json` | `global.ccignore` lists `.vscode`/`.envrc`/`.env*` but not `.claude/` or `.mcp.json`; a malicious repo's autoload files get in-container RCE — **already free** under skip-permissions | Not pruned/validated | **P2** — add `.claude/settings*.json`, `.claude/hooks`, `.mcp.json` to a validated guard section | CVE-2025-59536; CVE-2026-21852 |

---

## ✅ Remediation verified live

Re-run **from inside a restarted sandbox, through the real FUSE mount** (2026-07-22) — the
same non-destructive technique as the original exploitation pass: the payload is proven
*unresolvable* rather than detonated.

| # | Reproduction | Before | After |
|:--|:--|:--|:--|
| **C1** | `git config include.path evil.inc` | accepted | `could not write config file .git/config: Permission denied` |
| **C1b** | `git config 'includeIf.gitdir:/x/.path' …` | accepted | Permission denied |
| **C3** | rename a config carrying `[core]hooksPath = …` (inline form) | accepted | Permission denied · `core.hooksPath` resolves to nothing |
| **C3b** | same, normal multi-line form (regression) | denied | still denied |
| **C4** | `git config filter.x.clean 'echo pwn'` | denied | still denied — and the include route that re-enabled it is now shut |
| **C2** | `ln .git/config hardconfig` | permitted | `failed to create hard link … Permission denied` |
| **H1** | `git init --bare b1 && git -C b1 config core.hooksPath …` | accepted + resolved | Permission denied · resolves to nothing |
| **H1b** | write `b1/hooks/pre-commit` into the bare repo | permitted | Permission denied |
| **H2** | `--separate-git-dir=gd wt` → `git -C wt config core.fsmonitor …` | accepted + **executed on `git status`** | Permission denied · resolves to nothing |

**Regressions checked — all still working:** `git status`, config reads, `git init`
(with an empty template), `git add`, `git commit`, `git remote add`, `git worktree add`,
`git init --bare`, and ordinary hardlinks. `core.pager` is still refused, and the symlink
form is still resolved by the kernel before the guard sees it.

> [!NOTE]
> **Pre-existing functional bug found while verifying — not caused by these fixes, not yet fixed.**
> `git clone` and a default `git init` **fail inside the sandbox**: git copies its template
> directory first, `mkdir .git/hooks` is refused by `_git_sensitive`, and git aborts leaving a
> partial `.git/`. Confirmed present at `HEAD` before this change (`return ".git" in parts and
> "hooks" in parts`). Workaround today: `GIT_TEMPLATE_DIR= git init …`. The likely minimal fix is
> to permit creating the `hooks` **directory** and `*.sample` files — neither of which git ever
> executes — while continuing to deny every other write beneath it.

---

## Threat model

<details>
<summary><b>What counts as a finding, and why in-container RCE doesn't</b></summary>

<br>

The sandbox launches `claude --dangerously-skip-permissions` (`cc:387`), so **in-container code execution from injected content is expected and accepted** — the container *is* the boundary. A malicious webpage or repo can already run any command inside the container with no consent prompt.

This audit therefore measures only what **escapes** that boundary:

- **host code execution**,
- **host credential theft**, and
- **cross-project persistence**.

In-container-only effects are not counted as findings.

</details>

<details>
<summary><b>Methodology — 15-agent recon, 38-agent live exploitation, adversarial verify</b></summary>

<br>

1. **Recon** (15 parallel agents): mapped **72 distinct controls** across the 7 subsystems and swept published Claude Code / AI-coding-agent / container-escape / git-indirection / MCP / Wayland CVEs and disclosures (**118 candidate vectors**).
2. **Exploit testing** (19 vectors × test + adversarial-verify = **38 agents, ~1.85M tokens**): each vector was **actually executed against a live sandbox**, then a second agent tried to *refute* the verdict. Git tests ran in isolated `_audit_<id>/` subdirectories — still under the live FUSE guard — to avoid touching the real `.git/config`.
3. All testing was **non-destructive**: exploitability was proven via config *resolution* (`git config --get`), a permitted write-*open* (fd opened, nothing written), `stat`, or reading resolved state — never by executing host code or reading a real secret.

Only one verdict changed under adversarial review: **H4** was *upgraded* — read→exfil of the host token (H3) needs no additional bypass and no host trigger, so prompt-injection is a direct host-credential-theft consequence, not merely in-container.

</details>

---

## 🔴 Critical findings

<details open>
<summary><b>C1 — <code>include.path</code> / <code>includeIf.*.path</code> indirection → host RCE</b></summary>

<br>

**The guard.** `.git/config` is content-validated on write: `_dangerous_entries` (`ccignore-fuse.py:353`) parses the file and `_git_config_write_ok` (`:372`) refuses any *new* entry whose key is in `DANGEROUS_GIT_KEYS` (`:41` — `hooksPath`, `fsmonitor`, `sshCommand`, …). Directly setting `core.hooksPath` is correctly refused.

**The gap.** `include`/`includeif`/`path` are **not** in the danger set, and the validator inspects only the *literal* text — it never resolves includes. So `git config include.path <file>` passes, and the pointed-to file (any writable worktree file — only `config`/`hooks` are masked under `.git`) declares `[core] hooksPath = …`. Git resolves it fully.

**Live evidence.** In an isolated guard-covered gitdir: a `mv` (rename = the write) of a config containing `[core] hooksPath` → **EACCES** (validator held); the same rename adding `[include] path=…` → **allowed**; then `git config --get core.hooksPath` / `core.fsmonitor` resolved the attacker values. The `includeIf."gitdir:…".path` variant resolved identically. Reproduced by lead auditor and adversarial verifier independently.

**The host-side detector is also blind.** `ccignore-precommit.py:40` audits with `git config --local --list`, which **does not expand includes** — so the parser (`:47-52`) sees only a benign `include.path=…`. (`git config --local --list --includes` *does* expand them, verified during remediation; the audit simply never ran that form. It is now the form it runs, and `include` is additionally treated as a dangerous section so an include whose target is missing at audit time is still flagged.)

**Host trigger.** Any host git command in the repo. `core.fsmonitor` runs on `git status`/`git add`/`git diff` *before any human review*; `core.hooksPath` hijacks `git commit` **and** routes hook lookup away from `.git/hooks`, so `ccignore-precommit.py` never even runs.

</details>

<details>
<summary><b>C2 — Hardlink defeats the FUSE path-string guard → host RCE + secret read</b></summary>

<br>

**The gap.** FUSE protection is keyed on the **path string**: `_protected`/`_git_sensitive`/`_verdict` all match the *requested path*, and `link()` (`:453-455`) checks only whether the **new name** is masked — never the **source**. A hardlink is a distinct directory entry to the *same inode*, and the VFS does **not** re-resolve it (unlike a symlink, which re-enters FUSE and is correctly blocked). So an unmasked hardlink name aliases a protected inode past every check.

**Live evidence.** `ln .git/config hardconfig` (unmasked name) → permitted; `hardconfig` is byte-identical (same 92-byte backing inode); `os.open("hardconfig", O_WRONLY)` → **permitted**. `write()` has no validation, so bytes land in `.git/config` — a **direct** `core.hooksPath` injection, no include needed. The same alias on a `redact`ed file (`.env`) serves the real inode bytes past the stub → **secret exfiltration** (write-side proven live; read-side code-evident via the identical `read()` path).

**The symlink form was tested and correctly blocked** — the container kernel resolves the symlink to `.git/config` before the FUSE `open`, so the guard sees the real path. Only hardlinks bypass.

</details>

<details>
<summary><b>C3 — Inline <code>[section]key=value</code> parser bypass → host RCE</b></summary>

<br>

**The gap.** `_dangerous_entries` (`:353`) treats any line starting with `[` as a pure section header and `continue`s (`:358-363`), discarding a trailing inline `key=value` on the same line. **Git accepts `[core]hooksPath = …` on one line** (its parser resumes scanning after `]`). So the validator sees no dangerous key while git honors one.

**Live evidence.** `printf '[core] fsmonitor = /tmp/x\n'` → `git config --file f --get core.fsmonitor` returns `/tmp/x`; the real `_dangerous_entries` returns an **empty set** for `[core]hooksPath=`, `[core] fsmonitor=`, `[core]sshCommand=`, `[alias]run=!x` (but correctly catches the normal multi-line form). End-to-end through the live FUSE mount: rename with the normal-form payload → **EACCES**; with the inline form → **permitted**, and `git config --get core.hooksPath` then resolves the injected path.

</details>

<details>
<summary><b>C4 — <code>.gitattributes</code> filter/diff/merge driver via include → host RCE</b></summary>

<br>

**The gap.** Driver definitions (`filter.*.clean/smudge`, `diff.*.command/textconv`, `merge.*.driver`) *are* in `DANGEROUS_GIT_KEYS`, so **direct** definition in `.git/config` is refused. But via the C1 include bypass they can be defined in an included file, and `.gitattributes` (an ordinary, unguarded worktree file) binds paths to them. Git runs the driver command on checkout / diff / merge / archive.

**Live evidence.** Direct `git config filter.audit_x.clean 'echo …'` → **EACCES** (blocked). Via `git config include.path driver.inc` (allowed) + a `driver.inc` defining the drivers + `printf '* filter=audit_x diff=audit_x merge=audit_x' > .gitattributes`: all drivers resolved through `git config --get`, while `git config --local --list` showed nothing (include-blind).

</details>

---

## 🟠 High findings

<details>
<summary><b>H1 — Bare / <code>--separate-git-dir</code> repo config → host RCE</b></summary>

<br>

`_is_git_config` (`:333`) requires `.git` in `parts[:-1]` and `_git_sensitive` (`:338`) requires `.git` in `parts`. `git init --bare store` or `git init --separate-git-dir=gitdir wt` puts config+hooks under a directory **not named `.git`**, so `_protected` returns False and the rename validator (`:428`) never fires. **Live:** `git -C store config core.hooksPath /tmp/evilhooks` → *accepted* and resolved; the identical write into a real `.git` → refused. Host trigger: any host git op against that repo/worktree. The `ccignore-precommit.py` audit only inspects the top repo, so it is blind here too.

</details>

<details>
<summary><b>H2 — gitfile / symlinked <code>.git</code> redirect → host RCE</b></summary>

<br>

Writing `work/.git` as a **file** containing `gitdir: ../store` (a gitfile, CVE-2021-21300 class) is permitted — `_git_sensitive` treats only a literal `.git` *component* as sensitive, so the redirected `store/` gitdir is unguarded. **Live:** `git init --separate-git-dir` produced exactly this; `git -C work config core.fsmonitor store/fsm.sh` (unvalidated) then a bare `git -C work status` **executed the fsmonitor program**. The symlinked-`.git` variant behaves the same.

</details>

<details>
<summary><b>H3 — Shared OAuth token exfiltration over open egress → host credential theft</b></summary>

<br>

`~/.claude-shared/.credentials.json` (0600, **same-uid readable**, a real host bind mount outside FUSE's scope) plus **fully open egress** = the account OAuth token is exfiltrable by any injected session. **Live (no secret read):** `test -r` → readable; `os.open(O_RDONLY)` permitted; TLS egress to arbitrary hosts succeeds. This is the one vector flagged in `CLAUDE.md`'s accepted risks; it is nonetheless *host credential compromise shared across all projects*. **The real lever is egress**, not the mount — Claude needs the token.

</details>

<details>
<summary><b>H4 — Prompt-injection → unattended token exfil (universal enabler)</b></summary>

<br>

By design, injected webpage/repo content runs any in-container command with no consent (`cc:387`; subagents run `--permission-mode bypassPermissions`). The adversarial verifier **upgraded** this from "in-container only": read→exfil of the host token (H3) needs *no additional bypass and no host trigger* — same-uid-readable credential + open egress is the direct, single-vector consequence. It also arms every other host-reaching chain (C1–C4, H5, H8).

</details>

<details>
<summary><b>H5 — Poison shared <code>settings.json</code> → host credential theft + cross-project</b></summary>

<br>

`~/.claude-shared/settings.json` is writable, sits **outside** the FUSE guard, and `docker-entrypoint.sh:95-110` symlinks it into every project and **folds in-session edits back into the shared copy** (`cp -p`, `:106`). No content-validation exists, so `env.ANTHROPIC_BASE_URL` (redirect API traffic + token to an attacker — **CVE-2026-21852** class), `apiKeyHelper` (a command run for a key), and **inline `hooks[].command`** (bypassing the read-only `hooks/` dir) are all accepted and propagate to **every** project's next session. **Live:** the shared dir is writable (verified with a throwaway probe; the real file untouched).

</details>

<details>
<summary><b>H6 — Poison shared <code>plugins</code>/<code>skills</code>/<code>agents</code>/<code>commands</code> → cross-project persistence</b></summary>

<br>

Same shape as H5: these are 0775, writable, symlinked into every project, and — unlike `hooks/` — **not** read-only mounted. Injected skill/command/agent/plugin content runs automatically in every project's next session and, combined with H3, exfiltrates the token. Documented as a known gap in `CLAUDE.md`.

</details>

<details>
<summary><b>H7 — npm/pip install-time RCE arms the host-reaching chains</b></summary>

<br>

The sandbox exists to build untrusted repos; `bypassPermissions` runs `npm install`/`pip install` lifecycle scripts with no prompt. In-container by itself, but it is the **arming vector**: that code can poison git config (C1–C4 → host RCE), read the token (H3), or poison shared settings/assets (H5/H6). Not a bug — the escalation is in the *targets* it can reach.

</details>

<details>
<summary><b>H8 — Wayland clipboard poisoning → host paste RCE / read exfil</b></summary>

<br>

`cc:268` bind-mounts the host Wayland socket **read-write** with no mediation. Intended for host→container *image* paste, but the raw socket grants full bidirectional clipboard control: the container can **write** the clipboard (poison it with terminal-escape / bracketed-paste-bypass sequences — an embedded `ESC[201~` ends "safe paste" early — that execute when you next paste into a host terminal) and **read** it continuously (`wl-paste --watch` → secret exfil). This is a host-side control (your terminal), not fixable from inside the container. Documented accepted risk.

</details>

---

## 🟡 Low / informational

**L1 — Unguarded project `.claude/settings.json` & `.mcp.json`.** `global.ccignore` lists `.vscode`/`.envrc`/`.env*` but **not** `.claude/` or `.mcp.json`, and `cc` doesn't prune/validate project-local Claude autoload files. A malicious repo shipping them gets in-container RCE — but that is **already free** under `--dangerously-skip-permissions`, so marginal impact is ~zero for this threat model. Worth closing only as defense-in-depth against a future host-side `claude` or non-skip-permissions use.

---

## 🟢 Controls verified holding (tested, not assumed)

| Control | Result |
|:--|:--|
| **All classic container-escape CVEs** | Blocked — `CapEff=0`, `CapBnd` lacks `SYS_ADMIN` (`0xcb`), `NoNewPrivs=1`, seccomp mode 2, AppArmor `docker-default` enforce, `/sys` + `/sys/fs/cgroup` (cgroup2) + `/proc/sys` read-only, `/proc/self/exe` non-writable, no docker binary/socket (removes the CVE-2024-21626 trigger). `mount(2)`/`unshare(2)` → EPERM live. |
| **FUSE-sidecar pivot** | Blocked — `SYS_ADMIN` sidecar is in a separate mount+PID namespace, reachable only via FUSE ops; `_real` join is confined, `os.link` doesn't dereference the source, fusepy converts handler faults to `-EINVAL`. |
| **Symlink escape** | Blocked — `readlink` returns the target string only; the main-container kernel re-resolves it (in-mount targets re-enter the guard, out-of-mount reach only already-mounted paths). |
| **Mount-propagation abuse** | Blocked — no `CAP_SYS_ADMIN`, seccomp blocks namespace unshare, `:rslave` is one-directional, sidecar source is isolated. |
| **Host resolver reach** | Blocked — both systemd-resolved Varlink sockets are `/dev/null`-shadowed (`connect()` refused, verified live); source dir read-only; the root `resolv-sync` watcher is unreachable to uid 1000. |
| **`sleep-guard.sh` injection** | Blocked — the one container-originated value reaching a bash-arithmetic sink (`:157`) is sanitized by `awk '$NF + 0'` (`:133`); container/session names reach host command lines only as safely-quoted args. *(Keep that `awk` coercion — it is security-load-bearing.)* |

---

## 🛠 Recommendations

### ✅ `P0` — Close the git-config guard  <sub>fixed C1, C3, C4</sub>

> [!TIP]
> **Stop hand-parsing `.git/config`. Validate it the way git resolves it.** In the sidecar, on a `config` rename, run:
> ```bash
> git config --file <candidate> --list --includes -z
> ```
> and check every **fully-resolved** key against `DANGEROUS_GIT_KEYS`/`DANGEROUS_GIT_SECTIONS`. This inherently handles inline `[section]key=value`, line continuations, quoting, case, and comments (**C3**), and — because `--includes` expands them — `include.path`/`includeIf` (**C1, C4**). As belt-and-braces, also refuse any write that *adds/changes* an `include`/`includeif` directive outright.
>
> Mirror it host-side: change `ccignore-precommit.py:40` from `git config --local --list` to `git config --list --includes` (or explicit `--get-all core.hooksPath|core.fsmonitor|…`) so the detector is no longer include-blind.

### ✅ `P0` — Guard by inode, not path string  <sub>fixed C2</sub>

In `link()` (`:453`), refuse when the **source** is protected/redacted: `_deny_if_masked(source)` plus `_protected(source)` / `_verdict(source)=='redact'` → EACCES. Apply the same source-side check to `rename()` of a protected source. **Structurally stronger:** mount with `default_permissions` so the kernel enforces the real 0600/mode bits, and/or re-apply policy on the opened fd (`fstat`) — so no alias can launder a protected inode into an unprotected name.

### ✅ `P0` — Cover git dirs not named `.git`  <sub>fixed H1, H2</sub>

`_is_git_config`/`_git_sensitive` must recognize git dirs **structurally**, not by the literal `.git` component: refuse writes to any `config`/`hooks` under a directory carrying a git layout (`HEAD`+`objects`+`refs`); treat a non-directory `.git` (gitfile) and a symlinked `.git` as sensitive; and have `ccignore-precommit.py` walk nested/bare/separate gitdirs, not just the top repo.

### ⬜ `P1` — Constrain egress & protect the shared credential  <sub>mitigates H3, H4, H7</sub>

The token can't be made unreadable (Claude needs it) — **egress is the lever.** Default-deny outbound with an allowlist to the Anthropic API only; brokering short-lived scoped tokens host-side (keeping the durable credential out of any container-reachable mount) is the strong form. **Rotate the OAuth token if any untrusted session has run.**

### ⬜ `P1` — Bring the shared config surface under the guard  <sub>fixes H5, H6</sub>

Mount `~/.claude-shared/{settings.json,plugins,skills,agents,commands}` **read-only** into the container (as `hooks/` already is), and rework the entrypoint fold-back to write **per-project** rather than the shared copy. Content-validate any sandbox-writable `settings.json` and refuse `env.ANTHROPIC_BASE_URL`/`ANTHROPIC_API_KEY`, `apiKeyHelper`, and inline `hooks[].command` — the `DANGEROUS_GIT_KEYS` pattern applied to settings.

### ⬜ `P2` — Defense-in-depth

Add `.claude/settings*.json`, `.claude/hooks`, `.mcp.json` to a validated section of the guard (**L1**); interpose a clipboard proxy that permits only host→container image-paste and denies clipboard writes (**H8**); keep the host kernel and `runc` patched.

---

## Prior art & references

This audit's findings are not novel bug classes — they are the **known** AI-coding-agent boundary failures, reproduced against `cc`. The relevant public record:

- **Justin Steven (2022)** — *buried bare repos and `fsmonitor` abuses* — the foundational git-config-indirection advisory · [github.com/justinsteven/advisories](https://github.com/justinsteven/advisories/blob/main/2022_git_buried_bare_repos_and_fsmonitor_various_abuses.md)
- **Pillar Security** — *The Week of Sandbox Escapes* (Cursor / Codex / Gemini CLI / Antigravity) — the exact "sandboxed writer hands executable config to an unsandboxed reader" class · [pillar.security](https://www.pillar.security/blog/the-week-of-sandbox-escapes)
- **Check Point Research** — *RCE & API-token exfiltration through Claude Code project files* — **CVE-2026-21852** (`ANTHROPIC_BASE_URL` leak before trust, fixed v2.0.65) + **CVE-2025-59536** · [research.checkpoint.com](https://research.checkpoint.com/2026/rce-and-api-token-exfiltration-through-claude-code-project-files-cve-2025-59536/) · [GHSA-jh7p-qr78-84p7](https://github.com/advisories/GHSA-jh7p-qr78-84p7)
- **GitHub Copilot CLI** — **CVE-2026-45033 / GHSA-9ccr-r5hg-74gf** — nested bare repo `core.fsmonitor` RCE (H1's analog) · [github.com/github/copilot-cli](https://github.com/github/copilot-cli/security/advisories/GHSA-9ccr-r5hg-74gf)
- **Cobalt.io** — *Red Team Technique: Exploiting Git FSMonitor for Initial Access* · [cobalt.io](https://www.cobalt.io/blog/red-team-technique-exploiting-git-fsmonitor-for-initial-access)
- **CVE-2021-21300** — git symlink + clean/smudge-filter delayed-checkout RCE (C4/H2 class) · [github.blog](https://github.blog/2021-03-09-git-clone-vulnerability-announced/)
- **Cursor 3.0.0 / CVE-2026-48124** — `.claude` hook-config → unsandboxed execution (H5 analog)
- **Cymulate (Apr 2025)** — *Configuration-Based Sandbox Escape* across Claude Code / Gemini CLI / Codex CLI
- **Mitigation precedent** — OpenAI Codex forces `core.fsmonitor=false` on internal git commands · [openai/codex#26880](https://github.com/openai/codex/pull/26880)
- **Pastejacking** (D. Ayrey) & bracketed-paste bypass — the H8 clipboard-to-terminal class · [github.com/dxa4481/Pastejacking](https://github.com/dxa4481/Pastejacking)

---

## Overall assessment

The **container** is hardened to a high standard — every kernel/namespace escape class was tested and blocked. The exposure is entirely at the **host-executed-config boundary the sandbox itself set out to defend**, plus the accepted shared-credential/clipboard surface. The git-config guard is the right idea implemented with two brittle assumptions — *path strings identify inodes* and *hand-parsing equals git's resolution* — each of which is bypassable.

**P0 is now fixed** — the parser follows git's grammar and refuses `include`/`includeIf`, `link()` validates its source inode, and git dirs are recognised by layout. That closes **four Criticals and two Highs**, and the host-executed-config boundary now holds against every chain exercised in this audit. What remains (H3/H5/H6/H8) is the shared-credential, shared-settings and clipboard surface — accepted by design, and closable only by narrowing egress and the shared mounts, not by another guard rule.

---

<sub>**Test-artifact cleanup — done.** Testing left inert `_audit_*` directories under the project (their `.git/config` files cannot be deleted from inside the sandbox — the guard correctly denies `unlink` of `.git/config`, itself a minor note); these were removed host-side after the audit. The real repository `.git/config` was verified **pristine** (original 4 `core.*` keys, no injected/include keys) at audit end.</sub>
