# Developing kib

Notes for working on kib itself. For what it does and how to use it, see [`README.md`](README.md);
for why each subsystem is built the way it is — including the dead ends — see
[`docs/design-notes/`](docs/design-notes/README.md).

## Lint and format

One entrypoint, behaving identically in all three places you might run it — inside the box, on the
host, and in your editor:

```bash
./dev.sh format   # rewrite:  ruff format, ruff check --fix, shfmt -w
./dev.sh lint     # verify:   ruff format --check, ruff check, mypy --strict, shfmt -d
./dev.sh check    # lint + tests/check.sh — exactly what CI runs
```

Inside the box there is nothing to install: the image bakes ruff, mypy, shfmt and shellcheck at the
pinned versions. On the host:

```bash
uv venv --python 3.13
uv pip install -r requirements-dev.txt
# or, without uv:  python3 -m venv .venv && ./.venv/bin/pip install -r requirements-dev.txt
```

shfmt and shellcheck are Go/Haskell binaries, not Python packages — install the pinned releases
(shfmt `v3.13.1`, shellcheck `v0.10.0`), or `brew install shfmt shellcheck` on macOS and keep the
versions in step. `dev.sh` prefers a repo-local `.venv` but probes each tool before using it, so a
host venv — whose interpreter the container cannot see — falls back to the baked copies by itself.

Configuration is repo-root, shared by editor, container and host, and never duplicated into an
editor profile:

| File | Governs |
|---|---|
| `pyproject.toml` | ruff (format, lint, import order) and mypy `strict` |
| `.editorconfig` | 100-column lines — and **shfmt's own config**, which it reads whenever no style flags are passed, so `dev.sh` passes none |
| `requirements-dev.txt` | exact pins for ruff, mypy and pytest |
| `Dockerfile`, `.github/workflows/lint.yml` | pinned shfmt + shellcheck binaries, kept in step with each other |

What to annotate, when a `# noqa` earns its place, and the shell rules are in
[`CONVENTIONS.md`](CONVENTIONS.md).

## Editor setup (VS Code)

Run VS Code **on the host**, against the real directory — not attached to the box. The sandbox's
redacted view exists only inside the container, so the editor sees ordinary files.

[`.vscode/extensions.json`](.vscode/extensions.json) and [`.vscode/settings.json`](.vscode/settings.json)
are checked in — a fresh clone gets prompted to install, and they wire straight into the same
`pyproject.toml` / `.editorconfig` the CLI and CI read. Nothing to configure by hand:

```bash
code --install-extension charliermarsh.ruff
code --install-extension ms-python.mypy-type-checker
code --install-extension mkhl.shfmt
code --install-extension timonwong.shellcheck
code --install-extension EditorConfig.EditorConfig
```

Five things that will bite otherwise:

- **`.vscode/` is write-denied from inside the box** — it's on the host-executed-config guard list.
  An agent in the sandbox getting EPERM if it edits these files is the guard working, not a bug;
  edit them from a host terminal.
- **Point VS Code at `.venv`** (`Python: Select Interpreter`). `fromEnvironment` resolves ruff and
  mypy through the selected interpreter; without it both fall back to bundled versions and you get
  diagnostics CI doesn't have — or miss ones it does.
- **Use `mkhl.shfmt`, not `foxundermoon.shell-format`.** The latter is the more popular extension
  and it [ignores `.editorconfig`](https://github.com/foxundermoon/vs-shell-format/issues/66),
  configuring itself from `settings.json` instead — which would reformat every script against
  shfmt's tab default and fight `./dev.sh format` on every save.
- **shfmt and shellcheck are separate binaries.** `mkhl.shfmt` ships none, so install shfmt
  (`shfmt.executablePath` if it isn't on `PATH`); `timonwong.shellcheck` bundles *its own*, which
  drifts from the pinned `v0.10.0` — set `shellcheck.executablePath` at the pinned one if the
  editor and CI ever disagree.
- **A Flatpak or Snap editor has the sandbox's `PATH`, not yours.** Host-installed shfmt is
  invisible to it, so `mkhl.shfmt` fails with `command not found` (shellcheck keeps working only
  because it bundles a binary). Reach the host copy with `"shfmt.executablePath":
  "/usr/bin/flatpak-spawn"` plus `"shfmt.executableArgs": ["--host", "shfmt"]` — in **user**
  settings, since it describes the machine rather than the project.

The mypy extension writes a `.mypy_cache/` into the repo. That's gitignored and harmless on the
host, but it is the reason a bare `mypy` **inside** the box dies with SIGBUS — its cache is mmap'd
and mmap over the FUSE view faults. In the box, go through `./dev.sh`, which points
`MYPY_CACHE_DIR` outside the mount.

## Tests

All test suites live in [`tests/`](tests/). The host-side ones need no image or container:

```bash
./dev.sh check     # lint + the whole host-side suite — exactly what CI runs
./tests/check.sh   # just the suite: syntax, shellcheck, the bash-3.2/BSD portability
                   #   contract, the host/portable.sh shim unit tests, the broker and
                   #   MCP bash wiring, the regression guards, then pytest
pytest             # just the Python suites (tests/shared, host, guest, broker)
```

The bash sections live one per file in [`tests/check/`](tests/check/); `tests/check.sh` is a thin
runner over them, and both bash suites share the harness in `tests/lib.sh` so they report
identically.

[`tests/security-test.sh`](tests/security-test.sh) is the **in-sandbox** regression suite — one
check per control the [audit](docs/security/audit.md) established. Run it **inside** the box:

```bash
kib exec ./tests/security-test.sh                 # everything
kib exec ./tests/security-test.sh --list          # what it covers, run nothing
kib exec ./tests/security-test.sh -k git          # one section
```

Each check re-attempts a real attack and asserts the refusal, *and* re-attempts the legitimate
operation the guard must not break — a guard that blocks the attack by breaking the workflow has
failed too.

## Working on kib from inside kib

The repo is normally developed in its own sandbox, which has two consequences for debugging:

- **There is no `docker` binary or socket in the box**, so you cannot build the image or exercise a
  container end-to-end from in there. Host-side commands go to a host terminal.
- **Edits take effect on the next *container*, not the next terminal.** One long-lived container
  serves every terminal on the project and is recreated only after the last session exits; the
  `guest/entrypoint/*` files and the three `guest/bin/` shims are baked into the image and need a
  rebuild (`kib build`), not a relaunch.

[`CLAUDE.md`](CLAUDE.md) carries the full working rules and the list of settled dead ends.
