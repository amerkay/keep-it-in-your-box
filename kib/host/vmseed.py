"""Seed a VM's synced copy with what the sync never carries (host/vm.sh).

The sync ignores every guarded path, so nothing seeded here can flow back to the host. Redacted
files go in as their render (key names, never values); protected ones as their real bytes,
because the box must read them (git reads .git/config on every command).
"""

from __future__ import annotations

import io
import os
import sys
import tarfile
from collections.abc import Sequence
from typing import IO

from kib.shared import cli, render, rules

#: Inside a `.git`: big, and holding nothing guarded.
GIT_BULK = ("objects", "refs", "logs", "lfs")


def seed(
    project: str, rule_list: list[rules.Rule], out: IO[bytes], local: Sequence[str] = rules.VM_LOCAL
) -> None:
    """Stream the seed of `project` to `out` as a tar."""
    with tarfile.open(fileobj=out, mode="w|") as tar:
        for top, dirs, files in os.walk(project):
            in_git = os.path.basename(top) == ".git"
            dirs[:] = [d for d in dirs if d not in local and not (in_git and d in GIT_BULK)]
            for name in files:
                path = os.path.join(top, name)
                rel = os.path.relpath(path, project)
                verdict = rules.verdict(rule_list, rel)
                if verdict == rules.PROTECT or (verdict is None and rules.git_sensitive(rel)):
                    tar.add(path, arcname=rel, recursive=False)  # a symlink stays a symlink
                elif verdict == rules.REDACT:
                    # Never through a symlink: it would render a host file outside the project.
                    data = render.STUB if os.path.islink(path) else render.render(path)
                    info = tarfile.TarInfo(rel)
                    info.size, info.mode = len(data), 0o644
                    tar.addfile(info, io.BytesIO(data))


def _seed_cmd(guard_file: str, rule_file: str, project: str, skip: str) -> int:
    """`seed <guard-file> <rule-file> <project> <skip>` — the tar on stdout."""
    rule_list = rules.load(guard_file, guard=True) + rules.load(rule_file)
    seed(project, rule_list, sys.stdout.buffer, rules.vm_local(skip))
    return cli.OK


def main(argv: list[str]) -> int:
    return cli.dispatch("kib.host.vmseed", {"seed": (_seed_cmd, 4)}, argv)


if __name__ == "__main__":
    cli.run(main)
