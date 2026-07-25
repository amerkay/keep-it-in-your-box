"""`.kibignore` — parsed, matched and translated in exactly one place.

The FUSE guard, the launch-time audit gate and the `.gitignore` sync all read this module, so
anchoring, negation and unsafe-rule skipping mean one thing everywhere. It existed three times
before — matcher, pre-commit copy, bash translation — and had already drifted.

Syntax (gitignore-shaped, with two additions the guard file needs):

    name            one path segment, matching at any depth, never inside `.git`
    dir/name        the whole path, relative to the project root; `*` never crosses `/`
    !rule           re-include — rules apply in order and the last match wins
    #               comment; a leading `/` or a `..` component is unsafe and skipped

A path under an already-matched parent directory cannot be re-included — git's own
parent-exclusion rule, and why `dir/*` + `!dir/keep` behaves as people expect.

Guard rules (`guest/policy/global.kibignore`, `guard=True`) add `[protect]` / `[redact]`
sections and are TAIL-anchored, so `.git/config` covers `sub/.git/config` at any depth. They
are immune to a project's negation — a repo cannot write `!.git/config` to disarm its own
guard — while still negating each other, which is what lets `.env.*` redact broadly and
`!.env.example` carve the committed placeholder back out.
"""

import fnmatch
from collections.abc import Iterable, Sequence
from dataclasses import dataclass

from kib.shared import cli

#: The per-project rule file. Named once here; bash and the audit gate both read it back.
RULE_FILE = ".kibignore"

#: Verdicts, weakest first. 'redact' serves a stub on read and EACCES on write; 'protect'
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
    return all(fnmatch.fnmatch(a, p) for a, p in zip(parts, pattern_parts, strict=True))


def verdict(rules: Sequence[Rule], rel: str) -> str | None:
    """`None` | 'redact' | 'protect' for one project-relative path.

    Guard and project rules are tallied separately and the guard wins when it has a
    verdict — that separation is what makes guard rules immune to a project's `!`.
    """
    parts = rel.split("/")
    under_git = parts[0] == ".git"
    guard: str | None = None
    project: str | None = None
    for i in range(1, len(parts) + 1):
        ancestor = "/".join(parts[:i])
        segment = parts[i - 1]
        for rule in rules:
            if _rule_matches(rule, ancestor, segment, under_git):
                if rule.immune:
                    guard = None if rule.negated else rule.action
                else:
                    project = None if rule.negated else rule.action
        # A matched proper-ancestor directory seals everything beneath it.
        effective = guard or project
        if effective and i < len(parts):
            return effective
    return guard or project


def matches(rules: Sequence[Rule], rel: str) -> bool:
    """True if any rule covers this path. The audit gate's staged/tracked-path test."""
    return verdict(rules, rel) is not None


def to_gitignore(rules: Iterable[Rule]) -> list[str]:
    """Translate project rules to gitignore syntax.

    Bare names match anywhere (as they do in gitignore); a rule containing `/` anchors at
    the repo root. `parse()` has already dropped the unsafe forms and detached the `!`, so
    the anchoring `/` lands *after* the negation — `!/foo`, never `/!foo`, which would be a
    literal path beginning with `!` and negate nothing.
    """
    out = []
    for rule in rules:
        anchor = "/" if rule.anchor == EXACT else ""
        out.append(f"{'!' if rule.negated else ''}{anchor}{rule.pattern}")
    return out


def _to_gitignore_cmd(path: str) -> int:
    """`to-gitignore <rule-file>` — one translated pattern per line, for the bash sync."""
    for line in to_gitignore(load(path)):
        print(line)
    return cli.OK


def main(argv: list[str]) -> int:
    return cli.dispatch("kib.shared.rules", {"to-gitignore": (_to_gitignore_cmd, 1)}, argv)


if __name__ == "__main__":
    cli.run(main)
