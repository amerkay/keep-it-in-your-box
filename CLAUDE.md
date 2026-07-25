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
- **`bash -n` every script you touch** before finishing — a syntax error leaves the user unable
  to start the sandbox at all.

## Commands

```bash
./dev.sh format               # ruff format + ruff --fix + shfmt -w
./dev.sh lint                 # ruff, mypy --strict, shfmt -d
./dev.sh check                # lint + tests/check.sh — exactly what CI runs
./tests/check.sh              # host-side suite: syntax, shellcheck, portability, wiring, pytest
pytest                        # just the Python suites
./tests/security-test.sh      # run INSIDE a sandbox; --list, -k <section>, --no-clipboard
```

Toolchain config is repo-root and shared by editor, container and host: `pyproject.toml` (ruff
+ mypy `strict` + pytest), `.editorconfig` (shfmt's config too — pass it **no** style flags or it
ignores the file, and name every extensionless script in it or shfmt silently uses tabs for that
one file), 100-column lines everywhere. Versions are pinned in `requirements-dev.txt` and in the
Dockerfile's `ARG SHFMT_VERSION` / `ARG SHELLCHECK_VERSION`; keep the latter in step with
`.github/workflows/lint.yml`. Conventions live in `CONVENTIONS.md`.

Security-relevant changes must pass `security-test.sh` in **both** redaction modes: once
normally, once with the container launched under `KIB_SINGLE_CONTAINER=1` (the macOS topology).
Image build (host-side): **`kib build`** (or `./tools/build-image.sh`) — run it directly and it
streams the build and exits non-zero on failure; kib backgrounds the same script for the upgrade
prompt. Do **not** use a bare `docker build`: `CLAUDE_VERSION` then stays the literal string
`latest`, Docker keys its cache on that string rather than what it resolves to, so the install
layer is reused forever, the image keeps an old Claude, and kib prompts for the same upgrade every
launch. `build-image.sh` resolves the version number first, which is what busts that cache.

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
also proves the darwin code paths on Linux.

Bash reaches Python one way only: `kib_py <module> <args…>` (host/core.sh). Parameters travel in
**argv** — never environment variables, never JSON the shell has to assemble.

## Do not retry — settled dead ends

One line each; the full story is in the `docs/design-notes/` file in parentheses.

- **Don't re-split `~/.claude` into a shared + per-project pair** — the destructive migration it
  needs breaks the seamless host⇄box switch (same login, `--resume`, history). Keep canonical
  stock; isolate by per-launch assembly + subtree merge-out. Unknown `~/.claude` entries stay
  container-private (fail-closed). (`container-lifecycle.md`)
- **Never reintroduce a broker credential refresh loop; never broker `.credentials.json`** —
  rotating single-use refresh tokens logged the whole account out. Static `:ro` token only, for
  every provider. The broker is ON by default (`broker = off` or `KIB_BROKER=0` disables it); a
  first launch with no token auto-runs the login, else falls back to copying the real credential
  in (dir-backed, never a single-file bind — the rename footgun). (`credential-broker.md`)
- **Don't "simplify" `resolv-sync.sh` to overwrite resolv.conf wholesale** — `127.0.0.11` must
  stay first or the `kib-broker` alias breaks mid-session. (`clipboard-and-dns.md`)
- **Don't drop the main container's dual-homing** (`connect_broker_network`) — host dev servers
  and LAN must stay reachable alongside the broker net. (`credential-broker.md`)
- **Don't hide clipboard interfaces from the Wayland registry** — it broke `wl-paste`; refuse the
  write *requests* instead. (`clipboard-and-dns.md`)
- **Don't wrap `google-chrome` image-wide with `--no-sandbox`** — the entrypoint's `npx` shim
  already makes the stock `chrome-devtools-mcp` plugin launch a browser; a Dockerfile wrapper is
  redundant, needs a rebuild, and disarms every other Chrome caller. (`terminal-and-security.md`)
- **Sleep guard: busiest single process, never a sum; only pids in both samples** — any sum
  scales with N and pinned sleep overnight. Don't switch the inhibitor to `--what=idle` (kills
  lid-shut tasks); keep the post-resume SETTLE window (re-suspend wedged s2idle). The sampler is
  SOURCED by both the guard and the diagnostic — never copy it. (`sleep-guard.md`)
- **Don't re-enable `leftArrowOpensAgents`, and don't re-investigate the ←-key data loss** — the
  sandbox is exonerated; it's the binary's abort-then-fork. Keep the pin. (`terminal-and-security.md`)
- **No `tput reset`** (regression-guarded); keep `|| true` on `tput cols`/`lines` and `read`.
  (`terminal-and-security.md`)
- **FUSE passthrough I/O is `os.pread`/`os.pwrite`, never `lseek`+`read`** — the shared fd offset
  truncated reads at a 16 KiB boundary, which is where years of "flaky" lint/test runs came from.
  Regression-guarded. Also: keep mypy's cache out of the repo (mmap over the view SIGBUSes —
  `dev.sh` exports `MYPY_CACHE_DIR`), and keep `dev.sh`'s explicit `.py` list (`ruff format`
  rewrites python blocks inside `*.md`). (`redaction-config-guard.md`)
- **Never unlink lock files**, and every backgrounded host process must close fds 200/201
  (`200>&- 201>&-`) — one miss strands every project's containers. Unmount the FUSE view
  *before* killing its sidecar. (`container-lifecycle.md`)
- **Don't put a hook back into the user's repos.** kib cannot install one the git-native way
  (its own guard refuses `core.hooksPath`), so the file copy was always a workaround, and it
  littered every repo the sandbox ever touched. The checks live in `host/gitguard.sh` +
  `kib/host/gitaudit.py`, run at cold start, at teardown and on `kib audit`.
  (`redaction-config-guard.md`)
- **Don't set `PYTHONPATH` in the image** — it would leak into every process the agent runs. The
  guest shims set it for their own exec only. Regression-guarded.
- **`daemon.log` noise is benign**: `bg adopt … dead=N`, `idle 5s … exiting`,
  `bg settled (killed)` — each already cost a full investigation. (`terminal-and-security.md`)
- **`notify()` is for problems only** — never add a launch-success notification. (`clipboard-and-dns.md`)

## Conventions

- Conventional commit style. Never commit unless asked.
- `docs/design-notes/` files: `architecture.md` · `container-lifecycle.md` ·
  `redaction-config-guard.md` · `credential-broker.md` · `clipboard-and-dns.md` ·
  `sleep-guard.md` · `macos.md` · `terminal-and-security.md` (`README.md` is the map). Keep the
  relevant file updated when behaviour or rationale changes.
