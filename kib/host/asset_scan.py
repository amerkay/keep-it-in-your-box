"""Scan a shared PROMPT-asset tree (`~/.claude/skills|agents|commands`) for what must not be
shared: an AUTO-run command, or a symlink pointing out of the tree.

Those three trees mount writable and shared with every project because they hold prompt text.
With `plugins/` and `hooks/` locked, a skill directory is the obvious next parking spot for the
same payload — so this is the check that keeps the premise true.

The line is **auto-execution, not executability**. A `hooks` / `mcpServers` block's `command`
runs with no one deciding to run it, which is exactly why `plugins/` and `hooks/` are locked. A
bundled script is different: it runs only if the agent reads the skill and chooses to, and a
skill that is pure prose saying "now run this installer" is just as dangerous and cannot be
detected at all. Refusing the exec bit would therefore buy almost nothing while breaking
ordinary skills — most non-trivial ones ship a helper script. So scripts pass, `command` does
not.

A symlink out of the tree is the other half, and it is a READ primitive rather than an exec
one: these trees are host-backed and NOT behind the redaction FUSE, so `skills/x/SKILL.md ->
~/.ssh/id_rsa` persists to host state, auto-loads into every future session and into the host's
own unsandboxed `claude` — and the skill loader follows it and ingests the target. Content the
box cannot read itself, delivered by the host. (audit MAC-M1)

Two limits worth knowing: JSON only for commands (hooks and MCP servers are configured in JSON,
and the host has no YAML parser in the 3.9 stdlib), and this is detection at launch/teardown,
not prevention at write — these trees are plain bind mounts with no layer to interpose on.

Prints one `path — finding` line per finding. Exit: 0 clean · 1 findings · 4 unreadable (fail
closed: a file we cannot check must not pass into every project's next session).
"""

from __future__ import annotations

import json
import os

from kib.shared import cli, dangerous

#: Deep enough for `skills/<name>/references/<file>`, bounded so a pathological tree cannot
#: turn the walk into unbounded work.
MAX_DEPTH = 6

#: Keys below which a `command` is the host's to run. The scan starts DISARMED and only reports
#: under one of these: a skill's own prose may mention a command, and flagging that trains the
#: user to ignore the warning that matters.
ARM_KEYS = ("hooks", "mcpServers")


def _escaped_target(full: str, root_real: str) -> str | None:
    """The resolved target of *full* if it is a symlink landing outside the tree, else None.

    Judged on the fully resolved target, so a chain through an in-tree link is followed to
    where it really lands. A link that stays inside the tree is ordinary skill plumbing.
    """
    if not os.path.islink(full):
        return None
    target = os.path.realpath(full)
    if target == root_real or target.startswith(root_real + os.sep):
        return None
    return target


def scan(root: str) -> int:
    findings: list[str] = []
    root = root.rstrip(os.sep)  # else the depth below is off by one for a trailing slash
    root_real = os.path.realpath(root)
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        if dirpath[len(root) :].count(os.sep) >= MAX_DEPTH:
            dirnames[:] = []
            continue
        # Dirs as well as files: `skills/x -> ~/.ssh` shares a whole directory, and the walk
        # does not descend into it (followlinks=False), so this is its only sighting.
        escaping = set()
        for name in dirnames + filenames:
            full = os.path.join(dirpath, name)
            target = _escaped_target(full, root_real)
            if target is not None:
                escaping.add(name)
                findings.append(f"{full} — a symlink out of the tree, to {target}")
        for name in filenames:
            # Already a finding, and opening it would pull the out-of-tree target's contents
            # in here — the very thing this refuses to let a skill do.
            if not name.endswith(".json") or name in escaping:
                continue
            full = os.path.join(dirpath, name)
            try:
                with open(full, encoding="utf-8", errors="replace") as fh:
                    cfg = json.load(fh)
            except ValueError:
                continue  # not JSON despite the name — nothing executes it either
            except OSError as e:
                print(f"{full} — cannot read it ({e.strerror})")
                return cli.UNREADABLE
            findings += [
                f"{full} — {c}" for c in dangerous.json_commands(cfg, arm=ARM_KEYS, armed=False)
            ]
    if not findings:
        return cli.OK  # print nothing: a clean tree is silent, so callers can test the output
    print("\n".join(findings))
    return cli.FAIL


def main(argv: list[str]) -> int:
    return cli.dispatch("kib.host.asset_scan", {"scan": (scan, 1)}, argv)


if __name__ == "__main__":
    cli.run(main)
