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


def load_rules(path):
    """Ordered list of (negated, pattern, is_exact); order preserved so a
    later '!' rule re-includes a path an earlier rule matched."""
    rules = []
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


def matches(rel, rules):
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
                    fnmatch.fnmatch(a, p) for a, p in zip(anc, ppar)
                )
            else:
                hit = not under_git and fnmatch.fnmatch(seg, pat)
            if hit:
                ignored = not neg
        # A masked proper-ancestor directory seals everything beneath it.
        if ignored and i < len(parts):
            return True
    return ignored


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

    rules = load_rules(ccignore)
    if not rules:
        return 0

    out = subprocess.check_output(["git", "diff", "--cached", "--name-only", "-z"])
    staged = [p for p in out.decode().split("\0") if p]
    bad = [p for p in staged if matches(p, rules)]
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
