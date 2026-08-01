# CLAUDE.md

**Keep It in Your Box** — a Docker sandbox for running Claude Code isolated. You are working on
this repo **from inside the sandbox it builds**. Full architecture, rationale, and the history
behind every rule below live in `docs/design-notes/` (see its `README.md` for the map) — read the
named file **before changing a subsystem**; most "obvious simplifications" here are documented dead
ends.

## Layout — the boundary is the tree

```
bin/kib     host entry: verb dispatch and nothing else
host/       runs as YOU, on the host. One file per subsystem, loaded by host/_load.sh
guest/      crosses into a container: baked entrypoints, 3-line shims, policy files
kib/        the one importable package — shared/ (both sides) host/ guest/ broker/
tools/      build-image.sh
tests/      lib.sh + check.sh runner + check/*.sh sections + the pytest suites
```

A file's directory says which side of the trust boundary it is on. `kib/shared/` may not import
`kib.host` or `kib.guest` — that back-edge would drag host-only code into the container.

## Hard constraints — working in this repo

- **No `docker` binary or socket in here.** You cannot build the image or test a container
  end-to-end. Hand host-side commands to the user as a fenced block, pasteable as-is: no `!`
  prefix (that runs *in this container*), no `$` prompts, no placeholders.
- **Canonical `~/.claude` + `~/.claude.json` are LIVE host state** (the stock config a host
  `claude` also uses). kib keeps them untouched and assembles each container from them per launch
  into `$KIB_STATE_ROOT` scratch (`${XDG_STATE_HOME:-~/.local/state}/keep-it-in-your-box`), merging
  this project's slice back out on exit. Never aim destructive logic at canonical — build a fake
  `$HOME` in the scratchpad and test against that. The JSON/JSONL surgery is
  `kib/host/config_scope.py` (unit-tested by `tests/host/test_config_scope.py`).
- **Edits take effect on the next *container*, not the next terminal.** One long-lived container
  serves every terminal on the project; it is recreated only after the *last* session exits. The
  bind-mounted `kib/` package and `guest/bin/resolv-sync.sh` keep running their old code until
  then, and `guest/entrypoint/*` plus the three `guest/bin/` shims are **baked into the image** —
  they need a rebuild, not a relaunch. Before believing a "no change" result, check the
  container's birth time: `ps -o lstart= -p 1` inside it.
- **Editing a host script while a session is LIVE corrupts that running session.** `bash` reads a
  script incrementally by byte offset, so shortening `bin/kib` or a `host/*.sh` under a running
  `kib` makes it resume mid-token — seen as `_mcp_secrets: command not found` for a
  `warn_inline_mcp_secrets` call that is perfectly intact on disk. The same launch also holds the
  OLD sourced bash while `kib_py` execs the NEW bind-mounted python, so an argv contract changed
  on both sides still fails (`merge-out-json needs 3 argument(s), got 4`). Both are fail-closed
  and neither is a bug in the tree: **diagnose from a fresh launch, never from the session the
  edit landed under.** (`container-lifecycle.md`)
- **`bash -n` every script you touch** before finishing — a syntax error leaves the user unable
  to start the sandbox at all.

## Commands

```bash
./dev.sh format               # ruff format + ruff --fix + shfmt -w
./dev.sh lint                 # ruff, mypy --strict, shfmt -d
./dev.sh check                # lint + tests/check.sh — exactly what CI runs
./tests/check.sh              # host-side suite: one section per file in tests/check/
pytest                        # just the Python suites
./tests/security-test.sh      # run INSIDE a sandbox; --list, -k <section>, --no-clipboard
```

Toolchain config is repo-root and shared by editor, container and host; the table of what lives
where, and the pins to keep in step, is in `CONVENTIONS.md`. 100-column lines everywhere.

Security-relevant changes must pass `security-test.sh`, run inside a sandbox.
Image build (host-side): **`kib build`** (or `./tools/build-image.sh`), never a bare
`docker build` — that pins `CLAUDE_VERSION` to the literal string `latest` and poisons Docker's
layer cache forever (`docs/design-notes/architecture.md`).

## The CLI: verbs win over programs

`kib bash` is an **error**, not a shell. Pass-through is explicit — `kib exec bash`. An unknown
first token prints the verb table and never launches anything. `cc` is an alias for `kib claude`,
which is what makes a vendor's `claude mcp add …` line work verbatim after swapping the first
word; everything else is a `kib` verb (`broker`, `mcp`, `audit`, `exec`, `build`, …).

## Portability contract

Host-side scripts (`bin/kib`, `host/*.sh`, `tools/build-image.sh`, …) must be
**bash-3.2/BSD-clean** — stock macOS, no brew. GNU-only tools (`flock`, `setsid`, `sha256sum`, `grep -P`, `notify-send`) and
bash-4isms (`declare -A`, `${var,,}`, `readarray`) are allowed only inside `host/portable.sh`'s
linux branches — call its shims instead (`lock_fd`, `hash8`, `detach_pgrp`, `notify_desktop`).
**All OS branching lives in `host/portable.sh`.** Enforced by `tests/check/portability.sh`, which
also proves the darwin code paths on Linux. Two more clauses it enforces:

- Any array ever assigned `()` expands as `${arr[@]+"${arr[@]}"}`, never bare — bash 3.2 reads an
  empty `"${arr[@]}"` as unbound under `set -u` and aborts the launch.
- `kib/host`, `kib/shared`, `kib/broker` must run on **python 3.9** (stock macOS `python3`): keep
  `from __future__ import annotations` at the top and no 3.10+ runtime API (`zip(strict=)`, …).
  Only `kib/guest` may assume the image's 3.13. (`macos.md`)

Bash reaches Python one way only: `kib_py <module> <args…>` (host/core.sh). Parameters travel in
**argv** — never environment variables, never JSON the shell has to assemble.

## Do not retry — settled dead ends

One line each; the full story is in the `docs/design-notes/` file in parentheses.

- **Never root mount propagation at a path the engine serves as a host file share** — on macOS
  `/tmp`, `/Users`, `/Volumes` and `/private` are virtiofs views of the Mac, and virtiofs has no
  mount namespace for the event to land in. That, not the kernel count, is why kib's old `/tmp`
  root failed there; both containers share the LinuxKit kernel. The root goes inside the engine
  VM (`/run/kib/…`), never `/var` — a symlink to the shared `/private/var`. (`macos.md`)
- **Don't re-split `~/.claude` into a shared + per-project pair** — the destructive migration it
  needs breaks the seamless host⇄box switch (same login, `--resume`, history). Keep canonical
  stock; isolate by per-launch assembly + subtree merge-out. Unknown `~/.claude` entries stay
  container-private (fail-closed). (`container-lifecycle.md`)
- **Never give a user MCP route its own listen port** — one shared listener (8100), routes told
  apart by a `/mcp/<id>` prefix, every bind guarded, user routes fail-soft and named in
  `$BROKER_OUT/broken`. A per-route port with auto-assignment was tried; the number stays
  editable, two defs collided and the unguarded bind took the whole launch down.
  (`credential-broker.md`)
- **Never reintroduce a broker credential refresh loop; never broker `.credentials.json`** —
  rotating single-use refresh tokens logged the whole account out. Static `:ro` token only, for
  every provider. The broker is ON by default (`broker = off` or `KIB_BROKER=0` disables it); a
  first launch with no token auto-runs the login, else falls back to copying the real credential
  in (dir-backed, never a single-file bind — the rename footgun). (`credential-broker.md`)
- **Never name a varlink socket literally in `add_resolv_sync_args`** — runc creates the
  mountpoint and cannot on a `:ro` bind, so `-v /dev/null:<name>` aborts the entire launch the
  moment that socket is absent at create time. Keep every shadow inside the `[ -e ]`-guarded
  glob; the residual (one appearing after create is unshadowed) is caught by `security-test.sh`
  from inside the box and is not fixable by unioning the names in. Regression-guarded.
  (`clipboard-and-dns.md`)
- **Don't collapse `start_broker`'s token-mount walk into `broker_enabled_providers`** — only the
  walk carries the host `basename`, so collapsing widens `_active_providers` to `id|basename`, and
  that same output feeds `broker_config_hash`: the attach-refusal hash shifts for a six-line
  saving on the credential path. Drift is closed by a test instead — `tests/check/mcp.sh`, "both
  walks agree". (`credential-broker.md`)
- **Don't "simplify" `resolv-sync.sh` to overwrite resolv.conf wholesale** — `127.0.0.11` must
  stay first or the `kib-broker` alias breaks mid-session. (`clipboard-and-dns.md`)
- **Never nest a bind inside another bind's destination** — Docker Desktop aborts the whole
  `docker run` (`mountpoint … is outside of rootfs`), and pre-creating the mountpoint does not
  help. Mount flat under `/run/kib/` via `bind_via_link`, or copy the file in. (`macos.md`)
- **`--publish` is 127.0.0.1-only and fixed at creation — don't add a bind address, don't try to
  publish onto a running container.** `-p` exists only on `docker run`, so the attach path refuses
  a port the container lacks instead of starting a session whose failure is indistinguishable from
  a dead dev server. (`container-lifecycle.md`)
- **Don't drop the main container's dual-homing** (`connect_broker_network`) — host dev servers
  and LAN must stay reachable alongside the broker net. (`credential-broker.md`)
- **Don't hide clipboard interfaces from the Wayland registry** — it broke `wl-paste`; sanitise
  the write *content* at the `send` event instead. (`clipboard-and-dns.md`)
- **Never stage the clipboard bridge's output in the spool** — it is bind-mounted rw, so a `>`
  there follows a symlink the box planted (any host file truncated and overwritten) and a re-open
  is a TOCTOU that lands unsanitised bytes on the real pasteboard. Build every answer in
  `$DIR.priv` and `mv` it in. (`clipboard-and-dns.md`)
- **Don't refuse clipboard writes outright, and don't gate them on who is asking** — refusal
  broke the fullscreen TUI's select-to-copy, and the sidecar's own PID namespace makes
  `SO_PEERCRED` useless (pid 0). The content is the boundary. (`clipboard-and-dns.md`)
- **Don't wrap `google-chrome` image-wide with `--no-sandbox`** — the entrypoint's `npx` shim
  already makes the stock `chrome-devtools-mcp` plugin launch a browser; a Dockerfile wrapper is
  redundant, needs a rebuild, and disarms every other Chrome caller. (`terminal-and-security.md`)
- **Sleep guard: Claude's own hook state, never a measurement of output** — byte sampling
  (`wchar`), transcript mtime and `claude agents --json` were each tried and each removed. A
  background subagent writes almost nothing to the terminal, so any output-volume metric sleeps
  the machine mid-work, and a question waiting on the user is indistinguishable from a long
  think. The verdict is `kib_sleep_state`, SOURCED by both the guard and the diagnostic — never
  copy it. Keep the poll free of subprocesses: no `docker exec`, no CLI, markers or nothing.
  Don't switch the inhibitor to `--what=idle` (kills lid-shut tasks); keep the post-resume
  SETTLE window (re-suspend wedged s2idle); keep `--who` a space-free `claude-code` token (the
  diagnostic reads the PID by field offset). (`sleep-guard.md`)
- **Don't re-enable `leftArrowOpensAgents`, and don't re-investigate the ←-key data loss** — the
  sandbox is exonerated; it's the binary's abort-then-fork. Keep the pin. (`terminal-and-security.md`)
- **Don't re-pin the box's config dir to a fixed `/home/hostuser` spelling** — it mounts at the
  host's OWN `~/.claude` (`/home/kay/.claude`, `/Users/veronica/.claude`). Claude records plugin
  paths absolute and *validates* them against the running config dir, so any other spelling
  makes it reject the state canonical hands it. Same path both sides = nothing to translate;
  translating per field instead was tried and thrown away. (`redaction-config-guard.md`)
- **No `tput reset`** (regression-guarded); keep `|| true` on `tput cols`/`lines` and `read`.
  (`terminal-and-security.md`)
- **FUSE passthrough I/O is `os.pread`/`os.pwrite`, never `lseek`+`read`** — the shared fd offset
  truncates reads at a chunk boundary, and it surfaces as unexplained lint/test flakiness rather
  than an I/O error. Regression-guarded. (`redaction-config-guard.md`)
- **The FUSE view's speed rests on three things — don't undo one.** `auto_cache` (never
  `kernel_cache`: the host edits this tree), the memoised `_verdict` (cache the RULE verdict only,
  never `_classify` — its `lexists` must stay live), and a `flush()` that does not `fsync`. Together
  they took a small file from 2.31 ms to 0.067 ms. **`FUSE_PASSTHROUGH` is not the next step**: it
  needs kernel 6.9+ (Ubuntu 24.04 GA is 6.8, WSL2 is 5.15/6.6) and libfuse 3.17 low-level, and
  fusepy is ctypes over libfuse **2**. Regression-guarded. (`redaction-config-guard.md`)
- **Never `kill -TERM "-$pid"` from a pidfile — call `kill_pgrp`**, and never require `KIB_ROOT`
  from the environment in an *executed* host script (`detach_pgrp` gives it a fresh env; derive it
  from `$0`). A dead detached child's pid gets recycled into the next launch's own process group,
  so the stale pidfile made kib SIGTERM itself right after the banner: silent, no container, looks
  exactly like a `set -e` abort. Both regression-guarded. (`container-lifecycle.md`)
- **Never unlink lock files**, and every backgrounded host process must close fds 200/201
  (`200>&- 201>&-`) — one miss strands every project's containers. (`container-lifecycle.md`)
- **The host-executed-config guard is two tiers, split by WHEN a file fires — ambient trigger vs
  deliberate `claude` launch** — `[protect]` refuses the write and the policy text tells the session
  to stop, so a rule is only worth it where no report could arrive in time (`.git/hooks`, `.envrc`,
  `.vscode`: a commit, a `cd`, an editor-open). Everything that waits for someone to launch
  `claude` — `.claude/settings*.json`, `.claude/hooks/`, `.claude-plugin/`, `.mcp.json`,
  `mise.toml` — is *detected* by `audit_project_configs`. Don't promote one: rename-validation only
  works for temp+rename writers, so a `[protect]` on `.claude/settings.json` breaks Claude's own
  "always allow" with nothing to replace it, and the `[protect]` on `.claude/hooks` refused the
  script while the pointer arming it stayed writable. A tree-shaped detector must union git with an
  **mtime stamp** — the box can commit past a dirty-file filter. (`redaction-config-guard.md`)
- **A nested `[protect]` write is allowed only as a byte-identical copy of the same guarded tail
  at the project ROOT — never carve out a worktree dir or an "editor config" tier.** That was
  tried (`feat/worktree-editor-carveout`, reverted) and is bypassable with zero detection: the box
  can `git commit`, so it decides what "tracked" means, and a committed `.vscode/tasks.json`
  checks out pristine past a dirty-file detector. The anchor stays immutable; that is what makes a
  copy of it safe. (`redaction-config-guard.md`)
- **Don't add a `[mask]` section — `[redact]` is format-aware** — JSON and `.env*` read as keys
  with values replaced, everything else keeps the stub. Making it a policy choice needs a third
  verdict, a precedence table and an enable path, and lets a hostile repo pick the leakier
  renderer for its own paths. Format is a property of the file. (`redaction-config-guard.md`)
- **Shared assets are ONE open tier — don't re-lock `plugins`/`hooks`, and don't "harden" the tier
  by refusing scripts** — all five are rw and symlinked at canonical so authoring or installing one
  shares it. The `:ro` lock cost ~460 lines (mount-mode flag, lock witness, attach refusal, the
  per-project plugin farm) and never covered `~/.claude/skills/x/.claude-plugin/plugin.json`, which
  auto-loads as a plugin with no install step. It is `asset_scan` detection now, at teardown and
  only when a native `claude` exists; the accepted residual is cross-project auto-execution (audit
  H6, Accepted). The vetting line is auto-execution (a `hooks`/`mcpServers`/`lspServers`/`monitors`
  `command`), never the exec bit or a `#!`: most real skills ship a helper script, so that rule
  flags `skills/` on first contact and buys nothing a prose "run this" wouldn't.
  (`redaction-config-guard.md`)
- **Don't move the sandbox policy back into the assembled `CLAUDE.md`** — bound `:ro` at
  `/etc/claude-code/CLAUDE.md` it outranks user memory, survives a repo's `claudeMdExcludes` and
  cannot be edited from the box; the config-dir copy had none of the three.
  (`container-lifecycle.md`)
- **Don't put a hook back into the user's repos.** The checks live in `host/gitguard.sh` +
  `kib/host/gitaudit.py`, run at cold start, at teardown and on `kib audit`. Why a hook is not an
  option is in `kib/host/gitaudit.py`'s docstring. (`redaction-config-guard.md`)
- **Don't set `PYTHONPATH` in the image** — it would leak into every process the agent runs. The
  guest shims set it for their own exec only. Regression-guarded.
- **`daemon.log` noise is benign**: `bg adopt … dead=N`, `idle 5s … exiting`,
  `bg settled (killed)` — don't investigate them again. (`terminal-and-security.md`)
- **`notify()` is for problems only** — never add a launch-success notification. (`clipboard-and-dns.md`)

## Conventions

- Conventional commit style. Never commit unless asked.
- **Commit straight to `main` — never create a branch.** Solo repo, no PR flow; a branch only
  adds a merge step to undo.
- Keep the relevant `docs/design-notes/` file updated in the same change as the behaviour or
  rationale. Its `README.md` is the map.
