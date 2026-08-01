"""The audit gate, run host-side where kib already runs rather than from a file written into
every project's `.git/hooks/pre-commit` — kib's own guard refuses `core.hooksPath`, so a
git-native hook was never an option, and a copied-in one would litter every repo touched.

Two severities, and the asymmetry is deliberate:

* **Refuse** on a host-executed git config key, or an executable hook in a nested git dir.
  `core.fsmonitor` fires on a bare `git status`, before the user reads a single diff, so
  launching a session into it is the wrong default.
* **Warn** on a tracked path that matches `.kibignore` (the user's own hygiene; blocking a
  session over it would be hostile), and on project config that names a command the host runs —
  `.claude/settings*.json`, `.mcp.json`, `mise.toml`, a `.claude-plugin/` manifest, anything under
  `.claude/hooks/`. That class is *deliberate-trigger*: none of it fires until someone launches
  `claude`, so a report reaches the user in time. `[protect]` is reserved for what fires on an
  ordinary commit, `cd` or editor-open, where no report can. (`redaction-config-guard.md`)

Accepted loss versus the hook: commit-time *blocking* is gone, so a commit made between
sessions is unchecked. The FUSE guard remains the preventer — this is the detector. For the
project TREES that detector is git-blind by construction (the box can commit, so it decides what
"tracked" means), which is why `_since_stamp` unions an mtime pass over the git one.

Exit: 0 clean · 1 warn-class findings only · 5 refuse-class findings. On 1, stdout carries one
line naming the warn classes that fired (`Findings.warn_summary`) — the caller's alert text.
Findings themselves are stderr, always, so a caller may capture stdout without hiding them.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections.abc import Sequence
from dataclasses import dataclass, field

from kib.host import asset_scan
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
    project: list[str] = field(default_factory=list)  # warn

    @property
    def refuse(self) -> bool:
        return bool(self.config or self.hooks)

    @property
    def any(self) -> bool:
        return bool(self.config or self.hooks or self.tracked or self.project)

    @property
    def warn_summary(self) -> str:
        """Which warn classes fired, for the caller's teardown alert. Empty when none did.

        Here rather than in host/gitguard.sh because the two classes read nothing alike, and a
        popup naming the wrong one is worse than no popup: the alert said "tracked paths match
        .kibignore" for a plugin hook the session had just written.
        """
        parts = []
        if self.tracked:
            parts.append(f"tracked paths match {rules.RULE_FILE}")
        if self.project:
            parts.append("project config the host runs")
        return " + ".join(parts)


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

    The top-level `.git/hooks` is left alone: it is the user's own, and the FUSE guard already
    refuses writes to it. This walk is the *host*-side second opinion for the nested cases —
    hooks that were already on disk before kib ever ran, in a submodule or sub-repo.
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


# ── mixed-use project config ─────────────────────────────────────
# Files that name a command the HOST runs, but that ordinary work also edits. A `[protect]`
# rule would refuse an everyday write, and the sandbox policy tells the agent to STOP on that
# error — so an editable file in the guard ends a session over routine work. These are
# detected instead: warn-class, never refuse.
#
# Reported only when git shows the path dirty or untracked. The audit sees state, not change,
# and a committed config is the user's own; that filter is the cheap proxy for "touched during
# a session" and takes false positives on a clean checkout to zero.

#: Tail-matched, like the FUSE guard's rules — a `.claude/settings.json` in a subdirectory is
#: the one that loads when the user works there. Value picks the scanner.
PROJECT_CONFIGS = (
    (".claude/settings.json", "claude"),
    (".claude/settings.local.json", "claude"),
    (".mcp.json", "json"),
    (".zed/settings.json", "json"),
    # A repo published as a plugin — the multi-repo-workspace marketplace pattern. Its manifest
    # may declare hooks/MCP servers inline, or POINT at a file that does; both are reported, and
    # the pointer is followed exactly one level (`_plugin_findings`).
    (".claude-plugin/plugin.json", "plugin"),
    (".claude-plugin/marketplace.json", "marketplace"),
)

#: Whole DIRECTORIES whose contents are the finding, rather than a file with a schema. Value is
#: what one entry is, for the report line. `.claude/hooks` was `[protect]`ed until the tier split
#: was restated as ambient-vs-deliberate: nothing in there loads until a pointer names it and
#: `claude` is launched, which is a deliberate act detection reaches in time — unlike `.git/hooks`
#: or `.envrc`, which fire on an ordinary commit or `cd`. (`redaction-config-guard.md`)
PROJECT_TREES = ((".claude/hooks", "hook script"),)

#: Regex tier — python 3.9 has no `tomllib` and neither side has a YAML parser. Acceptable
#: here and nowhere else, because this tier only warns: a false positive costs one line.
#: Matched on the *pivot* keys only. A mise `[tasks]` entry or a cargo alias runs when the
#: user invokes it by name, which is the same "someone chose to" line the shared-assets tier
#: draws — `[hooks]` and `_.source` fire on a bare `cd`, with no such decision.
_MISE_PIVOTS = re.compile(r"^\s*(\[hooks\]|_\.source\s*=)", re.M)
TEXT_CONFIGS = (
    (".cargo/config.toml", re.compile(r"^\s*(rustc-wrapper|runner|linker)\s*=", re.M)),
    ("mise.toml", _MISE_PIVOTS),
    (".mise.toml", _MISE_PIVOTS),
    # `- ` because the key is usually the first in a list item. `entry:` in a *consumer*
    # config is the local-hook signal: a remote hook names only repo/rev/id.
    (".pre-commit-config.yaml", re.compile(r"^\s*(?:-\s*)?entry\s*:.*", re.M)),
)


#: One pathspec per config name, matching it at the root and at any depth — the same tails
#: `_tail_match` accepts, handed to git so the `--ignored` widening below stays bounded. Trees
#: take a `/**` tail instead: everything under them counts, at any depth.
CONFIG_PATHSPECS = tuple(
    [f":(glob)**/{name}" for name, _ in (*PROJECT_CONFIGS, *TEXT_CONFIGS)]
    + [f":(glob)**/{name}/**" for name, _ in PROJECT_TREES]
)


def _tail_match(rel: str, name: str) -> bool:
    return rel == name or rel.endswith("/" + name)


def _tree_match(rel: str, tree: str) -> bool:
    """Is *rel* under a `<anything>/<tree>/` directory (or under `<tree>/` at the root)?"""
    return ("/" + rel).find("/" + tree + "/") != -1


def _dirty(top: str, pathspecs: Sequence[str]) -> list[str]:
    """Paths git reports modified, staged or untracked — the proxy for "changed since commit".

    With `pathspecs`, ignored files are included too, and the listing is limited to them:
    plain `status` hides an ignored path, and `.claude/settings.local.json` — the file Claude
    writes "always allow" into — is gitignored in most repos, so the highest-traffic config of
    the set was the one the audit could never see. Repo-wide, `--ignored --untracked-files=all`
    would enumerate every path under node_modules, hence the pathspec.

    A rename or copy carries a second NUL-separated path; consume it, or the origin reads as
    the next entry's status field and every later path shifts by three characters.
    """
    args = ["status", "--porcelain", "-z", "--untracked-files=all"]
    if pathspecs:
        args += ["--ignored=traditional", "--", *pathspecs]
    entries = iter(_git(args, top).split("\0"))
    dirty: list[str] = []
    for entry in entries:
        if len(entry) < 4:
            continue
        dirty.append(entry[3:])
        if entry[0] in "RC":
            next(entries, None)
    return dirty


def _scan_json(path: str, kind: str) -> list[str]:
    """`settings_findings` for a Claude settings file, the generic walk for anything else.

    Unreadable or malformed is silence, not a finding: this tier warns about what it can
    prove, and Claude ignores an unparseable settings file anyway.

    `RecursionError` is caught with them, and it is not hypothetical: `[`×30000 is 60 KB of
    valid JSON that overflows the decoder, and both the walk above and `settings_findings`
    recurse as well. Uncaught, a repo could crash the audit at every cold start by committing
    one file — a denial of launch from repo content, in the one check meant to survive it.
    """
    try:
        with open(path) as fh:
            cfg = json.load(fh)
        if not isinstance(cfg, dict):
            return []
        return (
            dangerous.settings_findings(cfg) if kind == "claude" else dangerous.json_commands(cfg)
        )
    except (OSError, ValueError, RecursionError):
        return []


def _plugin_findings(top: str, rel: str, path: str) -> list[str]:
    """A `.claude-plugin/plugin.json`: what it declares inline, plus what its pointers name.

    Publishing a repo as a plugin is the sanctioned way to ship a repo-local hook — the manifest
    is where `hooks` is declared or redirected — so this is the file that has to be reported, not
    refused. A pointer is followed exactly one level and only inside the repo; asset_scan owns
    that resolver, so the shared-tree and project-tree audits cannot drift on what a pointer is.
    """
    cfg = _load_manifest(path)
    if cfg is None:
        return []
    found = ["a plugin manifest — this repo loads as a Claude Code plugin"]
    found += dangerous.json_commands(cfg)
    base = os.path.dirname(os.path.dirname(path))  # the plugin root, above .claude-plugin/
    top_real = os.path.realpath(top)
    for key, target, ok in asset_scan.pointer_paths(cfg, base, top_real):
        # Against top_REAL: the target is already resolved, so relpath'ing it to an unresolved
        # top prints a `../../..` walk whenever the repo path runs through a symlink (/tmp on
        # macOS is /private/tmp), which reads as an escape that did not happen.
        shown = os.path.relpath(target, top_real) if ok else target
        if not ok:
            found.append(f"{key} points OUT of the repo, to {shown}")
            continue
        pointed = _load_manifest(target)
        found.append(f"{key} -> {shown}")
        if pointed is not None:
            found += [f"{shown}: {c}" for c in dangerous.json_commands(pointed)]
    return [f"{rel}: {line}" for line in found]


def _load_manifest(path: str) -> object:
    """Parsed JSON, or None. Same error discipline as `_scan_json` — see its docstring."""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return json.load(fh)
    except (OSError, ValueError, RecursionError):
        return None


def _marketplace_findings(rel: str, path: str) -> list[str]:
    """A `marketplace.json` publishes plugins; it names no command of its own.

    What each published plugin runs lives in that plugin's own manifest, which is two hops away —
    and one hop is the bound everywhere else here. So this names what is published and stops.
    """
    cfg = _load_manifest(path)
    if not isinstance(cfg, dict):
        return []
    plugins = cfg.get("plugins")
    # `or`, then dropped if neither: an entry with no name and no source would otherwise be
    # published to the user as the literal string "None".
    names = [
        str(p.get("name") or p.get("source"))
        for p in (plugins if isinstance(plugins, list) else [])
        if isinstance(p, dict) and (p.get("name") or p.get("source"))
    ]
    if not names:
        return []
    return [f"{rel}: publishes {', '.join(names)} as plugins to any workspace adding it"]


def _since_stamp(top: str, stamp: str | None) -> list[str]:
    """Paths under a `PROJECT_TREES` directory modified since *stamp* was last touched.

    The git filter alone is bypassable, and known to be: the box can `git commit`, so it decides
    what "tracked" means, and a committed hook checks out pristine past a dirty-file detector —
    the hole that got the worktree-editor carve-out reverted. The timestamp pass is the second
    opinion that does not care what git thinks. The two are unioned, never traded off.

    `asset_scan.changed_at`, not `st_mtime`: the box owns these files, so mtime alone is
    something the payload can back-date past the stamp with one `touch`. ctime moves on every
    write and no unprivileged caller can wind it back.

    No stamp yet means the stamp is being created now, so report NOTHING: hooks already sitting
    in a fresh clone are the user's own, the same judgement `audit_nested_hooks` makes about the
    top-level `.git/hooks`.
    """
    if not stamp:
        return []
    try:
        newer_than = os.stat(stamp).st_mtime
    except OSError:
        return []
    found: list[str] = []
    for dirpath, dirnames, filenames in os.walk(top):
        dirnames[:] = [d for d in dirnames if d not in PRUNE_DIRS]
        rel_dir = os.path.relpath(dirpath, top).replace(os.sep, "/") + "/"
        if not any(_tree_match(rel_dir, tree) for tree, _ in PROJECT_TREES):
            continue
        for name in filenames:
            full = os.path.join(dirpath, name)
            if asset_scan.changed_at(full) <= newer_than:
                continue
            found.append(os.path.relpath(full, top).replace(os.sep, "/"))
    return found


def audit_project_configs(top: str, stamp: str | None = None) -> list[str]:
    """Uncommitted project config naming a command the host runs. Warn-class."""
    found: list[str] = []
    # Union, not either/or: git sees a change the mtime stamp missed (a file older than the
    # stamp, edited before it), and the stamp sees one git cannot (a commit made from the box).
    seen = set()
    for rel in [*_dirty(top, CONFIG_PATHSPECS), *_since_stamp(top, stamp)]:
        # A vendored copy under node_modules/ is a dependency's own file, and only loads if
        # the user works from inside it — the same judgement PRUNE_DIRS already makes.
        if rel in seen or PRUNE_DIRS.intersection(rel.split("/")[:-1]):
            continue
        seen.add(rel)
        path = os.path.join(top, rel)
        for tree, what in PROJECT_TREES:
            if _tree_match(rel, tree):
                found.append(f"{rel}: a {what} — it runs when a settings file or plugin names it")
        for name, kind in PROJECT_CONFIGS:
            if not _tail_match(rel, name):
                continue
            if kind == "plugin":
                found += _plugin_findings(top, rel, path)
            elif kind == "marketplace":
                found += _marketplace_findings(rel, path)
            else:
                found += [f"{rel}: {line}" for line in _scan_json(path, kind)]
        for name, pattern in TEXT_CONFIGS:
            if not _tail_match(rel, name):
                continue
            try:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
            except OSError:
                continue
            found += [f"{rel}: {m.group(0).strip()}" for m in pattern.finditer(text)]
    return found


def audit(top: str, stamp: str | None = None) -> Findings:
    """Every check, against one repository root."""
    return Findings(
        config=audit_git_config(top) + audit_nested_gitdirs(top),
        hooks=audit_nested_hooks(top),
        tracked=audit_tracked(top),
        project=audit_project_configs(top, stamp),
    )


def report(findings: Findings, refusing: bool, host_claude: str = "") -> None:
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
    if findings.project:
        w("\n⚠️  kib: uncommitted project config naming a command the HOST runs:\n")
        for line in findings.project:
            w(f"    {line}\n")
        w(
            "\nThese files are editable on purpose, so the sandbox is not blocked from\n"
            "writing them — read the diff before the host runs the tool that loads them.\n"
        )
        # Unconditional finding, conditional wording: the list itself matters either way (the
        # next box to open this repo loads it), but "runs on YOUR machine" is only true when
        # there is an unsandboxed reader, and claiming it otherwise is what makes a warning
        # stop being read.
        if host_claude:
            w(f"A native claude at {host_claude} loads them OUTSIDE any sandbox.\n")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="kib audit", description="host-executed config audit")
    ap.add_argument("--top", required=True, help="repository root to audit")
    ap.add_argument(
        "--mode",
        choices=("launch", "teardown", "report"),
        default="report",
        help="launch exits 5 on a refuse-class finding; teardown/report are never fatal",
    )
    ap.add_argument(
        "--hooks-stamp",
        default="",
        help="file whose mtime bounds the project-tree scan; absent means report nothing there",
    )
    ap.add_argument(
        "--host-claude", default="", help="path to a native claude, for the report's wording only"
    )
    args = ap.parse_args(argv)

    if not os.path.isdir(os.path.join(args.top, ".git")) and not os.path.isdir(args.top):
        return cli.OK  # not a repo (or gone) — nothing to audit, silently

    findings = audit(args.top, args.hooks_stamp)
    if not findings.any:
        return cli.OK
    report(
        findings,
        refusing=args.mode == "launch" and findings.refuse,
        host_claude=args.host_claude,
    )
    if findings.refuse:
        return cli.REFUSED
    # stdout is the CALLER's channel, one line, read by host/gitguard.sh to title its teardown
    # alert. Everything meant for the user goes to stderr via report() — never here, or the
    # command substitution reading this would swallow the findings themselves.
    print(findings.warn_summary)
    return cli.FAIL


if __name__ == "__main__":
    cli.run(main)
