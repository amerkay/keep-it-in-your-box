# Plan — Make `~/.claude` canonical again (drop the split + `migrate-sessions.sh`)

## Context

Today `cc` splits Claude Code's config into `~/.claude-shared/` (login, settings, assets)
and `~/.claude-sandbox/<slug>/` (per-project state), created by a one-time, **destructive**
`migrate-sessions.sh` that deletes `~/.claude` and `~/.claude.json`. That split exists for two
real reasons — Claude's daemon assumes one PID namespace + one `/tmp` per config dir, and a
shared `~/.claude` mounted into every container leaked cross-project transcripts/history — but it
has three costs the user wants gone:

- **Breaks host↔sandbox portability.** After migration, plain `claude` on the host has no
  `~/.claude`; you can't move between the stock CLI and the sandbox.
- **Lock-in.** Remove `cc` and your Claude config is gone/renamed; nothing is stock.
- **A destructive one-time migration** with its own failure modes (torn copy, slug collision).

**Goal:** keep host `~/.claude` (and `~/.claude.json`) **stock and unmodified**, delete
`migrate-sessions.sh`, `~/.claude-shared`, `~/.claude-sandbox`, and the `.migrated` gate — while
**preserving per-project isolation** and hardening the design against future Claude Code layout
changes.

### Decisions locked (from the design discussion)

1. **Path A — keep per-project isolation.** Not the single-shared-container (Path B), which would
   expose every project's source tree to every session.
2. **Isolation is structural, not a denylist filter.** Assemble the container's config dir from an
   **allowlist** of known-safe pieces of `~/.claude`; anything unrecognised falls through to a
   private, container-local base → **unknowns fail closed** (no leak), which is what makes the
   design robust to future Claude Code changes.
3. **Whole-file stores = Hybrid.** `history.jsonl` is **project-private** (courtesy-seeded read
   direction, never merged back). `.claude.json` is **scoped-in at launch + subtree-merged-out at
   exit** (only `projects["<path>"]` written back). **No live FUSE** on either file.
4. **Future-proofing:** default-deny unknowns + a versioned classification manifest / drift canary
   tied to `/etc/claude-code-version`, + cross-project isolation regression probes in
   `security-test.sh`.
5. **Security reality:** baseline (structural dir separation) is marginally stronger; this plan
   recovers most of that by making assembly structural and keeping every existing host-exec guard.

## Design overview

Nothing about the **container side** changes: the container still sees
`CLAUDE_CONFIG_DIR=/home/hostuser/.claude-session` and
`CLAUDE_SECURESTORAGE_CONFIG_DIR=/home/hostuser/.claude-shared` (`cc:310-311`), and
`docker-entrypoint.sh` still farms assets and folds back `settings.json` off those two env vars
(`docker-entrypoint.sh:160-255`). What changes is **what the host binds into those two container
paths and how it's populated** — assembled fresh per launch from canonical `~/.claude`, instead of
from pre-split persistent dirs.

Two host-side dirs replace the split:

- `CLAUDE_HOME="$HOME/.claude"` — **canonical, never restructured.** Source of shared assets,
  credentials, per-project transcripts, and the two whole-file stores.
- `CC_STATE_ROOT` (e.g. `${XDG_STATE_HOME:-$HOME/.local/state}/keep-it-in-your-box`) — cc-owned
  **scratch**: the per-slug assembled bases, the scoped `.claude.json`/`history.jsonl` copies, and
  the lifecycle locks. **Never bind-mounted into the container** (locks stay host-only, preserving
  the never-unlink-from-inside invariant). Ephemeral per launch except where noted.

### Data classification (the allowlist)

| `~/.claude` item | Treatment | Container path | Notes |
|---|---|---|---|
| `settings.json`, `keybindings.json` | bind **rw** (individual) | shared dir | fold-back persists to canonical (shared w/ host) — desired |
| `plugins/`, `skills/`, `agents/`, `commands/`, `hooks/` | bind **ro** (individual) | shared dir | RO = host-exec guard; farmed by entrypoint (unchanged) |
| `.credentials.json` | bind **rw** (individual) | shared dir | one login token, shared w/ host (OAuth refresh persists) |
| `CLAUDE.md` (user global memory) | **assembled**, not farmed | session dir | policy block prepended in-session only (see below) |
| `projects/<slug>/` (this project only) | bind **rw** | session dir | transcripts + `--resume` continuity, host↔sandbox |
| `~/.claude.json` | **scope-in + subtree-merge-out** | session dir `.claude.json` | globals + this project's entry only |
| `history.jsonl` | **project-private** (seed-in, no merge-out) | session dir | this project's lines only; divergence accepted |
| `file-history/` | **container-private** | session dir | avoids UUID-scoping + leak; loses cross-host rewind (v1 trade) |
| `daemon*`, `sessions/`, caches, **anything unrecognised** | **container-private** base | session dir | fail-closed default; never touches canonical |

## The CLAUDE.md win (policy no longer pollutes canonical)

Today `sync_shared_claude_md` (`cc-lib.sh:86-103`) injects the sandbox-policy block into the top of
the shared `CLAUDE.md`. If we shared `~/.claude/CLAUDE.md` directly, host `claude` would wrongly
inherit "you are in a sandbox" policy. Instead: **assemble the session-dir `CLAUDE.md` = policy
block + the user's `~/.claude/CLAUDE.md` content**, written into the private session dir each
launch. Host `~/.claude/CLAUDE.md` stays purely the user's; the policy loads only in-sandbox.
`sync_shared_claude_md` → `assemble_sandbox_claude_md`, and `CLAUDE.md` is dropped from the
entrypoint asset farm/fold-back loop (`docker-entrypoint.sh:178`).

## Concrete changes by file

### `cc` (launcher)

- **Remove** the `.migrated` gate (`cc:107-113`) and both `claude-json.seed` copies (`cc:146`,
  `cc:154`).
- **Replace** the path vars (`cc:80-83`): `CLAUDE_SHARED`/`CLAUDE_SANDBOX`/`SESSION_DIR` →
  `CLAUDE_HOME="$HOME/.claude"`, `CLAUDE_JSON="$HOME/.claude.json"`, `CC_STATE_ROOT=…`,
  `SESSION_DIR="$CC_STATE_ROOT/<slug>"` (scratch base, rebuilt per launch). Locks/state
  (`cc:91-101`) move under `CC_STATE_ROOT/.locks` and `CC_STATE_ROOT/.state`.
- **New `ensure_claude_home`** (replaces `migrate-sessions.sh` bootstrap): if `~/.claude` absent,
  `mkdir` a minimal skeleton so binds don't fail; Claude/first-login populate it. No `.migrated`.
- **New `assemble_session_dir`** (called on the create path, before `start_container` builds ARGS):
  build `$SESSION_DIR` scratch with empty private subdirs (`daemon`, `sessions`, `file-history`);
  `scope-in` `~/.claude.json` → `$SESSION_DIR/.claude.json`; `seed-in` this-project lines of
  `~/.claude/history.jsonl` → `$SESSION_DIR/history.jsonl`; `assemble_sandbox_claude_md` →
  `$SESSION_DIR/CLAUDE.md`. `pin_global_config "$SESSION_DIR/.claude.json"` stays (`cc:166`).
- **Rework the mount block** (`start_container`, around `cc:400-408`): instead of one writable
  `~/.claude-shared` bind + per-asset RO remounts, bind each shared item **individually from
  `~/.claude`** into the container's shared path (`settings.json`/`keybindings.json`/`.credentials.json`
  rw; `plugins`/`skills`/`agents`/`commands`/`hooks` ro), and add a nested rw bind
  `~/.claude/projects/<slug>` → `<session>/projects/<slug>`. The `$SESSION_DIR` scratch is still
  bound to `/home/hostuser/.claude-session` (`cc:302`). Container-side env (`cc:310-311`) unchanged.
- **New `check_claude_home_drift`** (drift canary): before assembly, diff top-level `~/.claude`
  entries against the manifest; `notify()` + log any unrecognised entry ("not exposed to sandbox —
  classify it"), and a stronger note when `/etc/claude-code-version` changed since last recorded.
  Informational only — the default (not exposed) is already safe.
- **Merge-out on exit:** in `teardown_container`/`cleanup` (`cc:252-273`, `cc:489-514`), before
  removing the scratch base, subtree-merge `$SESSION_DIR/.claude.json`'s `projects["<PWD>"]` back
  into `~/.claude.json` under an `flock` (via `lock_fd`). **Skip** for ephemeral
  (`CC_FORCE_NEW_SESSION`) sessions and skip/warn on unparseable scratch json (fail-closed).
- **Ephemeral session** (`cc:138-146`): own scratch base + own scoped `.claude.json`, merge-out
  **disabled** (throwaway), as today.

### `cc-lib.sh`

- Point `validate_shared_settings` (`cc-lib.sh:120-190`, called `cc:125`) at
  `~/.claude/settings.json`; **keep it unchanged otherwise** — it is now more load-bearing.
- `host_has_credential` (`cc-lib.sh:750`) and `start_broker` (`cc-lib.sh:820-841`):
  `$CLAUDE_SHARED/.credentials.json` → `$HOME/.claude/.credentials.json`.
- `sync_shared_claude_md` → `assemble_sandbox_claude_md` (policy + user memory → session dir).
- `pin_global_config`, the redaction trio (`prepare/verify/teardown_redaction`), DNS, clipboard,
  wayland, broker helpers, and `sync_ccignore_gitignore` — **unchanged** (orthogonal to the split).

### `docker-entrypoint.sh`

- Almost unchanged (operates purely off `CLAUDE_CONFIG_DIR`/`CLAUDE_SECURESTORAGE_CONFIG_DIR`).
  Only tweak: **drop `CLAUDE.md`** from the fold-back loop (`:178`) since it's now an
  assembled per-session file, not a shared symlink. The farm (`farm_dir`, `:209-242`) and
  `settings.json`/`keybindings.json` fold-back (`:177-198`) keep working — fold-back now writes
  through to canonical `~/.claude/settings.json` (desired host↔sandbox continuity).

### New helper (one script, python3 — portable, reuses migrate logic)

`claude-config-scope.py` with subcommands, reusing the exact logic already in
`migrate-sessions.sh`:

- `scope-in-json <src ~/.claude.json> <path> <dst>` — globals + `projects[path]` +
  this-project `githubRepoPaths` (mirrors `migrate-sessions.sh:391-399`).
- `merge-out-json <scratch .claude.json> <path> <canonical ~/.claude.json>` — read-modify-write
  **only** the `projects[path]` subtree; leave siblings/globals byte-identical; fail-closed on
  parse error.
- `seed-history <src history.jsonl> <path> <dst>` — filter to `project == path`
  (mirrors `migrate-sessions.sh:309-326`).
- `classify <~/.claude>` — hold the versioned manifest; print unrecognised top-level entries for
  the drift canary. (Manifest lives here, not in bash — avoids `declare -A` / macOS bash-3.2.)

### Deletions

- `migrate-sessions.sh` — **delete**.
- `claude-json.seed` concept and its writer in migration — gone (scope-in replaces it).
- CLAUDE.md references to migration / `.migrated` / the two renamed dirs — update.

### One-time transition for already-migrated users

Existing users have **no `~/.claude`** (migration deleted it). Ship a small, self-deleting
`reverse-migrate.sh` (or `migrate-sessions.sh --reverse` kept only for this) that **reassembles
`~/.claude` + `~/.claude.json`** from `~/.claude-shared` + each `~/.claude-sandbox/<slug>` (inverse
of the existing split: assets/creds → `~/.claude`; per-slug `projects/`, `history.jsonl` rows,
`.claude.json` `projects` entries → merged back). Dry-run by default; refuses while any `cc-*`
container or host `claude` runs (reuse the existing guard, `migrate-sessions.sh:112-130`). After it
runs once, it and the split dirs can be removed.

### `security-test.sh` — cross-project isolation probes

Add to `section "Shared config surface — cross-project pivot (H5, H6)"` (`security-test.sh:257`),
mirroring the `.env` redaction check's "compare, never print" discipline (`:235-254`):

- **Host-side seeding** (before launch, documented step / fixture): create a fake second project
  `~/.claude/projects/<other-slug>/…jsonl` with a `B-sentinel`, a `history.jsonl` line tagged with
  the other project + `B-sentinel`, and a `~/.claude.json` `projects["<other>"]` entry with a
  `B-sentinel` mcpServer. Seed an `A-sentinel` for the current project.
- **In-session asserts** (suite runs inside project A's container, `:95-99`): `deny`/`grep -q`
  that the `B-sentinel` is **absent** from the assembled config dir (`projects/<other-slug>`
  not present; `history.jsonl` lacks it; `.claude.json` lacks the other project) — and `allow`/
  `grep -q` that the **`A-sentinel` IS present** (this project's own transcript/history/entry
  readable). Run under both FUSE modes (`$SINGLE_FUSE`, `:114-119`).

## Security posture (baseline vs this plan)

| Concern | Baseline (split) | This plan (assembled) |
|---|---|---|
| Cross-project transcripts/history | structural (separate dirs) | structural (only `<slug>` bound; unknowns private) |
| Cross-project MCP/secrets (`.claude.json`) | pruned persistent | scope-in + single-subtree merge-out |
| Config blast radius | derived `~/.claude-shared` | canonical `~/.claude` — **larger**; mitigated below |
| Host-exec guard (RO hooks/plugins + `validate_shared_settings`) | present | **kept, unchanged — now more load-bearing** |
| Concurrency race on canonical files | none | merge-out under `flock`; single-subtree write; history not merged |
| Destructive one-time migration | yes | **none** |
| OAuth token / open egress (H3/H4) | accepted | **identical** |

Mitigations that make canonical-`~/.claude` acceptable: (a) **allowlist assembly** — only listed
items are ever exposed; (b) **RO binds** on every host-executed asset + `validate_shared_settings`
each launch; (c) **`flock` + single-subtree** merge-out so an ill-timed host write can't be
clobbered; (d) `~/.claude` is **never bound wholesale** — no path exposes other projects.

## Robustness to future Claude Code updates

1. **Default-deny is the floor:** a new/unknown store is container-private → cannot leak, with zero
   maintenance.
2. **Drift canary:** `classify` flags unrecognised `~/.claude` entries at launch via `notify()`
   (problems-only convention); version-pinned to `/etc/claude-code-version`.
3. **Regression probes:** the cross-project isolation tests above are the net that catches a
   classification bug after any update.
4. **Schema resilience:** the `.claude.json` merge-out copies one subtree verbatim — resilient to
   Claude adding global keys; `history.jsonl` keys on `project` per line (fail-closed to empty if
   the field is renamed, caught by tests).

## Concurrency & interlock

- Merge-out wraps `~/.claude.json` writes in `lock_fd`-based `flock` on `~/.claude.json.lock`.
- Worst case (host `claude` + same-project sandbox writing `.claude.json` at once) loses one
  sandbox-side edit, never corrupts unrelated data (single-subtree). Documented.
- `history.jsonl` project-private → **no** write race at all.
- Optional future hardening: a symmetric `cc --host` group-lock so host and container never run the
  same project's daemon concurrently (out of scope for this plan; noted).

## Edge cases

- **Fresh install (no `~/.claude`):** `ensure_claude_home` skeleton; Claude populates on first run.
- **Ephemeral (`CC_FORCE_NEW_SESSION`):** own scratch + scoped `.claude.json`, **merge-out off**.
- **`file-history` private:** rewind checkpoints are sandbox-local (host↔sandbox rewind seam) — v1
  trade; revisit with UUID-scoped binds if needed.
- **Unknown `~/.claude` entries:** invisible to the sandbox (private base) + surfaced by the canary.

## Verification (host-side — cannot run containers from inside the sandbox)

`bash -n` every touched script first (a syntax error blocks all launches). Then hand the user a
pasteable host block:

```bash
# 1. Static checks
cd /home/kay/keep-it-in-your-box
bash -n cc cc-lib.sh docker-entrypoint.sh reverse-migrate.sh
python3 -m py_compile claude-config-scope.py
./check.sh                      # portability contract (proves macOS paths on Linux)

# 2. Rebuild image (entrypoint change is baked, needs a rebuild)
docker build -t keep-it-in-your-box .

# 3. Host↔sandbox continuity: have a conversation in the sandbox, resume it on the host
./cc claude            # (say something, then exit)
CLAUDE_CONFIG_DIR=$HOME/.claude claude --resume   # the same session must be listed

# 4. Isolation regressions, BOTH modes
./cc ./security-test.sh -k "cross-project"
CC_SINGLE_CONTAINER=1 ./cc ./security-test.sh -k "cross-project"

# 5. .claude.json round-trip: add an MCP server in the sandbox, confirm it lands in ~/.claude.json
#    (and that other projects' entries in ~/.claude.json are byte-unchanged)
```

Confirm: `~/.claude` and `~/.claude.json` are present and unmodified in structure after a session
(only this project's `projects/<slug>` and its `.claude.json` subtree changed); `migrate-sessions.sh`
is gone; a fresh checkout with no `~/.claude` launches cleanly.

## Rollout order

1. `claude-config-scope.py` + unit-test its four subcommands against a fake `$HOME` under the
   scratchpad (`CC_MIGRATE_TEST`-style), never against live `~/.claude`.
2. `cc-lib.sh` path/var + `assemble_sandbox_claude_md` + credential path changes.
3. `cc` assembly/merge-out/drift-canary/mount rework; remove `.migrated` gate + seed copies.
4. `docker-entrypoint.sh` CLAUDE.md drop; rebuild image.
5. `security-test.sh` probes; run both modes.
6. `reverse-migrate.sh`; delete `migrate-sessions.sh`.
7. Update `CLAUDE.md` (this repo) + README to describe canonical-`~/.claude` design.
```
