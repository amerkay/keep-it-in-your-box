#!/usr/bin/env python3
# FUSE redacting passthrough used by the cc sidecar.
# Mirrors --src at --mnt; for paths matching rules from --patterns-file,
# reads return the redaction stub and writes return EACCES.
# Patterns file uses .ccignore syntax: bare basename = recursive (excluding
# .git), path with '/' = exact relative to src root, '#' starts a comment.
# Patterns may contain shell-glob wildcards (*, ?, []); for '/'-containing
# rules each path component is matched independently so '*' never crosses '/'.
# A leading '!' negates (re-includes), gitignore-style: rules apply in order,
# last match wins, so 'dir/*' then '!dir/keep' un-masks keep. A path under an
# already-masked parent directory can't be re-included (git's parent rule).

import argparse
import errno
import fnmatch
import os
import sys
from collections.abc import Sequence
from pathlib import PurePosixPath
from typing import Any

# fusepy 3.0.1 ships as the module 'fuse' from PyPI but as 'fusepy' in Debian
# (python3-fusepy). Same library, same API — accept either so the sidecar works
# whichever way the image installed it. Failing to import here aborts the mount,
# and cc refuses to launch without a sidecar, so an ImportError is never silent.
try:
    from fuse import FUSE, FuseOSError, Operations
except ImportError:  # Debian/Ubuntu packaging
    from fusepy import FUSE, FuseOSError, Operations

STUB = (
    b"# REDACTED BY .ccignore \xe2\x80\x94 hidden from this Claude Code Docker sandbox"
    b" by user policy.\n"
    b"# Intentional, not an error. All access paths return this stub; writes return EACCES.\n"
    b"# Ask the user directly if you need the contents \xe2\x80\x94 don't try to work around it.\n"
)
REDACTED_NAME = "REDACTED.md"


# Git config keys whose *value is a command the host runs*. A sandbox that can set one
# of these has host code execution at the next git invocation — core.fsmonitor fires on
# a bare `git status`, before any diff review. Matched on the key's last component, so
# `filter.lfs.clean` matches on "clean"; over-matching only costs a refused write.
DANGEROUS_GIT_KEYS = frozenset(
    """hookspath fsmonitor sshcommand pager editor askpass gitproxy external textconv
    command driver clean smudge process helper templatedir program cmd variant
    packobjectshook uploadpack receivepack""".split()
)
# include/includeIf point git at another config file, which may then declare any of the
# keys above. The validator sees only the file in front of it, so the indirection is the
# bypass — refuse a *newly added* include outright. (Pre-existing ones are grandfathered
# by _git_config_write_ok's old-vs-new diff: they are the user's own host-side config.)
DANGEROUS_GIT_SECTIONS = frozenset({"alias", "pager", "include", "includeif"})

# A git dir is identified by its layout, not its name: `git init --bare`,
# `--separate-git-dir` and a `gitdir:` redirect all put config+hooks somewhere other
# than a directory called '.git'.
GITDIR_MARKERS = ("HEAD", "objects", "refs")

GUARD_ACTIONS = ("protect", "redact")

# (negated, pattern, anchor, action, immune) — see load_rules.
Rule = tuple[bool, str, str, str, bool]


def load_rules(path: str, guard: bool = False) -> list[Rule]:
    """Parse .ccignore into an ordered list of (neg, pattern, anchor, action, immune).

    anchor: 'bare'  — one path segment, matches at any depth, never inside .git
            'exact' — the whole path, relative to the src root
            'tail'  — trailing path components, at any depth (guard rules only)
    action: 'redact'  — stub on read, EACCES on write (the .ccignore behaviour)
            'protect' — read through, EACCES on write

    Order is preserved so gitignore-style last-match-wins negation works: a later
    '!' rule re-includes a path an earlier rule masked. Guard rules take part in
    that among *themselves* only; _verdict tallies them separately from project
    rules and lets the guard win, so a project cannot un-protect itself.
    """
    rules: list[Rule] = []
    action = "redact"
    with open(path) as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            if guard and line.startswith("[") and line.endswith("]"):
                section = line[1:-1].strip().lower()
                if section not in GUARD_ACTIONS:
                    print(f"ccignore-fuse: unknown guard section {line!r}", file=sys.stderr)
                    continue
                action = section
                continue
            neg = line.startswith("!")
            if neg:
                line = line[1:].strip()
            line = line.rstrip("/")
            if not line:
                continue
            if line.startswith("/") or ".." in line.split("/"):
                print(f"ccignore-fuse: skipping unsafe rule {line!r}", file=sys.stderr)
                continue
            if guard:
                # Guard rules may negate *each other* (last match wins within the
                # guard set), which is how '.env.*' can redact while '!.env.example'
                # lets the committed placeholder through. They remain immune to a
                # project's '!' — see _verdict.
                rules.append((neg, line, "tail", action, True))
            else:
                rules.append((neg, line, "exact" if "/" in line else "bare", "redact", False))
    return rules


# Operations comes from an unstubbed fusepy, so it is typed Any and strict mode refuses to
# subclass it. Nothing else in the file is loosened.
class Redact(Operations):  # type: ignore[misc]
    def __init__(self, src: str, rules: Sequence[Rule]) -> None:
        self.src = os.path.realpath(src)
        self.rules = rules

    def _real(self, path: str) -> str:
        return os.path.join(self.src, path.lstrip("/"))

    def _rel(self, path: str) -> str:
        return path.lstrip("/")

    def _rule_matches(self, pat: str, anchor: str, anc: str, seg: str, under_git: bool) -> bool:
        """True if a single rule matches this ancestor / segment (glob-aware).

        Every anchor compares component-by-component, so a '*' never spans '/'.
        'bare' matches one segment and never applies inside .git; 'exact' pins
        the whole path to the src root; 'tail' pins only the trailing
        components, which is what lets a guard rule of '.git/config' cover
        'sub/.git/config' and '.git/modules/x/config' at any depth.
        """
        if anchor == "bare":
            return not under_git and fnmatch.fnmatch(seg, pat)
        apar = anc.split("/")
        ppar = pat.split("/")
        if anchor == "tail":
            if len(ppar) > len(apar):
                return False
            apar = apar[len(apar) - len(ppar) :]
        elif len(ppar) != len(apar):
            return False
        return all(fnmatch.fnmatch(a, p) for a, p in zip(apar, ppar, strict=True))

    def _verdict(self, rel: str) -> str | None:
        """None | 'redact' | 'protect' for one relative path.

        Rules apply in order and the last match wins, so 'dir/*' followed by
        '!dir/keep' leaves keep un-masked. A path beneath an already-matched
        *parent directory* can't be re-included (git's parent-exclusion rule).

        Guard and project rules are tallied separately and the guard wins when
        it has a verdict. That is what makes guard rules immune to a project's
        '!' — a project cannot write '!.git/config' to un-protect itself —
        while still letting the guard file negate *itself*, so '.env.*' can
        redact broadly and '!.env.example' can carve out the placeholder.
        """
        parts = rel.split("/")
        under_git = parts[0] == ".git"
        guard: str | None = None
        verdict: str | None = None
        for i in range(1, len(parts) + 1):
            anc = "/".join(parts[:i])
            seg = parts[i - 1]
            for neg, pat, anchor, action, immune in self.rules:
                if self._rule_matches(pat, anchor, anc, seg, under_git):
                    if immune:
                        guard = None if neg else action
                    else:
                        verdict = None if neg else action
            # A matched proper-ancestor directory seals everything beneath it.
            effective = guard or verdict
            if effective and i < len(parts):
                return effective
        return guard or verdict

    def _protected(self, path: str) -> bool:
        """True if writes to this path must be refused but reads pass through."""
        rel = self._rel(path)
        return rel != "" and (self._verdict(rel) == "protect" or self._git_sensitive(rel))

    def _classify(self, path: str) -> tuple[str, str]:
        """Return ('pass'|'file'|'dir'|'inside', masked_rel_root).

        - 'pass': not masked
        - 'file': path itself is a masked file → serve stub
        - 'dir':  path itself is a masked directory → serve single REDACTED.md
        - 'inside': path is inside a masked dir → serve REDACTED.md or ENOENT

        Only 'redact' reaches here. A 'protect' verdict deliberately returns
        'pass' so every read path stays a plain passthrough — masking
        .git/config with the stub would break in-container git outright, since
        git reads it on virtually every command. Protection is enforced on the
        write paths instead, via _protected().
        """
        rel = self._rel(path)
        if rel == "":
            return ("pass", "")
        parts = rel.split("/")
        # The shallowest masked ancestor is the redaction root; negation
        # (honored inside _verdict) can leave the leaf un-masked entirely.
        for i in range(1, len(parts) + 1):
            anc = "/".join(parts[:i])
            if self._verdict(anc) == "redact":
                real = self._real(anc)
                is_dir = os.path.isdir(real)
                if i == len(parts):
                    return ("dir" if is_dir else "file", anc)
                # Proper ancestor: a real dir (or non-existent path, so
                # creation stays denied) shrouds what's beneath it.
                if is_dir or not os.path.lexists(real):
                    return ("inside", anc)
                return ("file", anc)
        return ("pass", "")

    # ── read-only metadata ───────────────────────────────────────
    def getattr(self, path: str, fh: int | None = None) -> dict[str, Any]:
        kind, root = self._classify(path)
        if kind == "pass":
            st = os.lstat(self._real(path))
        elif kind == "file":
            st = os.lstat(self.src)
            return {
                "st_mode": 0o100444,
                "st_nlink": 1,
                "st_size": len(STUB),
                "st_ctime": st.st_ctime,
                "st_mtime": st.st_mtime,
                "st_atime": st.st_atime,
                "st_uid": st.st_uid,
                "st_gid": st.st_gid,
            }
        elif kind == "dir":
            st = os.lstat(self.src)
            return {
                "st_mode": 0o040555,
                "st_nlink": 2,
                "st_size": 0,
                "st_ctime": st.st_ctime,
                "st_mtime": st.st_mtime,
                "st_atime": st.st_atime,
                "st_uid": st.st_uid,
                "st_gid": st.st_gid,
            }
        else:  # inside masked dir
            rel = self._rel(path)
            if PurePosixPath(rel).name == REDACTED_NAME and os.path.dirname(rel) == root:
                st = os.lstat(self.src)
                return {
                    "st_mode": 0o100444,
                    "st_nlink": 1,
                    "st_size": len(STUB),
                    "st_ctime": st.st_ctime,
                    "st_mtime": st.st_mtime,
                    "st_atime": st.st_atime,
                    "st_uid": st.st_uid,
                    "st_gid": st.st_gid,
                }
            raise FuseOSError(errno.ENOENT)
        return {
            k: getattr(st, k)
            for k in (
                "st_mode",
                "st_nlink",
                "st_size",
                "st_ctime",
                "st_mtime",
                "st_atime",
                "st_uid",
                "st_gid",
            )
        }

    def readdir(self, path: str, fh: int) -> list[str]:
        kind, _ = self._classify(path)
        if kind == "dir":
            return [".", "..", REDACTED_NAME]
        if kind in ("file", "inside"):
            return [".", ".."]
        real = self._real(path)
        try:
            return [".", ".."] + os.listdir(real)
        except OSError as e:
            raise FuseOSError(e.errno) from e

    def readlink(self, path: str) -> str:
        kind, _ = self._classify(path)
        if kind != "pass":
            raise FuseOSError(errno.EACCES)
        return os.readlink(self._real(path))

    def statfs(self, path: str) -> dict[str, int]:
        s = os.statvfs(self.src)
        return {
            k: getattr(s, k)
            for k in (
                "f_bavail",
                "f_bfree",
                "f_blocks",
                "f_bsize",
                "f_favail",
                "f_ffree",
                "f_files",
                "f_flag",
                "f_frsize",
                "f_namemax",
            )
        }

    # ── reads ────────────────────────────────────────────────────
    def open(self, path: str, flags: int) -> int:
        kind, _ = self._classify(path)
        if flags & (os.O_WRONLY | os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_TRUNC):
            # Protected paths are writable only through the validated rename below;
            # nothing legitimate writes .git/config in place (git uses config.lock).
            if kind != "pass" or self._protected(path):
                raise FuseOSError(errno.EACCES)
        if kind != "pass":
            return 0  # virtual fd; reads served from STUB
        return os.open(self._real(path), flags)

    def read(self, path: str, size: int, offset: int, fh: int) -> bytes:
        kind, _ = self._classify(path)
        if kind != "pass":
            return STUB[offset : offset + size]
        os.lseek(fh, offset, os.SEEK_SET)
        return os.read(fh, size)

    def release(self, path: str, fh: int) -> int:
        if fh and fh != 0:
            os.close(fh)
        return 0

    # ── writes (passthrough for unmasked paths) ──────────────────
    def _deny_if_masked(self, path: str) -> None:
        kind, _ = self._classify(path)
        if kind != "pass" or self._protected(path):
            raise FuseOSError(errno.EACCES)

    # ── .git/config: validated writes ────────────────────────────
    # git never writes config in place — it writes config.lock and renames over the
    # target. So the rename *is* the write, and validating there needs no buffering
    # of write() calls. Blanket-denying instead would break `git remote add` and
    # `git push -u` inside the sandbox, which is why this exists at all.
    def _is_gitdir(self, rel_dir: str) -> bool:
        """True if this directory carries git's layout, whatever it is named.

        `git init --bare store`, `git init --separate-git-dir=gd wt` and a `.git`
        gitfile containing `gitdir: ../store` all place config+hooks under a
        directory that is *not* called '.git', so a name-based check misses them
        entirely — while the host still executes what they configure.
        """
        real = self._real(rel_dir)
        return all(os.path.exists(os.path.join(real, m)) for m in GITDIR_MARKERS)

    def _is_git_config(self, rel: str) -> bool:
        parts = rel.split("/")
        if len(parts) < 2 or parts[-1] not in ("config", "config.worktree"):
            return False
        return ".git" in parts[:-1] or self._is_gitdir("/".join(parts[:-1]))

    def _git_sensitive(self, rel: str) -> bool:
        """Host-executed paths inside any git dir, at any nesting.

        Kept as code rather than guard patterns because the shapes need
        depth-aware logic a tail rule can't express: submodules put these under
        .git/modules/<name>/ (arbitrarily deep, since submodules nest) and
        worktrees under .git/worktrees/<name>/. Sharing _is_git_config with the
        rename validation below also keeps "what is a git config" defined once.
        """
        if self._is_git_config(rel):
            return True
        parts = rel.split("/")
        if "hooks" not in parts:
            return False
        i = parts.index("hooks")
        return i >= 1 and (".git" in parts[:i] or self._is_gitdir("/".join(parts[:i])))

    @staticmethod
    def _dangerous_entries(text: str) -> set[tuple[str, str, str]]:
        """The (section, key, value) triples in a git config that name a command."""
        found: set[tuple[str, str, str]] = set()
        section = ""
        for raw in text.splitlines():
            line = raw.split("#", 1)[0].split(";", 1)[0].strip()
            if not line:
                continue
            if line.startswith("["):
                # '[filter "lfs"]' → 'filter'; subsection names are not keys.
                # Git's parser resumes scanning after ']', so '[core]hooksPath = x' on
                # one line is a valid setting — keep the remainder instead of dropping it.
                head, _, rest = line[1:].partition("]")
                section = (head.split() or [""])[0].strip('"').lower()
                line = rest.strip()
                if not line:
                    continue
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip().lower()
            if section in DANGEROUS_GIT_SECTIONS or key.split(".")[-1] in DANGEROUS_GIT_KEYS:
                found.add((section, key, value.strip()))
        return found

    def _git_config_write_ok(self, src_real: str, dst_real: str) -> bool:
        """Allow a config write that introduces no *new* command-valued setting.

        Compared against the current file rather than judged absolutely: a repo
        that already has, say, a git-lfs filter is the user's own host-side
        config, and rewriting the file for an unrelated reason (a new remote)
        must not trip over it. Only entries the sandbox is adding or changing
        are refused. Unreadable/undecodable input fails closed.
        """
        try:
            with open(src_real, encoding="utf-8", errors="strict") as f:
                new = self._dangerous_entries(f.read())
        except (OSError, UnicodeDecodeError):
            return False
        if not new:
            return True
        try:
            with open(dst_real, encoding="utf-8", errors="strict") as f:
                old = self._dangerous_entries(f.read())
        except (OSError, UnicodeDecodeError):
            old = set()
        added = new - old
        for section, key, _ in sorted(added):
            print(
                f"ccignore-fuse: refusing git config write — '{section}.{key}' names a "
                "command the host would execute",
                file=sys.stderr,
                flush=True,
            )
        return not added

    def create(self, path: str, mode: int, fi: object = None) -> int:
        self._deny_if_masked(path)
        return os.open(self._real(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)

    def write(self, path: str, data: bytes, offset: int, fh: int) -> int:
        os.lseek(fh, offset, os.SEEK_SET)
        return os.write(fh, data)

    def truncate(self, path: str, length: int, fh: int | None = None) -> None:
        self._deny_if_masked(path)
        with open(self._real(path), "r+b") as f:
            f.truncate(length)

    def unlink(self, path: str) -> None:
        self._deny_if_masked(path)
        os.unlink(self._real(path))

    def rmdir(self, path: str) -> None:
        self._deny_if_masked(path)
        os.rmdir(self._real(path))

    def mkdir(self, path: str, mode: int) -> None:
        self._deny_if_masked(path)
        os.mkdir(self._real(path), mode)

    def rename(self, old: str, new: str) -> None:
        self._deny_if_masked(old)
        if self._is_git_config(self._rel(new)):
            if not self._git_config_write_ok(self._real(old), self._real(new)):
                raise FuseOSError(errno.EACCES)
        else:
            self._deny_if_masked(new)
        os.rename(self._real(old), self._real(new))

    def chmod(self, path: str, mode: int) -> None:
        self._deny_if_masked(path)
        os.chmod(self._real(path), mode)

    def chown(self, path: str, uid: int, gid: int) -> None:
        self._deny_if_masked(path)
        os.chown(self._real(path), uid, gid)

    def utimens(self, path: str, times: tuple[float, float] | None = None) -> None:
        self._deny_if_masked(path)
        os.utime(self._real(path), times=times)

    def symlink(self, target: str, source: str) -> None:
        self._deny_if_masked(target)
        os.symlink(source, self._real(target))

    def link(self, target: str, source: str) -> None:
        self._deny_if_masked(target)
        # The source matters as much as the name: a hardlink is a second directory entry
        # for the *same inode*, and the VFS does not re-resolve it (a symlink does, which
        # is why the symlink form is already blocked). Without this, an unmasked alias
        # launders a protected inode past every path-based check — readable and writable.
        self._deny_if_masked(source)
        os.link(self._real(source), self._real(target))

    def flush(self, path: str, fh: int) -> int:
        if fh and fh != 0:
            os.fsync(fh)
        return 0

    def fsync(self, path: str, datasync: int, fh: int) -> int:
        if fh and fh != 0:
            (os.fdatasync if datasync else os.fsync)(fh)
        return 0


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--mnt", required=True)
    ap.add_argument("--patterns-file", required=True)
    ap.add_argument("--guard-file")
    args = ap.parse_args()

    # Guard rules first for readability only: _verdict tallies immune rules
    # separately, so they outrank project rules regardless of position here.
    # Their order relative to *each other* is what matters (last match wins).
    rules = load_rules(args.guard_file, guard=True) if args.guard_file else []
    guard_count = len(rules)
    rules += load_rules(args.patterns_file)
    print(
        f"ccignore-fuse: src={args.src} mnt={args.mnt} guard={guard_count} "
        f"rules={[('!' if n else '') + p for n, p, _, _, _ in rules]}",
        file=sys.stderr,
        flush=True,
    )

    FUSE(
        Redact(args.src, rules),
        args.mnt,
        foreground=True,
        allow_other=True,
        nothreads=False,
        default_permissions=False,
    )


if __name__ == "__main__":
    main()
