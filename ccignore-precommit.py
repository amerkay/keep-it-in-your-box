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
#   '#'            -> comment; leading-'/' and '..' rules are skipped as unsafe
#
# Bypass intentionally (not recommended) with: git commit --no-verify

import fnmatch
import os
import subprocess
import sys


def load_rules(path):
    basenames, exacts = set(), set()
    with open(path) as f:
        for line in f:
            line = line.split("#", 1)[0].strip().rstrip("/")
            if not line:
                continue
            if line.startswith("/") or ".." in line.split("/"):
                continue
            (exacts if "/" in line else basenames).add(line)
    return basenames, exacts


def matches(rel, basenames, exacts):
    parts = rel.split("/")
    under_git = parts[0] == ".git"

    # Exact rules against each ancestor, component-by-component so '*' never
    # spans a '/'.
    for i in range(1, len(parts) + 1):
        apar = parts[:i]
        for pat in exacts:
            ppar = pat.split("/")
            if len(ppar) == len(apar) and all(
                fnmatch.fnmatch(a, p) for a, p in zip(apar, ppar)
            ):
                return True

    # Basename rules against each path segment (never inside .git).
    if not under_git:
        for seg in parts:
            if any(fnmatch.fnmatch(seg, pat) for pat in basenames):
                return True
    return False


def main():
    try:
        top = (
            subprocess.check_output(["git", "rev-parse", "--show-toplevel"])
            .decode()
            .strip()
        )
    except subprocess.CalledProcessError:
        return 0

    ccignore = os.path.join(top, ".ccignore")
    if not os.path.exists(ccignore):
        return 0

    basenames, exacts = load_rules(ccignore)
    if not basenames and not exacts:
        return 0

    out = subprocess.check_output(["git", "diff", "--cached", "--name-only", "-z"])
    staged = [p for p in out.decode().split("\0") if p]
    bad = [p for p in staged if matches(p, basenames, exacts)]
    if not bad:
        return 0

    red, reset = "\033[31m", "\033[0m"
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
