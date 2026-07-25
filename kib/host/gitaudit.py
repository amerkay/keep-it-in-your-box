"""The audit gate, run host-side where kib already runs rather than from a file written into
every project's `.git/hooks/pre-commit` — kib's own guard refuses `core.hooksPath`, so a
git-native hook was never an option, and a copied-in one would litter every repo touched.

Two severities, and the asymmetry is deliberate:

* **Refuse** on a host-executed git config key, or an executable hook in a nested git dir.
  `core.fsmonitor` fires on a bare `git status`, before the user reads a single diff, so
  launching a session into it is the wrong default.
* **Warn** on a tracked path that matches `.kibignore`. That is the user's own hygiene;
  blocking a session over it would be hostile.

Accepted loss versus the hook: commit-time *blocking* is gone, so a commit made between
sessions is unchecked. The FUSE guard remains the preventer — this is the detector.

Exit: 0 clean · 1 warn-class findings only · 5 refuse-class findings.
"""

import argparse
import os
import subprocess
import sys
from collections.abc import Sequence
from dataclasses import dataclass, field

from kib.shared import cli, dangerous, rules

# Directories a project keeps large and boring. Walking them costs seconds and can hold no
# git dir of interest.
PRUNE_DIRS = {"node_modules", ".venv", "venv", "target", "dist", "build", ".tox"}
# A git dir is identified by its layout, not its name: `git init --bare`,
# `--separate-git-dir` and a `gitdir:` redirect all put config+hooks elsewhere.
GITDIR_MARKERS = ("HEAD", "objects", "refs")


@dataclass
class Findings:
    """What one audit pass turned up, split by what the caller should do about it."""

    config: list[str] = field(default_factory=list)  # refuse
    hooks: list[str] = field(default_factory=list)  # refuse
    tracked: list[str] = field(default_factory=list)  # warn

    @property
    def refuse(self) -> bool:
        return bool(self.config or self.hooks)

    @property
    def any(self) -> bool:
        return bool(self.config or self.hooks or self.tracked)


def _git(args: Sequence[str], cwd: str) -> str:
    """Run git, returning stdout; a failure is an empty result, never an exception."""
    try:
        return subprocess.run(
            ["git", *args], capture_output=True, text=True, check=False, cwd=cwd
        ).stdout
    except OSError:
        return ""


def audit_git_config(top: str) -> list[str]:
    """Local git config entries whose value is a command the host would run.

    `--includes` is what makes this see through `include.path` indirection; without it a
    poisoned config reads as a benign one-liner. `--local` is deliberate — the unscoped
    form would pull in the user's own `~/.gitconfig` (core.pager, alias.*) and flag every
    repo on the machine.
    """
    return dangerous.git_listing_lines(_git(["config", "--local", "--list", "--includes"], top))


def audit_nested_gitdirs(top: str) -> list[str]:
    """Dangerous config in git dirs the top-level scope never sees.

    Bare repos, `--separate-git-dir` targets and gitfile redirects are ordinary directories
    as far as `git config --local` is concerned, yet the host runs what they configure the
    moment it touches that repo.
    """
    bad: list[str] = []
    for dirpath, dirnames, _ in os.walk(top):
        dirnames[:] = [d for d in dirnames if d not in PRUNE_DIRS]
        if not all(os.path.exists(os.path.join(dirpath, m)) for m in GITDIR_MARKERS):
            continue
        # Inside a git dir only nested git dirs matter; objects/ alone is thousands of
        # directories and none of them can hold a config.
        dirnames[:] = [d for d in dirnames if d in ("modules", "worktrees")]
        if dirpath == os.path.join(top, ".git"):
            continue  # the top repo — already covered by audit_git_config()
        cfg = os.path.join(dirpath, "config")
        if not os.path.isfile(cfg):
            continue
        rel = os.path.relpath(dirpath, top)
        listing = _git(["config", "--file", cfg, "--list", "--includes"], top)
        bad += [f"{rel}: {line}" for line in dangerous.git_listing_lines(listing)]
    return bad


def audit_nested_hooks(top: str) -> list[str]:
    """Executable hooks in *nested* git dirs — submodules, worktrees, sub-repos.

    The top-level `.git/hooks` is left alone: it is the user's own, and kib bind-mounts it
    read-only. Nested ones are the gap that mount cannot cover, since a repo can be cloned
    or `git init`ed after the container started.
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


def audit_tracked(top: str) -> list[str]:
    """Tracked paths that match `.kibignore` — hidden from the sandbox, but in git anyway.

    Committing them leaks their real host contents into history and diffs, which is exactly
    what hiding them from the agent was for.
    """
    rule_file = os.path.join(top, rules.RULE_FILE)
    if not os.path.exists(rule_file):
        return []
    rule_list = rules.load(rule_file)
    if not rule_list:
        return []
    out = _git(["ls-files", "-z"], top)
    return [p for p in out.split("\0") if p and rules.matches(rule_list, p)]


def audit(top: str) -> Findings:
    """Every check, against one repository root."""
    return Findings(
        config=audit_git_config(top) + audit_nested_gitdirs(top),
        hooks=audit_nested_hooks(top),
        tracked=audit_tracked(top),
    )


def report(findings: Findings, refusing: bool) -> None:
    """Print findings to stderr, with the remedy for each class."""
    w = sys.stderr.write
    if findings.config or findings.hooks:
        headline = "refusing to launch" if refusing else "found in this repo"
        w(f"\n❌ kib: host-executed config {headline}\n")
    if findings.config:
        w(
            "\nThese git config entries name a command git runs on the HOST\n"
            "(core.fsmonitor fires on a bare `git status`, before you read any diff).\n"
            "An 'include.path' entry counts too: it can pull any of them in from\n"
            "another file. A '<dir>:' prefix means a nested or bare git dir:\n"
        )
        for line in findings.config:
            w(f"    {line}\n")
        w(
            "\nInspect, then remove with:  git config --local --unset <key>\n"
            "                        or:  git config --file <dir>/config --unset <key>\n"
        )
    if findings.hooks:
        w("\nExecutable hooks in nested git dirs:\n")
        for p in findings.hooks:
            w(f"    {p}\n")
        w("\nInspect, then remove or chmod -x them.\n")
    if findings.tracked:
        w(f"\n⚠️  kib: these tracked paths match {rules.RULE_FILE}:\n")
        for p in findings.tracked:
            w(f"    {p}\n")
        w(
            "\nThey are hidden from the sandbox, but git still has their real contents.\n"
            "Untrack with:  git rm --cached <path>\n"
        )


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="kib audit", description="host-executed config audit")
    ap.add_argument("--top", required=True, help="repository root to audit")
    ap.add_argument(
        "--mode",
        choices=("launch", "teardown", "report"),
        default="report",
        help="launch exits 5 on a refuse-class finding; teardown/report are never fatal",
    )
    args = ap.parse_args(argv)

    if not os.path.isdir(os.path.join(args.top, ".git")) and not os.path.isdir(args.top):
        return cli.OK  # not a repo (or gone) — nothing to audit, silently

    findings = audit(args.top)
    if not findings.any:
        return cli.OK
    report(findings, refusing=args.mode == "launch" and findings.refuse)
    if findings.refuse:
        return cli.REFUSED
    return cli.FAIL


if __name__ == "__main__":
    cli.run(main)
