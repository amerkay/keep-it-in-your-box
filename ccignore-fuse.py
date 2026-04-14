#!/usr/bin/env python3
# FUSE redacting passthrough used by the cc sidecar.
# Mirrors --src at --mnt; for paths matching rules from --patterns-file,
# reads return the redaction stub and writes return EACCES.
# Patterns file uses .ccignore syntax: bare basename = recursive (excluding
# .git), path with '/' = exact relative to src root, '#' starts a comment.

import argparse
import errno
import os
import sys
from pathlib import PurePosixPath

from fuse import FUSE, FuseOSError, Operations

STUB = (
    b"# REDACTED: This path was redacted inside the Claude Code container "
    b"by .ccignore. The real contents are available on the host machine.\n"
)
REDACTED_NAME = "REDACTED.md"


def load_rules(path):
    basenames, exacts = set(), set()
    with open(path) as f:
        for line in f:
            line = line.split("#", 1)[0].strip().rstrip("/")
            if not line:
                continue
            if line.startswith("/") or ".." in line.split("/"):
                print(f"ccignore-fuse: skipping unsafe rule {line!r}", file=sys.stderr)
                continue
            (exacts if "/" in line else basenames).add(line)
    return basenames, exacts


class Redact(Operations):
    def __init__(self, src, basenames, exacts):
        self.src = os.path.realpath(src)
        self.basenames = basenames
        self.exacts = exacts

    def _real(self, path):
        return os.path.join(self.src, path.lstrip("/"))

    def _rel(self, path):
        return path.lstrip("/")

    def _classify(self, path):
        """Return ('pass'|'file'|'dir'|'inside', masked_rel_root).

        - 'pass': not masked
        - 'file': path itself is a masked file → serve stub
        - 'dir':  path itself is a masked directory → serve single REDACTED.md
        - 'inside': path is inside a masked dir → serve REDACTED.md or ENOENT
        """
        rel = self._rel(path)
        if rel == "":
            return ("pass", "")
        parts = rel.split("/")
        # .git is never masked by bare-basename rules
        under_git = parts[0] == ".git"

        # Check exact rules against ancestors.
        for i in range(1, len(parts) + 1):
            anc = "/".join(parts[:i])
            if anc in self.exacts:
                real = self._real(anc)
                kind = "dir" if os.path.isdir(real) else "file"
                if i == len(parts):
                    return (kind, anc)
                return ("inside", anc) if kind == "dir" else ("file", anc)

        # Basename rules against each path segment (skip inside .git).
        if not under_git:
            for i, seg in enumerate(parts, start=1):
                if seg in self.basenames:
                    anc = "/".join(parts[:i])
                    real = self._real(anc)
                    if not os.path.lexists(real):
                        # Non-existent path but matches a rule: treat as masked file
                        # so creation attempts are denied too.
                        return ("file", anc) if i == len(parts) else ("inside", anc)
                    kind = "dir" if os.path.isdir(real) else "file"
                    if i == len(parts):
                        return (kind, anc)
                    return ("inside", anc) if kind == "dir" else ("file", anc)

        return ("pass", "")

    # ── read-only metadata ───────────────────────────────────────
    def getattr(self, path, fh=None):
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

    def readdir(self, path, fh):
        kind, _ = self._classify(path)
        if kind == "dir":
            return [".", "..", REDACTED_NAME]
        if kind in ("file", "inside"):
            return [".", ".."]
        real = self._real(path)
        try:
            return [".", ".."] + os.listdir(real)
        except OSError as e:
            raise FuseOSError(e.errno)

    def readlink(self, path):
        kind, _ = self._classify(path)
        if kind != "pass":
            raise FuseOSError(errno.EACCES)
        return os.readlink(self._real(path))

    def statfs(self, path):
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
    def open(self, path, flags):
        kind, _ = self._classify(path)
        if flags & (os.O_WRONLY | os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_TRUNC):
            if kind != "pass":
                raise FuseOSError(errno.EACCES)
        if kind != "pass":
            return 0  # virtual fd; reads served from STUB
        return os.open(self._real(path), flags)

    def read(self, path, size, offset, fh):
        kind, _ = self._classify(path)
        if kind != "pass":
            return STUB[offset : offset + size]
        os.lseek(fh, offset, os.SEEK_SET)
        return os.read(fh, size)

    def release(self, path, fh):
        if fh and fh != 0:
            os.close(fh)
        return 0

    # ── writes (passthrough for unmasked paths) ──────────────────
    def _deny_if_masked(self, path):
        kind, _ = self._classify(path)
        if kind != "pass":
            raise FuseOSError(errno.EACCES)

    def create(self, path, mode, fi=None):
        self._deny_if_masked(path)
        return os.open(self._real(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)

    def write(self, path, data, offset, fh):
        os.lseek(fh, offset, os.SEEK_SET)
        return os.write(fh, data)

    def truncate(self, path, length, fh=None):
        self._deny_if_masked(path)
        with open(self._real(path), "r+b") as f:
            f.truncate(length)

    def unlink(self, path):
        self._deny_if_masked(path)
        os.unlink(self._real(path))

    def rmdir(self, path):
        self._deny_if_masked(path)
        os.rmdir(self._real(path))

    def mkdir(self, path, mode):
        self._deny_if_masked(path)
        os.mkdir(self._real(path), mode)

    def rename(self, old, new):
        self._deny_if_masked(old)
        self._deny_if_masked(new)
        os.rename(self._real(old), self._real(new))

    def chmod(self, path, mode):
        self._deny_if_masked(path)
        os.chmod(self._real(path), mode)

    def chown(self, path, uid, gid):
        self._deny_if_masked(path)
        os.chown(self._real(path), uid, gid)

    def utimens(self, path, times=None):
        self._deny_if_masked(path)
        os.utime(self._real(path), times=times)

    def symlink(self, target, source):
        self._deny_if_masked(target)
        os.symlink(source, self._real(target))

    def link(self, target, source):
        self._deny_if_masked(target)
        os.link(self._real(source), self._real(target))

    def flush(self, path, fh):
        if fh and fh != 0:
            os.fsync(fh)
        return 0

    def fsync(self, path, datasync, fh):
        if fh and fh != 0:
            (os.fdatasync if datasync else os.fsync)(fh)
        return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--mnt", required=True)
    ap.add_argument("--patterns-file", required=True)
    args = ap.parse_args()

    basenames, exacts = load_rules(args.patterns_file)
    print(
        f"ccignore-fuse: src={args.src} mnt={args.mnt} "
        f"basenames={sorted(basenames)} exacts={sorted(exacts)}",
        file=sys.stderr,
        flush=True,
    )

    FUSE(
        Redact(args.src, basenames, exacts),
        args.mnt,
        foreground=True,
        allow_other=True,
        nothreads=False,
        default_permissions=False,
    )


if __name__ == "__main__":
    main()
