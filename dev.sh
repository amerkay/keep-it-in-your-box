#!/usr/bin/env bash
# One entrypoint for the lint/format toolchain, identical in all three environments:
# VSCode (via .editorconfig + pyproject.toml), the CLI inside the kib container, and a CLI
# on the host. Config lives in pyproject.toml / .editorconfig; versions in
# requirements-dev.txt (python) and the Dockerfile / CI (shfmt, shellcheck binaries).
#
#   ./dev.sh format   rewrite: ruff format + ruff --fix, shfmt -w
#   ./dev.sh lint      verify: ruff, mypy --strict, shfmt -d          (what CI runs, via check)
#   ./dev.sh check      lint + tests/check.sh (syntax, shellcheck, portability, unit tests)
#
# Host-side script: bash-3.2/BSD-clean per the portability contract (tests/check.sh enforces
# it). Nothing here needs a cc-portable.sh shim, so it deliberately does not source it.
set -euo pipefail
cd "$(dirname "$0")"

# mypy's cache is mmap'd, and mmap over the project's FUSE view dies with SIGBUS — an
# in-repo .mypy_cache core-dumps every in-container run. Keep it outside the mount always:
# one code path, and the host loses nothing but a repo-local cache directory.
MYPY_CACHE_DIR="${TMPDIR:-/tmp}/kib-mypy-cache"
export MYPY_CACHE_DIR

FAILED=""

# Prefer a repo-local venv (host setup) over whatever is on PATH (the container bakes
# /opt/dev-tools onto PATH), so a host venv never silently loses to a stale global install —
# but only if it can actually execute *here*. The repo is shared with the container, and a host
# `uv venv` puts a symlink to a uv-managed interpreter in .venv/bin/python3 that does not exist
# inside the sandbox: `ruff` still runs (native binary, no shebang) while `mypy` dies with
# "required file not found". Probing beats guessing at the environment — it also routes around a
# half-deleted or wrong-arch venv on the host, and needs no OS/container branching.
tool() {
    if [ -x ".venv/bin/$1" ] && ".venv/bin/$1" --version >/dev/null 2>&1; then
        printf '%s\n' ".venv/bin/$1"
    elif command -v "$1" >/dev/null 2>&1; then
        printf '%s\n' "$1"
    else
        return 1
    fi
}

# Run one tool, remember failure but keep going so a run reports every problem at once.
step() {
    local label="$1" bin
    shift
    if ! bin="$(tool "$1")"; then
        printf '\n\033[33m!\033[0m %s: %s not found — see "Toolchain" in CONVENTIONS.md\n' "$label" "$1"
        FAILED="$FAILED $label(missing)"
        return 0
    fi
    shift
    printf '\n\033[1m== %s\033[0m\n' "$label"
    "$bin" "$@" || FAILED="$FAILED $label"
}

# Tracked files plus new-but-not-ignored ones, so a file is linted before its first commit.
git_files() { git ls-files --cached --others --exclude-standard; }

# Shell scripts: *.sh plus extensionless files with a shell shebang (`cc`).
list_sh() {
    git_files | while IFS= read -r f; do
        [ -f "$f" ] || continue
        case "$f" in
            *.sh) printf '%s\n' "$f" ;;
            *.*) ;;
            *) head -n 1 "$f" 2>/dev/null | grep -qE '^#!.*(bash|/sh|[[:space:]]sh)' \
                && printf '%s\n' "$f" ;;
        esac
    done
}

# Explicit file list, never `ruff format .`: ruff also rewrites python code blocks inside
# *.md, which would silently edit the abbreviated snippets in docs/design-notes/.
list_py() { git_files | grep -E '\.py$' || true; }

# bash 3.2: no readarray. Populate an array from a newline-fed producer.
read_into() {
    local _name="$1"
    eval "$_name=()"
    while IFS= read -r _line; do
        [ -n "$_line" ] || continue
        eval "$_name+=(\"\$_line\")"
    done
}

usage() {
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

read_into PY < <(list_py)
read_into SH < <(list_sh)

# bash 3.2 expands "${arr[@]}" of an empty array as an unbound variable under `set -u`, and an
# empty list would silently lint nothing anyway. Both lists are non-empty in a real checkout.
if [ "${#PY[@]}" -eq 0 ] || [ "${#SH[@]}" -eq 0 ]; then
    printf 'dev.sh: discovered no python/shell files — run this from the repo checkout\n' >&2
    exit 1
fi

case "${1:-}" in
    format)
        step "ruff format" ruff format "${PY[@]}"
        step "ruff check --fix" ruff check --fix "${PY[@]}"
        step "shfmt -w" shfmt -w "${SH[@]}"
        ;;
    lint)
        step "ruff format --check" ruff format --check "${PY[@]}"
        step "ruff check" ruff check "${PY[@]}"
        step "mypy --strict" mypy "${PY[@]}"
        step "shfmt -d" shfmt -d "${SH[@]}"
        ;;
    check)
        "$0" lint || FAILED="$FAILED lint"
        printf '\n\033[1m== tests/check.sh\033[0m\n'
        ./tests/check.sh || FAILED="$FAILED tests/check.sh"
        ;;
    "" | -h | --help | help) usage ;;
    *)
        printf 'dev.sh: unknown command %s\n\n' "$1" >&2
        usage 2 >&2
        ;;
esac

if [ -n "$FAILED" ]; then
    printf '\n\033[31mFAILED:\033[0m%s\n' "$FAILED" >&2
    exit 1
fi
printf '\n\033[32mOK\033[0m — %s (%s python, %s shell)\n' "$1" "${#PY[@]}" "${#SH[@]}"
