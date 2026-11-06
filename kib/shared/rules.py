"""`.kibignore` — parsed and matched in exactly one place.

The FUSE guard and the launch-time audit gate both read this module, so anchoring, negation and
unsafe-rule skipping mean one thing everywhere. A second copy of this logic drifts from the
first, and the drift shows up as a guard that admits a write.

Syntax (gitignore-shaped, with two additions the guard file needs):

    name            one path segment, matching at any depth, never inside `.git`
    dir/name        the whole path, relative to the project root; `*` never crosses `/`
    !rule           re-include — rules apply in order and the last match wins
    #               comment; a leading `/` or a `..` component is unsafe and skipped

A path under an already-matched parent directory cannot be re-included — git's own
parent-exclusion rule, and why `dir/*` + `!dir/keep` behaves as people expect.

Guard rules (`guest/policy/global.kibignore`, `guard=True`) add `[protect]` / `[redact]`
sections and are TAIL-anchored, so `.git/config` covers `sub/.git/config` at any depth. They
negate each other, which is what lets `.env.*` redact broadly and `!.env.example` carve the
committed placeholder back out.

`[protect]` is immune to a project's negation — a repo cannot write `!.git/config` to disarm
the host-execution guard. `[redact]` is NOT: a project's `!` on the same component cancels it,
so a repo whose `.env` holds no secrets can hand it to the session (`redact_optouts()` names
those rules, and the launch prints them). The asymmetry is the two tiers' threat models —
`[protect]` stops the box writing what the HOST later runs, and no repo may waive that;
`[redact]` withholds the user's own secrets from the session, which is the user's to waive.
"""

from __future__ import annotations

import fnmatch
import json
import re
from collections.abc import Iterable, Sequence
from dataclasses import dataclass

from kib.shared import cli

#: The per-project rule file. Named once here; bash and the audit gate both read it back.
RULE_FILE = ".kibignore"

#: Verdicts, weakest first. 'redact' serves keys-without-values or a stub on read, and refuses
#: writes (EPERM — see `REFUSED` in kib/guest/fuse.py); 'protect'
#: reads through and refuses writes (masking `.git/config` would break in-container git,
#: which reads it on virtually every command).
REDACT = "redact"
PROTECT = "protect"
GUARD_SECTIONS = (PROTECT, REDACT)

#: Where a pattern is allowed to match.
BARE = "bare"  # one segment, any depth, never under .git
EXACT = "exact"  # the whole path, from the project root
TAIL = "tail"  # trailing components, any depth (guard rules only)


@dataclass(frozen=True)
class Rule:
    """One parsed rule. Order within a rule list is significant: last match wins."""

    negated: bool
    pattern: str
    anchor: str
    action: str
    immune: bool  # a guard rule: a project's '!' cannot cancel it

    def __str__(self) -> str:
        return ("!" if self.negated else "") + self.pattern


def parse(lines: Iterable[str], guard: bool = False) -> list[Rule]:
    """Parse rule text into an ordered list. Unsafe rules are dropped with a warning."""
    from kib.shared.log import get_logger  # local: keeps the guest import graph shallow

    log = get_logger("kib.rules")
    rules: list[Rule] = []
    action = REDACT
    for raw in lines:
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if guard and line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip().lower()
            if section not in GUARD_SECTIONS:
                log.warning("kib: unknown guard section %r", line)
                continue
            action = section
            continue
        negated = line.startswith("!")
        if negated:
            line = line[1:].strip()
        line = line.rstrip("/")
        if not line:
            continue
        if line.startswith("/") or ".." in line.split("/"):
            log.warning("kib: skipping unsafe rule %r", line)
            continue
        if guard:
            rules.append(Rule(negated, line, TAIL, action, True))
        else:
            rules.append(Rule(negated, line, EXACT if "/" in line else BARE, REDACT, False))
    return rules


def load(path: str, guard: bool = False) -> list[Rule]:
    """Parse a rule file. An absent file is an empty rule set, not an error."""
    try:
        with open(path) as fh:
            return parse(fh, guard=guard)
    except FileNotFoundError:
        return []


def _rule_matches(rule: Rule, ancestor: str, segment: str, under_git: bool) -> bool:
    """True if one rule matches this ancestor path / final segment.

    Every anchor compares component-by-component, so a `*` never spans a `/`.
    """
    if rule.anchor == BARE:
        return not under_git and fnmatch.fnmatch(segment, rule.pattern)
    parts = ancestor.split("/")
    pattern_parts = rule.pattern.split("/")
    if rule.anchor == TAIL:
        if len(pattern_parts) > len(parts):
            return False
        parts = parts[len(parts) - len(pattern_parts) :]
    elif len(pattern_parts) != len(parts):
        return False
    # Both branches above have equalised the lengths, so plain zip drops nothing.
    # `strict=` is deliberately absent: this module must import on python 3.9 (stock macOS).
    return all(fnmatch.fnmatch(a, p) for a, p in zip(parts, pattern_parts))


def verdict(rules: Sequence[Rule], rel: str) -> str | None:
    """`None` | 'redact' | 'protect' for one project-relative path.

    Guard and project rules are tallied separately and the guard wins when it has a verdict —
    that separation is what makes `[protect]` immune to a project's `!`. The one crack in it is
    the documented opt-out: a project `!` cancels a `[redact]` guard rule matched at the SAME
    path component. Same component, so `!secrets` cannot un-redact `secrets/.env` in passing.
    """
    parts = rel.split("/")
    under_git = parts[0] == ".git"
    guard: str | None = None
    project: str | None = None
    guard_at = optout_at = -1
    effective: str | None = None
    for i in range(1, len(parts) + 1):
        ancestor = "/".join(parts[:i])
        segment = parts[i - 1]
        for rule in rules:
            if _rule_matches(rule, ancestor, segment, under_git):
                if rule.immune:
                    guard = None if rule.negated else rule.action
                    guard_at = i
                else:
                    project = None if rule.negated else rule.action
                    if rule.negated:
                        optout_at = i
        effective = None if guard == REDACT and optout_at == guard_at else guard
        # A matched proper-ancestor directory seals everything beneath it.
        effective = effective or project
        if effective and i < len(parts):
            return effective
    return effective


def matches(rules: Sequence[Rule], rel: str) -> bool:
    """True if any rule covers this path. The audit gate's staged/tracked-path test."""
    return verdict(rules, rel) is not None


def redact_optouts(guard_rules: Sequence[Rule], project_rules: Iterable[Rule]) -> list[str]:
    """Project `!` rules that hand a guard-`[redact]` path back to the session.

    The launch names these (host/redaction.sh): the box can write `.kibignore`, so the one
    thing standing between a smuggled `!.env` and a full read of it is the user seeing it.
    Reported as RULES, not as a filesystem scan — no tree walk, and it says the same thing
    whether or not the file exists yet.
    """
    # REDACT only: a `!` aimed at a [protect] rule is inert, and reporting it would teach the
    # user that every negation un-guards something.
    return [
        r.pattern for r in project_rules if r.negated and verdict(guard_rules, r.pattern) == REDACT
    ]


def tightens(old: Sequence[Rule], new: Sequence[Rule]) -> bool:
    """True if `new` can only withhold MORE than `old` — the live-reload gate.

    A project rule that is not negated only ever ADDS a redact verdict (see `verdict`), so a
    list keeping every old rule and adding none that are negated cannot hand the session a path
    it could not already read. SUBSEQUENCE, not subset: rules are last-match-wins, so swapping
    `!foo` and `foo` flips the verdict with the set unchanged.
    """
    remaining = iter(new)
    kept_in_order = all(rule in remaining for rule in old)  # `old` is a subsequence of `new`
    return kept_in_order and not any(rule.negated for rule in set(new) - set(old))


#: git's own host-executed paths (kib/guest/fuse.py `_git_sensitive`), as Mutagen globs.
GIT_SENSITIVE = ("**/.git/**/config", "**/.git/**/config.worktree", "**/.git/**/hooks")


def git_sensitive(rel: str) -> bool:
    """`GIT_SENSITIVE` as a predicate."""
    p = rel.split("/")
    if p[-1] in ("config", "config.worktree") and ".git" in p[:-1]:
        return True
    return any(x == "hooks" and ".git" in p[:i] for i, x in enumerate(p))


def _glob(rule: Rule) -> str:
    """One rule in Mutagen's doublestar syntax: escape what fnmatch reads literally, and make
    `**` one segment again (doublestar's spans directories)."""
    p = "".join({"\\": "\\\\", "{": "[{]", "}": "[}]"}.get(c, c) for c in rule.pattern)
    p = re.sub(r"\*\*+", "*", p)
    if rule.anchor == EXACT:
        p = "/" + p
    elif rule.anchor == TAIL and "/" in p:
        p = "**/" + p
    return ("!" if rule.negated else "") + p


def sync_ignores(guard: Sequence[Rule], project: Sequence[Rule]) -> list[str]:
    """Mutagen `--ignore`s dropping every path `verdict` guards. Mutagen is one last-match-wins
    list, so the order rebuilds `verdict`'s tiers: a project `!` follows `[redact]` and can
    cancel it, and `[protect]` comes last, out of its reach."""
    out = [_glob(r) for r in guard if r.action == REDACT]
    for r in project:
        out.append(_glob(r))
        if r.anchor == BARE and not r.negated:  # kib's bare rules never match in the root .git
            out.append("!/.git/**/" + _glob(r))
            if fnmatch.fnmatch(".git", r.pattern):
                out.append("!/.git")
    return out + [_glob(r) for r in guard if r.action == PROTECT] + list(GIT_SENSITIVE)


def _optouts_cmd(guard_file: str, rule_file: str) -> int:
    """`optouts <guard-file> <rule-file>` — one un-redacting project rule per line."""
    for pattern in redact_optouts(load(guard_file, guard=True), load(rule_file)):
        print(pattern)
    return cli.OK


def _tightens_cmd(old_file: str, new_file: str) -> int:
    """`tightens <old-rules> <new-rules>` — status 0 if the new set can only redact more."""
    return cli.OK if tightens(load(old_file), load(new_file)) else cli.REFUSED


#: Never synced: the box builds its own in the VM, for Linux, whatever the host's OS. Caches too:
#: a box's `.pnpm-store` lands in the project (pnpm's store must share its filesystem).
VM_LOCAL = (
    *("node_modules", ".pnpm-store", ".next", ".nuxt", ".turbo", "target", ".terraform"),
    *(".venv", "venv", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache"),
)


def vm_local(skip: str) -> list[str]:
    """`VM_LOCAL` plus the user's `vm_skip` names (config: comma- or space-separated). First in
    every list, so a later guard rule always wins over one."""
    return [*VM_LOCAL, *skip.replace(",", " ").split()]


def _print_sync_config(paths: list[str]) -> int:
    """A Mutagen `-c` file. Not `--ignore`: the CLI splits that on commas."""
    print(json.dumps({"sync": {"defaults": {"ignore": {"paths": paths}}}}))
    return cli.OK


def _sync_config_cmd(guard_file: str, rule_file: str, skip: str) -> int:
    """`sync-config <guard-file> <rule-file> <skip>` — project ⇄ shadow: the guard applies here."""
    return _print_sync_config(
        [*vm_local(skip), *sync_ignores(load(guard_file, guard=True), load(rule_file))]
    )


def _vm_sync_config_cmd(skip: str) -> int:
    """`vm-sync-config <skip>` — shadow ⇄ VM: the shadow holds nothing guarded, build dirs only."""
    return _print_sync_config(vm_local(skip))


def main(argv: list[str]) -> int:
    return cli.dispatch(
        "kib.shared.rules",
        {
            "optouts": (_optouts_cmd, 2),
            "tightens": (_tightens_cmd, 2),
            "sync-config": (_sync_config_cmd, 3),
            "vm-sync-config": (_vm_sync_config_cmd, 1),
        },
        argv,
    )


if __name__ == "__main__":
    cli.run(main)
