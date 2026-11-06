"""Seed a VM's synced copy with what the sync never carries (host/vm.sh).

The sync ignores every guarded path, so nothing seeded here can flow back to the host. Redacted
files go in as their render (key names, never values); protected ones as their real bytes,
because the box must read them (git reads .git/config on every command).

The shadow is ALSO written by the VM (its hop syncs back), so VM root can plant a symlink in it.
Every write and unlink here goes through directory fds that refuse one: a path, an `open()` or a
`tar -x` would follow it out of the shadow and onto any host file.
"""

from __future__ import annotations

import os
import stat
from collections.abc import Iterator, Sequence

from kib.shared import cli, render, rules

#: Inside a `.git`: big, and holding nothing guarded.
GIT_BULK = ("objects", "refs", "logs", "lfs")
_DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def _guarded(
    project: str, rule_list: list[rules.Rule], local: Sequence[str]
) -> Iterator[tuple[str, str, str]]:
    """(rel, path, verdict) for every file the sync drops: guarded, or git's own executables."""
    for top, dirs, files in os.walk(project):
        in_git = os.path.basename(top) == ".git"
        dirs[:] = [d for d in dirs if d not in local and not (in_git and d in GIT_BULK)]
        for name in files:
            path = os.path.join(top, name)
            rel = os.path.relpath(path, project)
            verdict = rules.verdict(rule_list, rel)
            if verdict is None and rules.git_sensitive(rel):
                verdict = rules.PROTECT
            if verdict:
                yield rel, path, verdict


def _place(root: str, rel: str, src: str, verdict: str) -> None:
    """Write `rel` under `root` — never through a symlink anywhere below `root`."""
    fd = os.open(root, _DIR)
    try:
        *parents, name = rel.split("/")
        for part in parents:
            try:
                os.mkdir(part, 0o755, dir_fd=fd)
            except FileExistsError:
                pass
            nxt = os.open(part, _DIR, dir_fd=fd)  # ELOOP on a planted link: fail closed
            os.close(fd)
            fd = nxt
        try:
            os.unlink(name, dir_fd=fd)
        except FileNotFoundError:
            pass
        if verdict == rules.PROTECT and os.path.islink(src):
            os.symlink(os.readlink(src), name, dir_fd=fd)  # a symlink stays a symlink
            return
        # A redacted symlink is never rendered: it would read a host file outside the project.
        mode = 0o644
        if verdict == rules.REDACT:
            data = render.STUB if os.path.islink(src) else render.render(src)
        else:
            with open(src, "rb") as fh:
                data = fh.read()
            mode = stat.S_IMODE(os.stat(src).st_mode)
        out = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode, dir_fd=fd)
        with os.fdopen(out, "wb") as fh:
            fh.write(data)
    finally:
        os.close(fd)


def seed(
    project: str,
    shadow: str,
    rule_list: list[rules.Rule],
    local: Sequence[str] = rules.VM_LOCAL,
    only: str | None = None,
) -> None:
    """Place every guarded file of `project` into `shadow` (all, or one verdict)."""
    for rel, path, verdict in _guarded(project, rule_list, local):
        if only in (None, verdict):
            _place(shadow, rel, path, verdict)


def redact(project: str, shadow: str, rule_list: list[rules.Rule], local: Sequence[str]) -> None:
    """A tightened `.kibignore`: every file it now redacts in `shadow` becomes its render."""
    for top, _, files, dfd in os.fwalk(shadow):
        for name in files:
            rel = os.path.relpath(os.path.join(top, name), shadow)
            if rules.verdict(rule_list, rel) == rules.REDACT:
                os.unlink(name, dir_fd=dfd)
    seed(project, shadow, rule_list, local, only=rules.REDACT)


def _load(guard_file: str, rule_file: str) -> list[rules.Rule]:
    return rules.load(guard_file, guard=True) + rules.load(rule_file)


def _seed_cmd(guard_file: str, rule_file: str, project: str, shadow: str, skip: str) -> int:
    """`seed <guard-file> <rule-file> <project> <shadow> <skip>`"""
    seed(project, shadow, _load(guard_file, rule_file), rules.vm_local(skip))
    return cli.OK


def _redact_cmd(guard_file: str, rule_file: str, project: str, shadow: str, skip: str) -> int:
    """`redact <guard-file> <rule-file> <project> <shadow> <skip>`"""
    redact(project, shadow, _load(guard_file, rule_file), rules.vm_local(skip))
    return cli.OK


def main(argv: list[str]) -> int:
    return cli.dispatch(
        "kib.host.vmseed", {"seed": (_seed_cmd, 5), "redact": (_redact_cmd, 5)}, argv
    )


if __name__ == "__main__":
    cli.run(main)
