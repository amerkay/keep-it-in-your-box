"""The redacting FUSE passthrough. Runs in the guest, as the sandbox's view of the project.

Mirrors `--src` at `--mnt`. Paths matching a rule read as a stub and refuse writes; paths the
guard PROTECTS read through untouched and refuse writes, since stubbing `.git/config` would
break in-container git outright.

Rule parsing lives in `kib.shared.rules` and the host-executed-value tables in
`kib.shared.dangerous`. This module owns the filesystem translation, plus the one guard needing
depth-aware logic no tail rule can express: git's executed paths nest arbitrarily under
`.git/modules/<name>/` and `.git/worktrees/<name>/`.
"""

import argparse
import errno
import os
import sys
from collections.abc import Sequence
from pathlib import PurePosixPath
from typing import Any

from kib.shared import dangerous, rules
from kib.shared.log import get_logger

# fusepy is the module 'fuse' on PyPI but 'fusepy' in Debian. Same API — accept either. A
# failed import aborts the mount, and kib refuses to launch without redaction, so it is loud.
try:
    from fuse import FUSE, FuseOSError, Operations
except ImportError:  # Debian/Ubuntu packaging
    from fusepy import FUSE, FuseOSError, Operations

log = get_logger("kib.fuse")

STUB = (
    b"# REDACTED BY .kibignore \xe2\x80\x94 hidden from this Claude Code Docker sandbox"
    b" by user policy.\n"
    b"# Intentional, not an error. All access paths return this stub; writes return EACCES.\n"
    b"# Ask the user directly if you need the contents \xe2\x80\x94 don't try to work around it.\n"
)
REDACTED_NAME = "REDACTED.md"

# A git dir is identified by its layout, not its name: `git init --bare`,
# `--separate-git-dir` and a `gitdir:` redirect all put config+hooks somewhere other than a
# directory called '.git'.
GITDIR_MARKERS = ("HEAD", "objects", "refs")


# Operations comes from an unstubbed fusepy, so it is typed Any and strict mode refuses to
# subclass it. Nothing else in the file is loosened.
class Redact(Operations):  # type: ignore[misc]
    """Passthrough of `src`, filtered through an ordered rule list."""

    def __init__(self, src: str, rule_list: Sequence[rules.Rule]) -> None:
        self.src = os.path.realpath(src)
        self.rules = rule_list

    def _real(self, path: str) -> str:
        return os.path.join(self.src, path.lstrip("/"))

    def _rel(self, path: str) -> str:
        return path.lstrip("/")

    def _verdict(self, rel: str) -> str | None:
        return rules.verdict(self.rules, rel)

    def _protected(self, path: str) -> bool:
        """True if writes to this path must be refused but reads pass through."""
        rel = self._rel(path)
        return rel != "" and (self._verdict(rel) == rules.PROTECT or self._git_sensitive(rel))

    def _classify(self, path: str) -> tuple[str, str]:
        """Return `('pass'|'file'|'dir'|'inside', masked_rel_root)`.

        - 'pass': not masked
        - 'file': the path itself is a masked file → serve the stub
        - 'dir': the path itself is a masked directory → serve a single REDACTED.md
        - 'inside': the path is inside a masked dir → REDACTED.md or ENOENT

        Only a 'redact' verdict reaches here. 'protect' deliberately returns 'pass' so
        every read stays a plain passthrough; protection is enforced on the write paths,
        via `_protected()`.
        """
        rel = self._rel(path)
        if rel == "":
            return ("pass", "")
        parts = rel.split("/")
        # The shallowest masked ancestor is the redaction root; negation (honoured inside
        # verdict()) can leave the leaf un-masked entirely.
        for i in range(1, len(parts) + 1):
            anc = "/".join(parts[:i])
            if self._verdict(anc) == rules.REDACT:
                real = self._real(anc)
                is_dir = os.path.isdir(real)
                if i == len(parts):
                    return ("dir" if is_dir else "file", anc)
                # Proper ancestor: a real dir (or a non-existent path, so creation stays
                # denied) shrouds what is beneath it.
                if is_dir or not os.path.lexists(real):
                    return ("inside", anc)
                return ("file", anc)
        return ("pass", "")

    def _stub_attr(self, mode: int, nlink: int, size: int) -> dict[str, Any]:
        """Synthetic stat for a masked path, timestamped from the project root."""
        st = os.lstat(self.src)
        return {
            "st_mode": mode,
            "st_nlink": nlink,
            "st_size": size,
            "st_ctime": st.st_ctime,
            "st_mtime": st.st_mtime,
            "st_atime": st.st_atime,
            "st_uid": st.st_uid,
            "st_gid": st.st_gid,
        }

    # ── read-only metadata ───────────────────────────────────────
    def getattr(self, path: str, fh: int | None = None) -> dict[str, Any]:
        kind, root = self._classify(path)
        if kind == "file":
            return self._stub_attr(0o100444, 1, len(STUB))
        if kind == "dir":
            return self._stub_attr(0o040555, 2, 0)
        if kind == "inside":
            rel = self._rel(path)
            if PurePosixPath(rel).name == REDACTED_NAME and os.path.dirname(rel) == root:
                return self._stub_attr(0o100444, 1, len(STUB))
            raise FuseOSError(errno.ENOENT)
        st = os.lstat(self._real(path))
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
        try:
            return [".", ".."] + os.listdir(self._real(path))
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

    # pread/pwrite, NEVER lseek+read. With nothreads=False several workers serve one open file
    # and share the fd's single offset; racing lseeks let one read from another's offset, and a
    # short buffer past EOF reads to the kernel as EOF — the caller silently sees the file
    # truncated at a 16 KiB boundary. pread carries the offset, so nothing races.
    def read(self, path: str, size: int, offset: int, fh: int) -> bytes:
        kind, _ = self._classify(path)
        if kind != "pass":
            return STUB[offset : offset + size]
        return os.pread(fh, size, offset)

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
    # git never writes config in place — it writes config.lock and renames over the target, so
    # the rename IS the write and validating there needs no write() buffering. Blanket-denying
    # instead would break `git remote add` and `git push -u` in the sandbox.
    def _is_gitdir(self, rel_dir: str) -> bool:
        """True if this directory carries git's layout, whatever it is named."""
        real = self._real(rel_dir)
        return all(os.path.exists(os.path.join(real, m)) for m in GITDIR_MARKERS)

    def _is_git_config(self, rel: str) -> bool:
        parts = rel.split("/")
        if len(parts) < 2 or parts[-1] not in ("config", "config.worktree"):
            return False
        return ".git" in parts[:-1] or self._is_gitdir("/".join(parts[:-1]))

    def _git_sensitive(self, rel: str) -> bool:
        """Host-executed paths inside any git dir, at any nesting.

        Kept as code rather than guard patterns because the shapes need depth-aware logic a
        tail rule cannot express: submodules put these under `.git/modules/<name>/`
        (arbitrarily deep, since submodules nest) and worktrees under
        `.git/worktrees/<name>/`. Sharing `_is_git_config` with the rename validation below
        also keeps "what is a git config" defined once.
        """
        if self._is_git_config(rel):
            return True
        parts = rel.split("/")
        if "hooks" not in parts:
            return False
        i = parts.index("hooks")
        return i >= 1 and (".git" in parts[:i] or self._is_gitdir("/".join(parts[:i])))

    def _git_config_write_ok(self, src_real: str, dst_real: str) -> bool:
        """Allow a config write that introduces no *new* command-valued setting.

        Compared against the current file rather than judged absolutely: a repo that
        already has, say, a git-lfs filter is the user's own host-side config, and
        rewriting the file for an unrelated reason (a new remote) must not trip over it.
        Only entries the sandbox is adding or changing are refused. Unreadable or
        undecodable input fails closed.
        """
        try:
            with open(src_real, encoding="utf-8", errors="strict") as f:
                new = dangerous.git_ini_entries(f.read())
        except (OSError, UnicodeDecodeError):
            return False
        if not new:
            return True
        try:
            with open(dst_real, encoding="utf-8", errors="strict") as f:
                old = dangerous.git_ini_entries(f.read())
        except (OSError, UnicodeDecodeError):
            old = set()
        added = new - old
        for section, key, _ in sorted(added):
            log.error(
                "kib-fuse: refusing git config write — '%s.%s' names a command the host "
                "would execute",
                section,
                key,
            )
        return not added

    def create(self, path: str, mode: int, fi: object = None) -> int:
        self._deny_if_masked(path)
        return os.open(self._real(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)

    def write(self, path: str, data: bytes, offset: int, fh: int) -> int:
        return os.pwrite(fh, data, offset)  # same offset race as read(), same fix

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


def main(argv: Sequence[str] | None = None) -> None:
    ap = argparse.ArgumentParser(prog="kib-fuse", description="redacting FUSE passthrough")
    ap.add_argument("--src", required=True)
    ap.add_argument("--mnt", required=True)
    ap.add_argument("--patterns-file", required=True)
    ap.add_argument("--guard-file")
    args = ap.parse_args(argv)

    # Guard rules first for readability only: verdict() tallies immune rules separately, so
    # they outrank project rules regardless of position here. Their order relative to *each
    # other* is what matters (last match wins).
    rule_list = rules.load(args.guard_file, guard=True) if args.guard_file else []
    guard_count = len(rule_list)
    rule_list += rules.load(args.patterns_file)
    print(
        f"kib-fuse: src={args.src} mnt={args.mnt} guard={guard_count} "
        f"rules={[str(r) for r in rule_list]}",
        file=sys.stderr,
        flush=True,
    )

    FUSE(
        Redact(args.src, rule_list),
        args.mnt,
        foreground=True,
        allow_other=True,
        nothreads=False,
        default_permissions=False,
    )


if __name__ == "__main__":
    main()
