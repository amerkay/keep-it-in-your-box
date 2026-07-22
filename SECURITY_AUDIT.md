# Security Audit — `cc` Claude Code Sandbox

**Date:** 2026-07-22
**Scope:** The `cc` Docker sandbox in this repository (`cc`, `cc-lib.sh`, `docker-entrypoint.sh`, `Dockerfile`, `ccignore-fuse.py`, `global.ccignore`, `ccignore-precommit.py`, `resolv-sync.sh`, `sleep-guard.sh`).
**Question asked:** *Can a malicious script, webpage, or github repo driving this session escape the sandbox and execute code on the host?*
**Method:** Static analysis of every control + **live exploitation testing from inside a running sandbox**, each finding independently re-verified by an adversarial second pass.

---

## Bottom line

**Yes — host code execution is achievable, and so is theft of the host OAuth token.** Six confirmed paths reach the host, four of them rated **Critical**. The container hardening itself is excellent (all classic container-escape CVEs are blocked), but the sandbox's own stated boundary — *"what the host runs later"* — has multiple holes in the **git-config guard**, and the shared credential/settings surface is exfiltrable by design.

The most important chains fire on the **host's next `git status` / `git add` / `git commit`** in the project — i.e. the exact commands you run to *review the sandbox's diff before trusting it*. `core.fsmonitor` executes in-process on a bare `git status`, **before a human sees anything**, and a redirected `core.hooksPath` bypasses the repo's own `ccignore-precommit.py` guard hook. The review step the whole model relies on is where the payload detonates.

| # | Finding | Severity | Host impact | Status |
|---|---------|----------|-------------|--------|
| C1 | `git config include.path` / `includeIf.*.path` indirection | **Critical** | Host RCE | Confirmed (live, ×3) |
| C2 | Hardlink defeats FUSE `protect`/`redact` (path-string guard) | **Critical** | Host RCE + secret read | Confirmed (live, ×2) |
| C3 | Inline `[section]key=value` parser bypass of the config validator | **Critical** | Host RCE | Confirmed (live) |
| C4 | `.gitattributes` filter/diff/merge driver via include bypass | **Critical** | Host RCE | Confirmed (live) |
| H1 | Bare / `--separate-git-dir` repo config (dir not named `.git`) | High | Host RCE | Confirmed (live) |
| H2 | gitfile / symlinked `.git` redirect to unguarded gitdir | High | Host RCE | Confirmed (live) |
| H3 | Shared OAuth token exfiltration over open egress | High | Host credential theft | Confirmed (live) |
| H4 | Prompt-injection → unattended token exfil (universal enabler) | High | Host credential theft | Confirmed (live) |
| H5 | Poison shared `settings.json` (`ANTHROPIC_BASE_URL`/`apiKeyHelper`/inline hooks) | High | Host credential theft + cross-project | Confirmed (live) |
| H6 | Poison shared `plugins`/`skills`/`agents`/`commands` | High | Cross-project persistence | Confirmed (live) |
| H7 | npm/pip install-time RCE arms the host-reaching chains | High | Host credential theft (chained) | Confirmed |
| H8 | Wayland clipboard poisoning → host paste RCE / read exfil | High | Host RCE (on paste) | Confirmed (mechanism) |
| L1 | Unguarded project `.claude/settings.json` & `.mcp.json` autoload | Low | In-container only | Confirmed |
| — | Container-escape CVEs, FUSE-sidecar pivot, symlink escape, mount-propagation, host-resolver reach, sleep-guard injection | Info | None | **Verified blocked** |

---

## Threat model

The sandbox launches `claude --dangerously-skip-permissions` (`cc:387`), so **in-container code execution from injected content is expected and accepted** — the container *is* the boundary. A malicious webpage or repo can already run any command inside the container with no consent prompt. This audit therefore measures only what escapes that boundary: **host code execution, host credential theft, and cross-project persistence.** In-container-only effects are not counted as findings.

## Methodology

1. **Recon** (15 parallel agents): mapped 72 distinct controls across the 7 subsystems, and swept published Claude Code / AI-coding-agent / container-escape / git-indirection / MCP / Wayland CVEs and disclosures (118 candidate vectors).
2. **Exploit testing** (19 vectors × test + adversarial-verify = 38 agents, ~1.85M tokens): each vector was **actually executed against a live sandbox**, then a second agent tried to *refute* the verdict. Git tests ran in isolated `_audit_<id>/` subdirectories (still under the live FUSE guard) to avoid touching the real `.git/config`.
3. All testing was **non-destructive**: exploitability was proven via config *resolution* (`git config --get`), write-*open* permitted (fd opened, nothing written), `stat`, or reading resolved state — never by executing code on the host or reading a real secret.

---

## Critical findings

### C1 — `git config include.path` / `includeIf.*.path` indirection → host RCE

**The guard.** `.git/config` is content-validated on write: `ccignore-fuse.py:_dangerous_entries` (`:352`) parses the file and `_git_config_write_ok` (`:372`) refuses any *new* entry whose key is in `DANGEROUS_GIT_KEYS` (`:41`, e.g. `hooksPath`, `fsmonitor`, `sshCommand`). Directly setting `core.hooksPath` is correctly refused.

**The gap.** `include`/`includeif`/`path` are **not** in the danger set, and the validator inspects only the *literal* text — it never resolves includes. So `git config include.path <file>` passes validation, and the pointed-to file (writable: only `config`/`hooks` are masked under `.git`, or any ordinary worktree file) declares `[core] hooksPath = …`. Git resolves it fully.

**Live evidence.** In an isolated guard-covered gitdir: a `mv` (rename = the write) of a config containing `[core] hooksPath` → **EACCES** (validator held); the same rename adding `[include] path=…` → **allowed**; then `git config --get core.hooksPath` / `core.fsmonitor` resolved the attacker values (`/tmp/EVIL_HOOKS_INC`, `/tmp/EVIL_FSMON_INC`). The `includeIf."gitdir:…".path` variant resolved identically. Reproduced by the lead auditor and by the adversarial verifier independently.

**Host-side detector is also blind.** `ccignore-precommit.py:40` audits with `git config --local --list`, which **does not expand includes** — output shows only `include.path=…`, and the parser (`:47-52`) treats `include`/`path` as benign. (`git config --list` *would* expand them, but the audit never runs that form.)

**Host trigger.** Any host git command in the repo. `core.fsmonitor` runs on `git status`/`git add`/`git diff` (your diff-review commands) *before any human review*; `core.hooksPath` hijacks `git commit` **and** routes hook lookup away from `.git/hooks`, so the `ccignore-precommit.py` guard hook never even runs.

**Root cause:** `ccignore-fuse.py:41` (`DANGEROUS_GIT_KEYS` omits `include`/`includeif`/`path`) + `:352` (`_dangerous_entries` never resolves includes); `ccignore-precommit.py:40` (`--local --list` is include-blind).

---

### C2 — Hardlink defeats the FUSE path-string guard → host RCE + secret read

**The gap.** FUSE protection is keyed on the **path string**: `_protected`/`_git_sensitive`/`_verdict` (`:133-167`, `:337-350`) all match the requested path, and `link()` (`:453-455`) checks only whether the **new name** is masked — never the **source**. A hardlink is a distinct directory entry to the *same inode*, and the VFS does **not** re-resolve it (unlike a symlink, which correctly re-enters FUSE and is blocked). So an unmasked hardlink name aliases a protected inode past every check.

**Live evidence.** `ln .git/config hardconfig` (unmasked target name) → permitted; `hardconfig` is byte-identical (same 92-byte backing inode); `os.open("hardconfig", O_WRONLY)` → **permitted** (guard sees the unmasked name). `write()` has no validation, so bytes land in `.git/config` — a **direct** `core.hooksPath` injection, no include needed. The same alias on a `redact`ed file (`.env`) serves the real inode bytes past the stub → **secret exfiltration** (code-evident via the identical `read()` path; write-side proven live).

The symlink form was **tested and correctly blocked** — the container kernel resolves the symlink to `.git/config` before the FUSE `open`, so the guard sees the real path. Only hardlinks bypass.

**Root cause:** `ccignore-fuse.py:453-455` `link()` validates the target, not the source; the guard identifies inodes by path string rather than by inode/mode.

---

### C3 — Inline `[section]key=value` parser bypass → host RCE

**The gap.** `_dangerous_entries` (`:352`) treats any line starting with `[` as a pure section header and `continue`s (`:360-363`), discarding a trailing inline `key=value` on the same line. **Git accepts `[core]hooksPath = …` on one line** (its parser resumes scanning after `]`). So the validator sees no dangerous key while git honors one.

**Live evidence.** `printf '[core] fsmonitor = /tmp/x\n'` → `git config --file f --get core.fsmonitor` returns `/tmp/x`; the real `Redact._dangerous_entries` returns an **empty set** for `[core]hooksPath=`, `[core] fsmonitor=`, `[core]sshCommand=`, `[alias]run=!x` (but correctly catches the normal multi-line form). End-to-end through the live FUSE mount: a rename with the normal-form payload → **EACCES**; with the inline-form payload → **permitted**, and `git config --get core.hooksPath` then resolves the injected path.

**Root cause:** `ccignore-fuse.py:360-363` — hand-rolled parser diverges from git's grammar for inline section forms.

---

### C4 — `.gitattributes` filter/diff/merge driver via include → host RCE

**The gap.** Driver definitions (`filter.*.clean/smudge`, `diff.*.command/textconv`, `merge.*.driver`) *are* in `DANGEROUS_GIT_KEYS`, so **direct** definition in `.git/config` is refused. But via the C1 include bypass they can be defined in an included file, and `.gitattributes` (an ordinary, unguarded worktree file) binds paths to them. Git runs the driver command on checkout / diff / merge / archive.

**Live evidence.** Direct `git config filter.audit_x.clean 'echo …'` → **EACCES** (blocked). Via `git config include.path driver.inc` (allowed) + a `driver.inc` defining the filter/diff/merge drivers + `printf '* filter=audit_x diff=audit_x merge=audit_x' > .gitattributes`: all drivers resolved through `git config --get`, while `git config --local --list` showed nothing (include-blind).

**Root cause:** same as C1 (`ccignore-fuse.py:41`/`:352` don't resolve includes) — `.gitattributes` is an additional trigger surface even for keys the direct-write validator does catch.

---

## High findings

### H1 — Bare / `--separate-git-dir` repo config (git dir not named `.git`) → host RCE
`_is_git_config` (`:333`) requires `.git` in `parts[:-1]` and `_git_sensitive` (`:337`) requires `.git` in `parts`. A `git init --bare store` or `git init --separate-git-dir=gitdir wt` puts config+hooks under a directory **not named `.git`**, so `_protected` returns False and the rename validator (`:430`, gated on `_is_git_config`) never fires. **Live:** `git -C store config core.hooksPath /tmp/evilhooks` → *accepted* and resolved; the identical write into a real `.git` → refused. Host trigger: any host git op against that repo/worktree (`git status` fires `core.fsmonitor`). The `ccignore-precommit.py` audit only inspects the top repo, so it's blind here too.

### H2 — gitfile / symlinked `.git` redirect → host RCE
Writing `work/.git` as a **file** containing `gitdir: ../store` (a gitfile, CVE-2021-21300 class) is permitted — `_git_sensitive` treats only a literal `.git` *component* as sensitive, so the redirected `store/` gitdir is unguarded. **Live:** `git init --separate-git-dir` produced exactly this; `git -C work config core.fsmonitor store/fsm.sh` (unvalidated) then a bare `git -C work status` **executed the fsmonitor program**. Symlinked-`.git` variant behaves the same.

### H3 — Shared OAuth token exfiltration over open egress → host credential theft
`~/.claude-shared/.credentials.json` (0600, **same-uid readable**, a real host bind mount outside FUSE's scope) plus **fully open egress** = the account OAuth token is exfiltrable by any injected session. **Live (no secret read):** `test -r` → readable; `os.open(O_RDONLY)` permitted; TLS egress to arbitrary hosts succeeds. This is the one vector flagged in `CLAUDE.md`'s accepted risks; it is nonetheless *host credential compromise shared across all projects*. The real lever is **egress**, not the mount (Claude needs the token).

### H4 — Prompt-injection → unattended token exfil (universal enabler)
By design, injected webpage/repo content runs any in-container command with no consent (`cc:387`; subagents run `--permission-mode bypassPermissions`). The adversarial verifier **upgraded** this from "in-container only": read→exfil of the host token (H3) needs *no additional bypass and no host trigger* — same-uid readable credential + open egress is the direct, single-vector consequence. It also arms every other host-reaching chain (C1–C4, H5, H8).

### H5 — Poison shared `settings.json` → host credential theft + cross-project
`~/.claude-shared/settings.json` is writable, sits **outside** the FUSE guard, and `docker-entrypoint.sh:95-110` symlinks it into every project and **folds in-session edits back into the shared copy** (`cp -p`, `:106`). No content-validation exists, so `env.ANTHROPIC_BASE_URL` (redirect API traffic + token to an attacker, CVE-2026-21852 class), `apiKeyHelper` (a command run for a key), and **inline `hooks[].command`** (bypassing the read-only `hooks/` dir) are all accepted and propagate to **every** project's next session. **Live:** the shared dir is writable (verified with a throwaway probe; the real file untouched).

### H6 — Poison shared `plugins`/`skills`/`agents`/`commands` → cross-project persistence
Same shape as H5: these are 0775, writable, symlinked into every project, and — unlike `hooks/` — **not** read-only mounted. Injected skill/command/agent/plugin content runs automatically in every project's next session and, combined with H3, exfiltrates the token. Documented as a known gap in `CLAUDE.md`.

### H7 — npm/pip install-time RCE arms the host-reaching chains
The sandbox exists to build untrusted repos; `bypassPermissions` runs `npm install`/`pip install` lifecycle scripts with no prompt. In-container by itself, but it is the **arming vector**: that code can poison git config (C1–C4 → host RCE), read the token (H3), or poison shared settings/assets (H5/H6). Not a bug — the escalation is in the *targets* it can reach.

### H8 — Wayland clipboard poisoning → host paste RCE / read exfil
`cc:268` bind-mounts the host Wayland socket **read-write** with no mediation. Intended for host→container *image* paste, but the raw socket grants full bidirectional clipboard control: the container can **write** the clipboard (poison it with terminal-escape / bracketed-paste-bypass sequences that execute when you next paste into a host terminal) and **read** it continuously (`wl-paste --watch` → secret exfil). This is a host-side control (your terminal), not fixable from inside the container. Documented accepted risk.

---

## Low / informational

**L1 — Unguarded project `.claude/settings.json` & `.mcp.json`.** `global.ccignore` lists `.vscode`/`.envrc`/`.env*` but **not** `.claude/` or `.mcp.json`, and `cc` doesn't prune/validate project-local Claude autoload files. A malicious repo shipping them gets in-container RCE — but that's **already free** under `--dangerously-skip-permissions`, so marginal impact is ~zero for this threat model. Worth closing only as defense-in-depth against a future host-side `claude` or non-skip-permissions use.

## Controls verified holding (tested, not assumed)

- **All classic container-escape CVEs are blocked** (`cesc-cve`): `CapEff=0`, `CapBnd` lacks `SYS_ADMIN` (`0xcb`), `NoNewPrivs=1`, seccomp mode 2, AppArmor `docker-default` enforce, `/sys` + `/sys/fs/cgroup` (cgroup2) + `/proc/sys` read-only, `/proc/self/exe` non-writable, no docker binary/socket (removes the CVE-2024-21626 trigger surface). `mount(2)`/`unshare(2)` → EPERM live.
- **FUSE-sidecar pivot blocked** (`fuse-pivot`): the SYS_ADMIN sidecar is in a separate mount+PID namespace, reachable only via FUSE ops; `_real` join is confined, `os.link` doesn't dereference the source, and fusepy converts handler faults to `-EINVAL` (no server crash).
- **Symlink escape blocked** (`fuse-symlink`): `readlink` returns the target string only; the main-container kernel re-resolves it — in-mount targets re-enter the guard, out-of-mount targets reach only already-mounted paths.
- **Mount-propagation abuse blocked** (`mount-prop`): no `CAP_SYS_ADMIN`, seccomp blocks namespace unshare, `:rslave` is one-directional, sidecar source is isolated.
- **Host resolver unreachable** (`resolver`): both systemd-resolved Varlink sockets are `/dev/null`-shadowed (`connect()` refused, verified live); the source dir is read-only; the root `resolv-sync` watcher is unreachable to uid 1000.
- **`sleep-guard.sh` injection blocked** (`sleep-guard`): the one container-originated value reaching a bash-arithmetic sink (`:157`) is sanitized by `awk '$NF + 0'` (`:133`); container/session names reach host command lines only as safely-quoted host-generated args. *(Keep that `awk` coercion — it is security-load-bearing.)*

---

## Recommendations (prioritized)

### P0 — Close the git-config guard (fixes C1, C3, C4, and the direct half of C2)
**Stop hand-parsing `.git/config`. Validate it the way git resolves it.** In the sidecar, on a `config` rename, run:

```
git config --file <candidate> --list --includes -z
```

and check every **fully-resolved** key against `DANGEROUS_GIT_KEYS`/`DANGEROUS_GIT_SECTIONS`. This inherently handles inline `[section]key=value`, line continuations, quoting, case, comments (**C3**), and — because `--includes` expands them — `include.path`/`includeIf` (**C1, C4**). As belt-and-braces, also refuse any write that *adds/changes* an `include`/`includeif` directive outright.
Mirror it host-side: change `ccignore-precommit.py:40` from `git config --local --list` to `git config --list --includes` (or explicit `--get-all core.hooksPath|core.fsmonitor|…`) so the detector is no longer include-blind.

### P0 — Guard by inode, not path string (fixes C2)
In `link()` (`:453`), refuse when the **source** is protected/redacted: `self._deny_if_masked(source)` plus `_protected(source)` / `_verdict(source)=='redact'` → EACCES. Apply the same source-side check to `rename()` of a protected source. **Structurally stronger:** mount with `default_permissions` so the kernel enforces the real 0600/mode bits, and/or re-apply policy on the opened fd (`fstat`), so no alias can launder a protected inode into an unprotected name.

### P0 — Cover git dirs not named `.git` (fixes H1, H2)
`_is_git_config`/`_git_sensitive` must recognize git dirs structurally, not by the literal `.git` component. Options: refuse writes to any `config`/`hooks` under a directory containing a git repo layout (`HEAD`+`objects`+`refs`); treat a non-directory `.git` (gitfile) and a symlinked `.git` as sensitive; and have `ccignore-precommit.py` walk nested/bare/separate gitdirs, not just the top repo.

### P1 — Constrain egress and protect the shared credential (mitigates H3, H4, H7)
The token can't be made unreadable (Claude needs it) — **egress is the lever.** Default-deny outbound with an allowlist to the Anthropic API only; brokering short-lived scoped tokens host-side (keeping the durable credential out of any container-reachable mount) is the strong form. Rotate the OAuth token if any untrusted session has run.

### P1 — Bring the shared config surface under the guard (fixes H5, H6)
Mount `~/.claude-shared/{settings.json,plugins,skills,agents,commands}` **read-only** into the container (as `hooks/` already is), and rework the entrypoint fold-back to write **per-project** rather than the shared copy. Content-validate any sandbox-writable `settings.json` and refuse `env.ANTHROPIC_BASE_URL`/`ANTHROPIC_API_KEY`, `apiKeyHelper`, and inline `hooks[].command` — the `DANGEROUS_GIT_KEYS` pattern applied to settings.

### P2 — Defense-in-depth
Add `.claude/settings*.json`, `.claude/hooks`, `.mcp.json` to a validated section of the guard (L1); interpose a clipboard proxy that permits only host→container image-paste and denies clipboard writes (H8); keep the host kernel and `runc` patched.

---

## Cleanup required (host-side)

Testing left inert `_audit_*` directories in the project. Their `.git/config` files **cannot be deleted from inside the sandbox** — the guard denies `unlink` of `.git/config` (a correct behavior, and itself a minor note: a sandbox can create git dirs it can't self-clean). The two remaining `include.path` references point to files already deleted (git ignores missing includes) and no `/tmp` payloads exist, so they are harmless. Remove them from a **host terminal**:

```
rm -rf /home/kay/claude-docker/_audit_*
```

The real repository `.git/config` was verified **pristine** (original 4 `core.*` keys, no injected/include keys) at audit end.

---

## Overall assessment

The **container** is hardened to a high standard — every kernel/namespace escape class was tested and blocked. The exposure is entirely at the **host-executed-config boundary the sandbox itself set out to defend**, plus the accepted shared-credential/clipboard surface. The git-config guard is the right idea implemented with two brittle assumptions — *path strings identify inodes* and *hand-parsing equals git's resolution* — each of which is bypassable. Fixing P0 (validate via `git config --includes`, guard by inode, cover non-`.git` gitdirs) closes four Criticals and two Highs and would make the boundary genuinely hold.
