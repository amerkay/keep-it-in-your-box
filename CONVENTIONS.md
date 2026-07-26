# Project Coding Conventions you MUST follow

One entrypoint for everything below — run it before you finish:

```bash
./dev.sh format   # rewrite:  ruff format, ruff check --fix, shfmt -w
./dev.sh lint     # verify:   ruff format --check, ruff check, mypy --strict, shfmt -d
./dev.sh check    # lint + tests/check.sh (one section per file in tests/check/)
```

`./dev.sh check` is exactly what CI runs, so a clean local run means a green build.

## Toolchain

Config is repo-root and shared by all three environments (VSCode on the host, the CLI inside
the kib container, a CLI on the host) — never duplicate a setting into an editor profile.

| What | Where | Notes |
|---|---|---|
| Python format + lint + import order | `pyproject.toml` `[tool.ruff]` | Ruff replaces Black, Flake8 and isort |
| Python typing | `pyproject.toml` `[tool.mypy]` | `strict = true`, no exceptions |
| Shell format | `.editorconfig` | shfmt reads it **only** when passed no style flags — so pass none. Every extensionless script must be named in its `[…]` glob, or shfmt silently formats that one file with tabs |
| Line length, charset, EOL, final newline | `.editorconfig` | **100 columns**, everywhere, prose included |
| Python tool versions | `requirements-dev.txt` | exact `==` pins (ruff, mypy, pytest) |
| Shell tool versions | `Dockerfile` `ARG SHFMT_VERSION` / `ARG SHELLCHECK_VERSION` | pinned release binaries; keep in step with `.github/workflows/lint.yml` |

Bump a pin deliberately and in every place it appears. A floating version means the same code
passes in one environment and fails in another.

Editor wiring — the extensions to install and the two `.vscode/` files that point them at the
config above — is in the README's [editor setup](README.md#editor-setup-vs-code) section. Note
`.vscode/` is write-denied inside the sandbox, so those files are created host-side.

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
- **Stdlib only in anything the container runs.** Everything under `kib/` runs off the image's
  bare `python3`; a pip dependency there breaks the launch path. `requirements-dev.txt` is for
  the lint and test toolchain, not for runtime.
- **`kib/shared/` may not import `kib.host` or `kib.guest`.** It is the layer both sides share;
  a back-edge drags host-only code into the container.

## Shell

- **shfmt** with the style in `.editorconfig` (4-space indent, `switch_case_indent`,
  `binary_next_line`). Continuations lead with the operator — `\` then `&& …` on the next line.
- **shellcheck** clean down to the **info** tier (`-S info`, fatal in `tests/check/syntax.sh` and
  in the editor), and `bash -n` every script you touch before finishing: a syntax error here
  leaves the user unable to start the sandbox at all. A `# shellcheck disable=` is per-file and
  reason-carrying — never a blanket one covering eleven subsystems. Note a directive only applies
  to the **next complete command**, so a block of cross-unit globals needs it in the file header,
  and it may never sit in front of a single `case` branch (SC1124).
- **Never silence a finding you have not understood.** SC2004 on `host/sleep-monitor.sh`'s
  nameref looks like dead syntax and is load-bearing: `_io` points at an *associative* array, so
  the "unnecessary" `$` is what keeps the subscript from being the literal string `pid`.
- **`# shellcheck source=` paths take the `SCRIPTDIR/` prefix** (`source=SCRIPTDIR/../host/core.sh`).
  A bare relative path only resolves when shellcheck's cwd happens to be the repo root, so the
  editor — which lints on stdin with cwd set to the file's own directory — silently stops
  following the source and reports SC1091 instead.
- **Every `host/*.sh` file opens with what it owns and which globals it reads/writes.** That
  header is the contract between the units; shellcheck cannot see across the source boundary.
- **Host-side scripts must be bash-3.2/BSD-clean** (stock macOS, no brew). GNU-only tools and
  bash-4 features live behind a `host/portable.sh` shim — see the portability contract in
  `CLAUDE.md`. `tests/check/portability.sh` enforces this and proves the darwin paths on Linux.

## Tests

**Python is tested with pytest**; bash is tested by the two shell suites. pytest is pinned in
`requirements-dev.txt` and baked into the image's `/opt/dev-tools`, so it is present wherever the
toolchain is — `tests/check/pytest.sh` HARD-FAILS if it is missing rather than skipping, because a
silently skipped suite reads as a pass.

- `tests/` mirrors `kib/`: `shared/`, `host/`, `guest/`, `broker/`. Shared fixtures live in
  `tests/conftest.py`, which is also what puts the repo root on `sys.path`.
- `tests/check.sh` — a thin runner over `tests/check/*.sh`, one file per section (syntax,
  portability, wiring, mcp, regressions, shims, pytest). Add a case as a `pass`/`fail` pair with a
  message that says what broke and why it matters. Settled bugs get a **regression guard** there.
- `tests/security-test.sh` — runs *inside* a sandbox. Kept as one file, but it sources
  `tests/lib.sh` so both suites report identically.
- Name a check for the behaviour it protects, not the function it calls. A test whose name
  survives a refactor of the code under it is the one worth writing.

## Documentation

- `CLAUDE.md` is instructions only — short, authoritative, every line preventing a real mistake.
- Rationale, history and dead ends go in `docs/design-notes/` (see its `README.md` for the map).
  **Update the relevant file in the same change as the behaviour.** When a claim is inferred
  rather than measured, say which it is.

## Project specific conventions and notes

- **Conventional commits, and never commit unless asked.** No `--no-verify`, no `--amend`, no
  history rewriting, no `push` unless told to.
- **mypy's cache must stay outside the repo** (mmap over the FUSE view SIGBUSes) — `dev.sh`
  exports `MYPY_CACHE_DIR`; keep it that way.
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
