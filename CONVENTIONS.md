# Project Coding Conventions you MUST follow

One entrypoint for everything below — run it before you finish:

```bash
./dev.sh format   # rewrite:  ruff format, ruff check --fix, shfmt -w
./dev.sh lint     # verify:   ruff format --check, ruff check, mypy --strict, shfmt -d
./dev.sh check    # lint + tests/check.sh (syntax, shellcheck, portability, unit tests)
```

`./dev.sh check` is exactly what CI runs, so a clean local run means a green build.

## Toolchain

Config is repo-root and shared by all three environments (VSCode on the host, the CLI inside
the kib container, a CLI on the host) — never duplicate a setting into an editor profile.

| What | Where | Notes |
|---|---|---|
| Python format + lint + import order | `pyproject.toml` `[tool.ruff]` | Ruff replaces Black, Flake8 and isort |
| Python typing | `pyproject.toml` `[tool.mypy]` | `strict = true`, no exceptions |
| Shell format | `.editorconfig` | shfmt reads it **only** when passed no style flags — so pass none |
| Line length, charset, EOL, final newline | `.editorconfig` | **100 columns**, everywhere, prose included |
| Python tool versions | `requirements-dev.txt` | exact `==` pins |
| Shell tool versions | `Dockerfile` `ARG SHFMT_VERSION` / `ARG SHELLCHECK_VERSION` | pinned release binaries; keep in step with `.github/workflows/lint.yml` |

Bump a pin deliberately and in every place it appears. A floating version means the same code
passes in one environment and fails in another.

## Python

- **Ruff** for formatting and linting; rule set is `E, F, I, UP, B, N` (see `pyproject.toml`).
  Never hand-format around it — if the output is ugly, restructure the code.
- **`mypy --strict` must pass on every file.** Annotate parameters *and* returns, including
  `-> None`. Prefer precise types; reach for `Any` only where the data genuinely is dynamic
  (parsed JSON, a `ModuleType` stub, a heterogeneous provider row) and say so in a comment.
- Suppress a rule only with a narrow, reason-carrying comment — `# noqa: N815` on the one line,
  `# type: ignore[misc]` with the sentence explaining why, never a bare `# noqa` or a file-wide
  ignore.
- 4-space indent; `snake_case` functions/variables, `PascalCase` classes, `UPPER_CASE` constants.
- Docstrings on every module, class and non-trivial function (PEP 257). Comments carry the *why*
  — the rules this repo has re-learned the hard way are worth a sentence each.
- **Stdlib only in anything the container runs.** The sidecars (`ccignore-fuse.py`,
  `wayland-guard.py`, `cc-broker.py`, `claude-config-scope.py`) run off the image's bare
  `python3`; a pip dependency there breaks the launch path. `requirements-dev.txt` is for the
  lint toolchain, not for runtime.

## Shell

- **shfmt** with the style in `.editorconfig` (4-space indent, `switch_case_indent`,
  `binary_next_line`). Continuations lead with the operator — `\` then `&& …` on the next line —
  matching the existing 54 sites.
- **shellcheck** clean, and `bash -n` every script you touch before finishing: a syntax error
  here leaves the user unable to start the sandbox at all.
- **Host-side scripts must be bash-3.2/BSD-clean** (stock macOS, no brew). GNU-only tools and
  bash-4 features live behind a `cc-portable.sh` shim — see the portability contract in
  `CLAUDE.md`. `tests/check.sh` enforces this and proves the darwin paths on Linux.

## Tests

There is **no pytest here** and none should be added: the suites are self-checking scripts so
they can run inside the sandbox with nothing installed.

- `tests/check.sh` — host-side dev suite. Add a case as an `ok`/`bad` pair with a message that
  says what broke and why it matters. Settled bugs get a **regression guard** here.
- `tests/security-test.sh` — runs *inside* a sandbox; must pass in both redaction modes
  (normally, and under `CC_SINGLE_CONTAINER=1`).
- `tests/broker-test.py`, `tests/config-scope-test.py`, `test-ccignore-fuse.py` — plain scripts
  with a local `check()` helper, exiting non-zero on failure. Register new ones in
  `tests/check.sh`'s `PY` list.
- Name a check for the behaviour it protects, not the function it calls.

## Documentation

- `CLAUDE.md` is instructions only — short, authoritative, every line preventing a real mistake.
- Rationale, history and dead ends go in `docs/design-notes/` (see its `README.md` for the map).
  **Update the relevant file in the same change as the behaviour.** When a claim is inferred
  rather than measured, say which it is.

## Project specific conventions and notes

- **Conventional commits, and never commit unless asked.** No `--no-verify`, no `--amend`, no
  history rewriting, no `push` unless told to.
- **You are working from inside the sandbox this repo builds.** There is no `docker` binary or
  socket. Host-side commands go to the user as a fenced block, pasteable as-is: no `!` prefix
  (that runs *in this container*), no `$` prompts, no placeholders.
- **Edits take effect on the next *container*, not the next terminal.** Bind-mounted sidecars
  keep running their old code until the last session exits; `docker-entrypoint.sh`,
  `entrypoint-fuse.sh` and anything in the `Dockerfile` need a rebuild (`./build-bg.sh`, never a
  bare `docker build`). Before believing a "no change" result, check `ps -o lstart= -p 1`.
- **mypy's cache must stay outside the repo** — it is mmap'd, and mmap over the FUSE view dies
  with SIGBUS. `dev.sh` exports `MYPY_CACHE_DIR` into `$TMPDIR`; keep it that way.
- **A host `.venv` is visible inside the container, and half of it does not run there.** `uv venv`
  puts a symlink to a uv-managed interpreter in `.venv/bin/python3`, which the sandbox has no
  copy of — so `ruff` (a native binary) works while `mypy` (a Python entry point) fails with
  "required file not found". `dev.sh`'s `tool()` probes `--version` before preferring the venv
  and falls back to the baked `/opt/dev-tools` copies; don't reduce that to a plain `[ -x ]`.
- **`ruff format` also rewrites Python code blocks inside `*.md`.** `dev.sh` passes an explicit
  `.py` file list for that reason — don't "simplify" it to `ruff format .` or it will edit the
  abbreviated snippets in `docs/design-notes/`.
- Prefer deleting or merging code over adding it. Shorter and DRY-er wins, as long as the
  *reason* survives in a comment.
