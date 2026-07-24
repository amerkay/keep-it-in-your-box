# PLAN: unified lint/format toolchain (VSCode · kib container · host CLI)

> **Status:** planned, not yet implemented. Execute in a later session.
> **Scope note:** the *planning* session that wrote this could only edit `CONVENTIONS.md`; every
> other file below is still to be created/edited.

## Context

`CONVENTIONS.md` prescribes formatters/linters but **nothing is wired up** — the repo has zero
tool configs (`pyproject.toml`, `requirements-dev.txt`, `.editorconfig`, `.vscode/` all absent),
and `tests/check.sh` only runs `py_compile` (syntax), never a formatter or linter. So none of the
three target environments — VSCode on the host, the CLI inside the kib container, the CLI on the
host — can lint or format consistently: there is no shared config and no pinned versions to agree
on.

Goal: one **single source of truth** (config files at repo root) + **pinned versions** so all
three environments produce identical results, a thin verb entrypoint (`dev.sh`), and CI to enforce
it.

### Decisions (locked with the user)

| Area | Choice |
|---|---|
| Python format + lint + imports | **Ruff** (one binary, replaces Black+Flake8+isort) |
| Type checking | **mypy `--strict`**, enforced |
| Shell | **shfmt (check-only) + shellcheck**, both kept & **version-pinned** (not moved to pip) |
| Entrypoint | **`./dev.sh`** subcommands (`format` / `lint` / `check`), pure bash |
| Config home | `pyproject.toml`, `requirements-dev.txt`, `.editorconfig` at repo root |
| Existing 6 sidecars | **clean baseline** — ruff-format + full annotations to pass `--strict` |
| CI | **GitHub Actions, lint-only, Ubuntu** |
| VSCode | host-side `.vscode/` (protected path — user creates it) |

## Constraints (CLAUDE.md / sandbox)

- **No docker in-container** — cannot build/test the image here; hand host commands as a paste-in
  fenced block (no `!`, no `$`, no placeholders).
- **`.vscode/` is a protected path** — writes fail EACCES inside the sandbox (host executes it).
  Its files must be created **by the user on the host**; content is provided below.
- **Dockerfile edits need an image rebuild**, not a relaunch (baked, not bind-mounted). The shfmt
  pin + dev-tool layer land only on the next rebuilt container (verify with `ps -o lstart= -p 1`).
- **`dev.sh` must be bash-3.2 / BSD-clean** (host may be stock macOS). Source `cc-portable.sh` and
  use its shims for any GNU-only need; all OS branching stays in `cc-portable.sh`.
- `bash -n` every script touched. Never commit unless the user asks.

## Environment facts (from exploration)

- Image is `FROM debian:trixie` (Python **3.13**). It **already bakes** `shellcheck` (apt),
  `shfmt` (Dockerfile:91–116), and `uv` (Dockerfile:74–77).
- **Bug to fix:** `shfmt` is fetched as GitHub **`latest`** with a `v3.12.0` fallback
  (Dockerfile:100) — it *floats*, so builds format differently over time. Pin it.
- The 4 main sidecars are **untyped**: `0` of ~91 functions annotated across `cc-broker.py` (841
  lines), `ccignore-fuse.py` (533), `wayland-guard.py` (245), `ccignore-precommit.py` (242).
  `--strict` is the **largest work item** — its own stage.

## Task checklist

- [ ] **1. Root configs** — `pyproject.toml`, `requirements-dev.txt`, `.editorconfig`
- [ ] **2. `dev.sh`** verb entrypoint (`format`/`lint`/`check`)
- [ ] **3. Dockerfile** — pin shfmt + add pinned Python dev-tool layer
- [ ] **4. CI** — `.github/workflows/lint.yml` (Ubuntu, lint-only)
- [ ] **5. VSCode** — hand `.vscode/` files to the user (host-side)
- [ ] **6. Sidecars** — ruff-format + full `--strict` annotations (separate commits)
- [ ] **7. `CONVENTIONS.md`** — rewrite (drop `src/`/boto3/AWS; add Ruff + shell + tooling)

## Detail

### 1. Root configs (new)

**`pyproject.toml`**
```toml
[tool.ruff]
line-length = 88
target-version = "py313"          # container runtime; the tools run on any py3.11+

[tool.ruff.lint]
select = ["E", "F", "I", "UP", "B", "N"]   # pycodestyle, pyflakes, isort, pyupgrade, bugbear, naming

[tool.ruff.format]                 # Black-compatible defaults

[tool.mypy]
python_version = "3.13"
strict = true
```

**`requirements-dev.txt`** — Python tools only; **exact pins** (lock to installed via `pip freeze`
/ `uv pip compile`). Shell tools are intentionally *not* here (they are binaries).
```
ruff==<pin>
mypy==<pin>
```

**`.editorconfig`**
```ini
root = true
[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
trim_trailing_whitespace = true
[*.py]
indent_style = space
indent_size = 4
[*.sh]
indent_style = space
indent_size = 2
```

### 2. `dev.sh` (new, repo root, `chmod +x`)

Pure bash, `set -euo pipefail`, `source cc-portable.sh`. Discover files with
`git ls-files '*.py'` / `'*.sh'`. Subcommands:
- `format` → `ruff format .` then `ruff check --fix .` (apply + sort imports)
- `lint` → `ruff format --check .` && `ruff check .` && `mypy <py>` && `shfmt -d <sh>` &&
  `shellcheck <sh>`  *(this is what CI runs — shell is linted in CI too)*
- `check` → `dev.sh lint` then `tests/check.sh` (full local suite)

`tests/check.sh` stays authoritative for the security/portability suite; its redundant
`py_compile` block may be dropped (ruff/mypy supersede it).

### 3. Dockerfile (edit)

- Replace the `releases/latest | jq` lookup (Dockerfile:100) with a fixed
  `SHFMT_VERSION="v3.12.0"` — reproducible, no network version resolution.
- Add a dev-tools layer **above** the Claude-install line (keep version bumps cached):
  `COPY requirements-dev.txt` then `uv pip install --system -r requirements-dev.txt` (uv already
  present). Container then ships ruff + mypy at the pinned versions.

### 4. CI (new) — `.github/workflows/lint.yml`

Single `ubuntu-latest` job on push/PR: checkout → install `shfmt` + `shellcheck` (apt) at the
pinned version → `pip install -r requirements-dev.txt` → `./dev.sh lint`. No docker build, no OS
matrix (image is Linux-only; linting is OS-independent).

### 5. VSCode (host-side — user creates; **cannot** be written from the sandbox)

```jsonc
// .vscode/settings.json
{
  "editor.formatOnSave": true,
  "editor.defaultFormatter": "charliermarsh.ruff",
  "[python]": { "editor.codeActionsOnSave": { "source.organizeImports": "explicit" } },
  "python.defaultInterpreterPath": "${workspaceFolder}/.venv/bin/python"
}
```
```jsonc
// .vscode/extensions.json
{ "recommendations": ["charliermarsh.ruff", "ms-python.mypy-type-checker", "editorconfig.editorconfig"] }
```

### 6. Existing sidecars (edit) — clean baseline for `--strict` *(largest stage)*

Run `dev.sh format`, then add full type annotations so `mypy --strict` passes on `cc-broker.py`,
`ccignore-fuse.py`, `wayland-guard.py`, `ccignore-precommit.py`, `tests/broker-test.py`,
`test-ccignore-fuse.py`. Keep separate from the tooling scaffolding — ~91 functions, and it
touches security-relevant code.

### 7. `CONVENTIONS.md` (rewrite — generic-ish)

- **Replace** Black/Flake8/isort → **Ruff** (`ruff format`, `ruff check`); line-length 88.
- **Replace** the mypy/testing line → **mypy `--strict`**.
- **Add** *Shell* section: shellcheck + shfmt (check-only) + bash-3.2/BSD portability
  (point at `cc-portable.sh` / CLAUDE.md).
- **Add** *Tooling* section: `./dev.sh format|lint|check`, `requirements-dev.txt`, root configs,
  VSCode extensions.
- **Drop** irrelevant sections: `src/services`·`db/models`·`db/operations`, dataclass
  `to_dict/from_dict`, `boto3-stubs`, `moto`/AWS. Genericize "Project Structure" to the flat
  `*.sh` + sidecars + `tests/` layout.
- **Fill** "Project specific conventions": conventional commits, never commit unless asked,
  container-rebuild-vs-relaunch gotcha.

## Critical files

- New: `pyproject.toml`, `requirements-dev.txt`, `.editorconfig`, `dev.sh`, `.github/workflows/lint.yml`
- New (host-side, user): `.vscode/settings.json`, `.vscode/extensions.json`
- Edit: `Dockerfile` (shfmt pin + dev layer), the 6 `*.py` sidecars, `CONVENTIONS.md`, optionally
  `tests/check.sh`
- Reuse: `cc-portable.sh` (shims for `dev.sh`), `tests/check.sh` (called by `dev.sh check`)

## Verification (end-to-end)

1. **Host CLI:** `python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt`, then
   `./dev.sh lint` → green; `./dev.sh format` twice → second run a no-op (idempotent).
2. **Container:** rebuild image (host-side), confirm fresh container via `ps -o lstart= -p 1`, then
   inside it check `ruff --version` / `mypy --version` / `shfmt --version` match the pins and
   `./dev.sh lint` passes identically to the host.
3. **Full suite:** `./tests/check.sh` still green; `./dev.sh check` green.
4. **CI:** push a branch; the Ubuntu lint job passes.
5. **VSCode:** after the user adds `.vscode/`, format-on-save reformats via Ruff and the Problems
   panel surfaces mypy/ruff findings.

### Host-side commands to hand the user (no `!`, real paths)
```
docker build -t keep-it-in-your-box .
brew install shfmt shellcheck        # macOS host, to match the pinned in-image versions
```
