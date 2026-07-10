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
from pathlib import PurePosixPath

from fuse import FUSE, FuseOSError, Operations

STUB = (
    b"# REDACTED BY .ccignore \xe2\x80\x94 hidden from this Claude Code Docker sandbox by user policy.\n"
    b"# Intentional, not an error. All access paths return this stub; writes return EACCES.\n"
    b"# Ask the user directly if you need the contents \xe2\x80\x94 don't try to work around it.\n"
)
REDACTED_NAME = "REDACTED.md"


def load_rules(path):
    """Parse .ccignore into an ordered list of (negated, pattern, is_exact).

    Order is preserved so gitignore-style last-match-wins negation works:
    a later '!' rule re-includes a path an earlier rule masked.
    """
    rules = []
    with open(path) as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
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
            rules.append((neg, line, "/" in line))
    return rules


class Redact(Operations):
    def __init__(self, src, rules):
        self.src = os.path.realpath(src)
        self.rules = rules

    def _real(self, path):
        return os.path.join(self.src, path.lstrip("/"))

    def _rel(self, path):
        return path.lstrip("/")

    def _rule_matches(self, pat, exact, anc, seg, under_git):
        """True if a single rule matches this ancestor / segment (glob-aware).

        Exact ('/'-containing) rules match the ancestor component-by-component
        so a '*' never spans '/'; bare-basename rules match one segment and
        never apply inside .git.
        """
        if exact:
            apar = anc.split("/")
            ppar = pat.split("/")
            return len(ppar) == len(apar) and all(
                fnmatch.fnmatch(a, p) for a, p in zip(apar, ppar)
            )
        return not under_git and fnmatch.fnmatch(seg, pat)

    def _ignored(self, rel):
        """Gitignore-consistent mask test for one relative path.

        Rules apply in order and the last match wins, so 'dir/*' followed by
        '!dir/keep' leaves keep un-masked. A path beneath an already-masked
        *parent directory* can't be re-included (git's parent-exclusion rule).
        """
        parts = rel.split("/")
        under_git = parts[0] == ".git"
        ignored = False
        for i in range(1, len(parts) + 1):
            anc = "/".join(parts[:i])
            seg = parts[i - 1]
            for neg, pat, exact in self.rules:
                if self._rule_matches(pat, exact, anc, seg, under_git):
                    ignored = not neg
            # A masked proper-ancestor directory seals everything beneath it.
            if ignored and i < len(parts):
                return True
        return ignored

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
        # The shallowest masked ancestor is the redaction root; negation
        # (honored inside _ignored) can leave the leaf un-masked entirely.
        for i in range(1, len(parts) + 1):
            anc = "/".join(parts[:i])
            if self._ignored(anc):
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

    rules = load_rules(args.patterns_file)
    print(
        f"ccignore-fuse: src={args.src} mnt={args.mnt} "
        f"rules={[('!' if n else '') + p for n, p, _ in rules]}",
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
