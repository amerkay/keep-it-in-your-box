#!/usr/bin/env python3
# ccignore-precommit — auto-installed by cc into .git/hooks/pre-commit.
# MARKER: ccignore-precommit (cc uses this string to detect/update its own hook)
#
# Aborts a commit if any staged path matches a rule in the repo's .ccignore.
# Such paths are hidden from the Claude Code Docker sandbox; committing them
# would leak their real (host) contents into git history and diffs.
#
# Rule syntax mirrors ccignore-fuse.py exactly:
#   bare basename  -> matches that name as any path component (excluding .git)
#   path with '/'  -> exact, relative to repo root, '*' never crosses '/'
#   leading '!'    -> negation (re-include), gitignore last-match-wins order
#   '#'            -> comment; leading-'/' and '..' rules are skipped as unsafe
#
# Bypass intentionally (not recommended) with: git commit --no-verify

import fnmatch
import os
import subprocess
import sys
from collections.abc import Sequence

# ── Host-config audit ────────────────────────────────────────────────────
# The sandbox's FUSE guard refuses to write these, but this hook is the backstop:
# it catches a repo poisoned before the guard shipped, one edited outside cc, and
# anything the guard's path matching misses. Duplicated from ccignore-fuse.py on
# purpose — this file is copied standalone into .git/hooks and cannot import it.
DANGEROUS_GIT_KEYS = frozenset(
    """hookspath fsmonitor sshcommand pager editor askpass gitproxy external textconv
    command driver clean smudge process helper templatedir program cmd variant
    packobjectshook uploadpack receivepack""".split()
)
DANGEROUS_GIT_SECTIONS = frozenset({"alias", "pager", "include", "includeif"})
PRUNE_DIRS = {"node_modules", ".venv", "venv", "target", "dist", "build", ".tox"}
GITDIR_MARKERS = ("HEAD", "objects", "refs")


def bad_keys(listing: str) -> list[str]:
    """Lines of `git config --list` output naming a command the host would run."""
    bad: list[str] = []
    for line in listing.splitlines():
        key = line.split("=", 1)[0].strip().lower()
        if not key:
            continue
        parts = key.split(".")
        if parts[0] in DANGEROUS_GIT_SECTIONS or parts[-1] in DANGEROUS_GIT_KEYS:
            bad.append(line)
    return bad


def git_config_list(args: Sequence[str]) -> str:
    try:
        return subprocess.run(
            ["git", "config", *args, "--list", "--includes"],
            capture_output=True,
            text=True,
            check=False,
        ).stdout
    except OSError:
        return ""


def audit_git_config() -> list[str]:
    """Local git config entries whose value is a command the host would run.

    `--includes` is what makes this see through `include.path` indirection; without
    it a poisoned config reads as a benign one-liner. `--local` is deliberate — the
    unscoped form would pull in the user's own ~/.gitconfig (core.pager, alias.*)
    and block every commit.
    """
    return bad_keys(git_config_list(["--local"]))


def audit_nested_gitdirs(top: str) -> list[str]:
    """Dangerous config in git dirs the top-level scope never sees.

    Bare repos, `--separate-git-dir` targets and gitfile redirects are ordinary
    directories as far as `git config --local` is concerned, yet the host runs
    what they configure the moment it touches that repo.
    """
    bad: list[str] = []
    for dirpath, dirnames, _ in os.walk(top):
        dirnames[:] = [d for d in dirnames if d not in PRUNE_DIRS]
        if not all(os.path.exists(os.path.join(dirpath, m)) for m in GITDIR_MARKERS):
            continue
        # Inside a git dir only nested git dirs matter; objects/ alone is thousands
        # of directories and none of them can hold a config.
        dirnames[:] = [d for d in dirnames if d in ("modules", "worktrees")]
        if dirpath == os.path.join(top, ".git"):
            continue  # the top repo — already covered by audit_git_config()
        cfg = os.path.join(dirpath, "config")
        if not os.path.isfile(cfg):
            continue
        rel = os.path.relpath(dirpath, top)
        bad += [f"{rel}: {line}" for line in bad_keys(git_config_list(["--file", cfg]))]
    return bad


def audit_nested_hooks(top: str) -> list[str]:
    """Executable hooks in *nested* git dirs — submodules, worktrees, sub-repos.

    The top-level .git/hooks is left alone: cc bind-mounts it read-only and it is
    the user's own. Nested ones are the gap that mount cannot cover, since a repo
    can be cloned or `git init`ed after the container started.
    """
    found: list[str] = []
    for dirpath, dirnames, filenames in os.walk(top):
        dirnames[:] = [d for d in dirnames if d not in PRUNE_DIRS]
        if os.path.basename(dirpath) == ".git":
            # Descend only where nested git dirs live; skip objects/, refs/, …
            dirnames[:] = [d for d in dirnames if d in ("modules", "worktrees", "hooks")]
            if os.path.dirname(dirpath) == top:
                dirnames[:] = [d for d in dirnames if d != "hooks"]
            continue
        if os.path.basename(dirpath) != "hooks":
            continue
        for name in filenames:
            path = os.path.join(dirpath, name)
            if name.endswith(".sample"):
                continue
            if os.access(path, os.X_OK) and not os.path.isdir(path):
                found.append(os.path.relpath(path, top))
    return found


def load_rules(path: str) -> list[tuple[bool, str, bool]]:
    """Ordered list of (negated, pattern, is_exact); order preserved so a
    later '!' rule re-includes a path an earlier rule matched."""
    rules: list[tuple[bool, str, bool]] = []
    with open(path) as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            neg = line.startswith("!")
            if neg:
                line = line[1:].strip()
            line = line.rstrip("/")
            if not line:
                continue
            if line.startswith("/") or ".." in line.split("/"):
                continue
            rules.append((neg, line, "/" in line))
    return rules


def matches(rel: str, rules: Sequence[tuple[bool, str, bool]]) -> bool:
    """Gitignore-consistent: last matching rule wins, and a path under an
    already-masked parent directory can't be re-included by negation."""
    parts = rel.split("/")
    under_git = parts[0] == ".git"
    ignored = False
    for i in range(1, len(parts) + 1):
        anc = parts[:i]
        seg = parts[i - 1]
        for neg, pat, exact in rules:
            if exact:
                ppar = pat.split("/")
                hit = len(ppar) == len(anc) and all(
                    fnmatch.fnmatch(a, p) for a, p in zip(anc, ppar, strict=True)
                )
            else:
                hit = not under_git and fnmatch.fnmatch(seg, pat)
            if hit:
                ignored = not neg
        # A masked proper-ancestor directory seals everything beneath it.
        if ignored and i < len(parts):
            return True
    return ignored


def main() -> int:
    try:
        top = subprocess.check_output(["git", "rev-parse", "--show-toplevel"]).decode().strip()
    except subprocess.CalledProcessError:
        return 0

    red, reset = "\033[31m", "\033[0m"

    # Runs whether or not the repo has a .ccignore: a poisoned git config is a
    # host-execution bug on its own, independent of any redaction rules.
    cfg = audit_git_config() + audit_nested_gitdirs(top)
    hooks = audit_nested_hooks(top)
    if cfg or hooks:
        sys.stderr.write(
            f"\n{red}✖ commit blocked — host-executed config found in this repo{reset}\n"
        )
        if cfg:
            sys.stderr.write(
                "\nThese git config entries name a command git runs on the HOST\n"
                "(core.fsmonitor fires on a bare `git status`, before you read any diff).\n"
                "An 'include.path' entry counts too: it can pull any of them in from\n"
                "another file. A '<dir>:' prefix means a nested or bare git dir:\n"
            )
            for line in cfg:
                sys.stderr.write(f"    {line}\n")
            sys.stderr.write(
                "\nInspect, then remove with:  git config --local --unset <key>\n"
                "                        or:  git config --file <dir>/config --unset <key>\n"
            )
        if hooks:
            sys.stderr.write("\nExecutable hooks in nested git dirs:\n")
            for p in hooks:
                sys.stderr.write(f"    {p}\n")
            sys.stderr.write("\nInspect, then remove or chmod -x them.\n")
        sys.stderr.write(
            "\nA sandboxed Claude session can write these; the host executes them later.\n"
            "If you set them yourself, bypass with:  git commit --no-verify\n\n"
        )
        return 1

    ccignore = os.path.join(top, ".ccignore")
    if not os.path.exists(ccignore):
        return 0

    rules = load_rules(ccignore)
    if not rules:
        return 0

    out = subprocess.check_output(["git", "diff", "--cached", "--name-only", "-z"])
    staged = [p for p in out.decode().split("\0") if p]
    bad = [p for p in staged if matches(p, rules)]
    if not bad:
        return 0

    sys.stderr.write(
        f"\n{red}✖ commit blocked by .ccignore{reset} — these staged paths are hidden "
        "from the Claude sandbox and must not be committed:\n"
    )
    for p in bad:
        sys.stderr.write(f"    {p}\n")
    sys.stderr.write(
        "\nCommitting them would leak their real contents into git history and diffs.\n"
        "Unstage them with:  git restore --staged <path>\n"
        "If this is truly intentional, bypass with:  git commit --no-verify\n\n"
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
