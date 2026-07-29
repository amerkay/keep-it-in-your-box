"""The redacting FUSE passthrough. Runs in the guest, as the sandbox's view of the project.

Mirrors `--src` at `--mnt`. Paths matching a rule refuse writes and read as their key names
with every value redacted (JSON and dotenv) or as a flat stub (anything else — see `render`);
paths the guard PROTECTS read through untouched and refuse writes, since stubbing
`.git/config` would break in-container git outright.

One relaxation, and only for PROTECT: a guarded path may be written at a NESTED location if
its bytes reproduce the same guarded tail at the project ROOT exactly (`_mirror_anchor`).
Reproducing what the host already executes grants nothing; authoring is still refused.

Rule parsing lives in `kib.shared.rules` and the host-executed-value tables in
`kib.shared.dangerous`. This module owns the filesystem translation, plus the one guard needing
depth-aware logic no tail rule can express: git's executed paths nest arbitrarily under
`.git/modules/<name>/` and `.git/worktrees/<name>/`.
"""

import argparse
import errno
import json
import os
import re
import sys
from collections.abc import Sequence
from pathlib import PurePosixPath
from typing import Any

from kib.shared import dangerous, rules
from kib.shared.log import get_logger

# fusepy is the module 'fuse' on PyPI but 'fusepy' in Debian. Same API — accept either. A
# failed import aborts the mount, and kib refuses to launch without redaction, so it is loud.
try:
    from fuse import FUSE, FuseOSError, Operations, fuse_get_context
except ImportError:  # Debian/Ubuntu packaging
    from fusepy import FUSE, FuseOSError, Operations, fuse_get_context

log = get_logger("kib.fuse")

STUB = (
    b"# REDACTED BY .kibignore \xe2\x80\x94 hidden from this Claude Code Docker sandbox"
    b" by user policy.\n"
    b"# Intentional, not an error. All access paths return this stub; writes return EPERM.\n"
    b"# Ask the user directly if you need the contents \xe2\x80\x94 don't try to work around it.\n"
)
REDACTED_NAME = "REDACTED.md"

# kib policy refusals raise EPERM, never EACCES. The reason is logged to the SIDECAR's stderr —
# a different container — so the agent sees an errno and nothing else, and the errno is the only
# channel able to say "the guard refused this" rather than "check the file mode". EACCES stays
# what `default_permissions` returns for an ordinary owner/mode failure.
REFUSED = errno.EPERM

# A git dir is identified by its layout, not its name: `git init --bare`,
# `--separate-git-dir` and a `gitdir:` redirect all put config+hooks somewhere other than a
# directory called '.git'.
GITDIR_MARKERS = ("HEAD", "objects", "refs")

#: Any flag that makes an open able to modify the file.
WRITE_FLAGS = os.O_WRONLY | os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_TRUNC

# ── format-aware redaction ───────────────────────────────────────
# A redacted file whose *shape* is known reads as its key names with every value replaced.
# The whole-file stub hid which settings even exist, so the agent's next move was to ask the
# user, who pasted the value into the transcript — the stub caused the leak it prevented.
#
# THE RULE: never pass a byte of the file through. Output is synthesised from parsed tokens
# (key names only); anything a parser cannot vouch for falls back to STUB, so a comment, a
# continuation or a value containing '#' or '=' cannot leak by construction.
#
# Accepted residual: a file where the *key* is the secret. Documented in etc-CLAUDE.md.
REDACTED_VALUE = "<redacted>"
RENDER_MAX = 64 * 1024  # config and credential files; bigger is not one of these shapes
DOTENV_KEY = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=")


def _scrub(node: Any) -> Any:
    """A JSON tree with every scalar leaf replaced. Keys and structure survive, values don't."""
    if isinstance(node, dict):
        return {k: _scrub(v) for k, v in node.items()}
    if isinstance(node, list):
        return [_scrub(v) for v in node]
    return REDACTED_VALUE


def _render_json(text: str) -> bytes | None:
    # RecursionError alongside ValueError: `[`×30000 is 60 KB of *valid* JSON that overflows
    # the decoder, and _scrub recurses too. Uncaught it would surface as an unexplained read
    # failure rather than the stub — the class of bug the pread note below is about.
    try:
        return (json.dumps(_scrub(json.loads(text)), indent=2) + "\n").encode()
    except (ValueError, RecursionError):
        return None


def _render_dotenv(text: str) -> bytes | None:
    """`KEY=<redacted>` per assignment, or None if any value spans lines.

    A multi-line quoted value has to bail: its own interior lines match the key pattern, so
    fragments of the secret would print as if they were names.
    """
    keys: list[str] = []
    for line in text.splitlines():
        m = DOTENV_KEY.match(line)
        if not m:
            continue
        value = line[m.end() :].lstrip()
        quote = value[:1]
        if quote in ('"', "'"):
            tail = value[1:].rstrip()
            if not tail.endswith(quote) or tail.endswith("\\" + quote):
                return None
        keys.append(m.group(1))
    return "".join(f"{k}={REDACTED_VALUE}\n" for k in keys).encode() if keys else None


def render(name: str, real: str) -> bytes:
    """What a redacted file serves on read. STUB on any doubt — unknown shape, parse failure,
    unreadable, undecodable, or too large to be one of these shapes."""
    # Bounded read rather than a size check then a read: one syscall fewer, and no window in
    # which the file grows past the cap between the two.
    try:
        with open(real, encoding="utf-8", errors="strict") as fh:
            text = fh.read(RENDER_MAX + 1)
    except (OSError, UnicodeDecodeError):
        return STUB
    if len(text) > RENDER_MAX:
        return STUB
    if name.endswith(".json"):
        return _render_json(text) or STUB
    if name == ".env" or name.startswith(".env."):
        return _render_dotenv(text) or STUB
    return STUB


# Operations comes from an unstubbed fusepy, so it is typed Any and strict mode refuses to
# subclass it. Nothing else in the file is loosened.
class Redact(Operations):  # type: ignore[misc]
    """Passthrough of `src`, filtered through an ordered rule list."""

    def __init__(
        self,
        src: str,
        rule_list: Sequence[rules.Rule],
        uid: int | None = None,
        gid: int | None = None,
    ) -> None:
        self.src = os.path.realpath(src)
        self.rules = rule_list
        # Ownership remap, NOT a blanket squash. On macOS the project arrives over the engine
        # VM's virtiofs, which reports every file as root:root; the agent is HOST_UID, so git
        # refuses the whole tree as "dubious ownership" and takes dev.sh/CI down with it. So
        # whoever owns the project ROOT is reported as the agent — and only them. A file
        # genuinely owned by someone else keeps its real ids, so `default_permissions` still
        # refuses it. On Linux the base ids already are the agent's and the map is identity.
        # None = report the real ids (standalone use).
        self.uid = uid
        self.gid = gid
        st = os.lstat(self.src)
        self.base_uid = st.st_uid
        self.base_gid = st.st_gid
        # getattr must report the size read() will produce, so both have to see ONE render of
        # one version of the file — recomputing per call lets a file changing under us report
        # one size and serve another, splicing two versions across a partial read. Keyed on
        # identity+mtime+size, capped because a project can hold any number of redacted files.
        self._rendered: dict[tuple[str, int, int, int], bytes] = {}
        # fds opened for WRITING at a protected path — the mirror candidates. release() is
        # handed no flags, and a read-only open of .git/config reaching its size check would
        # unlink the file.
        self._mirroring: set[int] = set()

    def _render(self, rel: str) -> bytes:
        """Cached bytes for a redacted file. A cache miss on a racing write just recomputes."""
        real = self._real(rel)
        try:
            st = os.stat(real)
        except OSError:
            return STUB
        key = (real, st.st_ino, st.st_mtime_ns, st.st_size)
        hit = self._rendered.get(key)
        if hit is None:
            hit = render(PurePosixPath(rel).name, real)
            if len(self._rendered) >= 64:
                self._rendered.clear()
            self._rendered[key] = hit
        return hit

    def _own(self, st_uid: int, st_gid: int) -> tuple[int, int]:
        return (
            self.uid if self.uid is not None and st_uid == self.base_uid else st_uid,
            self.gid if self.gid is not None and st_gid == self.base_gid else st_gid,
        )

    def _adopt(self, real: str | None = None, fd: int | None = None, *, deref: bool = True) -> None:
        """Hand a just-created inode to the caller.

        The inode lands on the HOST, so it must belong to the caller rather than to whoever
        the server happens to run as. kib starts the server as the host user, which makes this
        a no-op there — but the invariant is what matters, not the coincidence. Best effort:
        virtiofs ignores chown, and there the reported ids are invented anyway.
        """
        uid, gid, _ = fuse_get_context()
        try:
            if fd is not None:
                os.fchown(fd, uid, gid)
            elif real is not None:
                os.chown(real, uid, gid, follow_symlinks=deref)
        except OSError:
            pass

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

    # ── mirrors: reproduce, never author ─────────────────────────
    # A guarded path may be written at a NESTED location iff its bytes are identical to the same
    # guarded tail at the project ROOT — which the box cannot write, so those bytes are the
    # host's own. Reproducing what the host already executes grants no capability; a payload
    # differs from the anchor, or has none, and is refused. This is what lets `git worktree add`,
    # `clone`, a branch switch and `stash pop` check out a repo that tracks `.vscode/`.
    #
    # NOT scoped to worktrees, deliberately: the box can `git commit`, so it decides what
    # "tracked" means, and any carve-out keyed on a location or a file type is bypassable by
    # committing the payload first (redaction-config-guard.md).
    def _mirror_anchor(self, rel: str) -> str | None:
        """The root-anchored twin a nested guarded path may reproduce, byte for byte.

        Guard rules are TAIL-anchored, so the shortest suffix that still reads PROTECT is the
        rule's own tail — the matcher already answers this, no rule identity needed.
        """
        if self._git_sensitive(rel) or self._verdict(rel) != rules.PROTECT:
            return None  # git's own paths and [redact]: never mirrorable
        parts = rel.split("/")
        for i in range(len(parts) - 1, 0, -1):  # shortest first; i is never 0, so never itself
            if self._verdict("/".join(parts[i:])) == rules.PROTECT:
                return "/".join(parts[i:])
        return None

    def _mirrorable(self, path: str) -> bool:
        """True if this path may be written as a copy of an anchor that exists.

        `lexists` covers both shapes at once: `mkdir …/w/.vscode` resolves to `.vscode`, a real
        directory (and an empty directory executes nothing), while `…/w/.vscode/tasks.json`
        resolves to a `tasks.json` the host never wrote — absent, so refused.
        """
        anchor = self._mirror_anchor(self._rel(path))
        return anchor is not None and os.path.lexists(self._real(anchor))

    def _anchor_bytes(self, path: str, offset: int, size: int) -> bytes:
        """The anchor's bytes at this offset. b'' when there is no readable anchor, which makes
        any non-empty write mismatch and be refused."""
        anchor = self._mirror_anchor(self._rel(path))
        if anchor is None:
            return b""
        try:
            fd = os.open(self._real(anchor), os.O_RDONLY)
        except OSError:
            return b""
        try:
            return os.pread(fd, size, offset)
        finally:
            os.close(fd)

    def _track_mirror(self, path: str, fd: int) -> None:
        """Record an fd opened for writing at a protected path, for release()'s size check."""
        if self._protected(path):
            self._mirroring.add(fd)

    def _deny_unless_whole_mirror(self, path: str) -> None:
        """Refuse, and leave nothing behind, unless the finished file matches the anchor's size.

        Size is the one thing write() cannot check: a SHORT mirror matches its anchor byte for
        byte as far as it goes, and a truncated script is a different script (`rm -rf /tmp/x`
        cut to `rm -rf /`). The UNLINK is the enforcement here — the kernel does not reliably
        surface a release() error to close(), so the errno is only a courtesy.
        """
        real = self._real(path)
        anchor = self._mirror_anchor(self._rel(path))
        try:
            if anchor is not None and os.path.getsize(real) == os.path.getsize(self._real(anchor)):
                return
        except OSError:
            pass
        try:
            os.unlink(real)
        except OSError:
            pass
        raise FuseOSError(REFUSED)

    def _classify(self, path: str) -> tuple[str, str]:
        """Return `('pass'|'file'|'dir'|'inside'|'absent', masked_rel_root)`.

        - 'pass': not masked
        - 'file': the path itself is a masked file → serve the stub
        - 'dir': the path itself is a masked directory → serve a single REDACTED.md
        - 'inside': the path is inside a masked dir → REDACTED.md or ENOENT
        - 'absent': masked, but nothing is there on the host → reads must behave exactly as
          outside the box (ENOENT); writes are still refused, since 'absent' is not 'pass'

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
                # Redaction hides VALUES, it does not conjure files. Stubbing a path the host
                # does not have made `.env.local`/`.env.development` stat successfully in a
                # project that has only `.env`, and a dev-server watcher over the dotenv set
                # then restarted forever on entries that appear and vanish.
                if not os.path.lexists(real):
                    return ("absent", anc)
                is_dir = os.path.isdir(real)
                if i == len(parts):
                    return ("dir" if is_dir else "file", anc)
                # Proper ancestor: a real dir shrouds what is beneath it.
                return ("inside", anc) if is_dir else ("file", anc)
        return ("pass", "")

    def _stub_attr(self, root: str, mode: int, nlink: int, size: int) -> dict[str, Any]:
        """Synthetic stat for a masked path, timestamped from the masked root itself.

        NOT from the project root: that mtime moves whenever any entry is added or removed
        there, so every redacted file in the tree appeared to change at once and a watcher
        (`nuxi dev`, chokidar) restarted on each one. `root` always exists — 'absent' is
        classified before any stub is served — and a race that deletes it ENOENTs, correctly.
        """
        st = os.lstat(self._real(root))
        uid, gid = self._own(st.st_uid, st.st_gid)
        return {
            "st_mode": mode,
            "st_nlink": nlink,
            "st_size": size,
            "st_ctime": st.st_ctime,
            "st_mtime": st.st_mtime,
            "st_atime": st.st_atime,
            "st_uid": uid,
            "st_gid": gid,
        }

    # ── read-only metadata ───────────────────────────────────────
    def getattr(self, path: str, fh: int | None = None) -> dict[str, Any]:
        kind, root = self._classify(path)
        if kind == "file":
            return self._stub_attr(root, 0o100444, 1, len(self._render(root)))
        if kind == "dir":
            return self._stub_attr(root, 0o040555, 2, 0)
        if kind == "inside":
            rel = self._rel(path)
            if PurePosixPath(rel).name == REDACTED_NAME and os.path.dirname(rel) == root:
                return self._stub_attr(root, 0o100444, 1, len(STUB))
            raise FuseOSError(errno.ENOENT)
        st = os.lstat(self._real(path))
        attr = {
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
        attr["st_uid"], attr["st_gid"] = self._own(st.st_uid, st.st_gid)
        return attr

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
            raise FuseOSError(REFUSED)
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
        if flags & WRITE_FLAGS:
            # A protected path opens for writing only as a mirror, or through the validated
            # rename below; nothing legitimate writes .git/config in place (git uses
            # config.lock).
            self._deny_if_masked(path)
        if kind not in ("pass", "absent"):
            return 0  # virtual fd; reads served from the render/STUB
        fd = os.open(self._real(path), flags)  # 'absent' ENOENTs here, as it would outside
        if flags & WRITE_FLAGS:
            self._track_mirror(path, fd)
        return fd

    # pread/pwrite, NEVER lseek+read. With nothreads=False several workers serve one open file
    # and share the fd's single offset; racing lseeks let one read from another's offset, and a
    # short buffer past EOF reads to the kernel as EOF — the caller silently sees the file
    # truncated at a 16 KiB boundary. pread carries the offset, so nothing races.
    def read(self, path: str, size: int, offset: int, fh: int) -> bytes:
        kind, root = self._classify(path)
        if kind == "file":
            return self._render(root)[offset : offset + size]
        if kind != "pass":
            return STUB[offset : offset + size]  # the REDACTED.md marker inside a masked dir
        return os.pread(fh, size, offset)

    def release(self, path: str, fh: int) -> int:
        if fh and fh != 0:
            os.close(fh)
        if fh in self._mirroring:
            self._mirroring.discard(fh)
            if self._protected(path):
                self._deny_unless_whole_mirror(path)
        return 0

    # ── writes (passthrough for unmasked paths) ──────────────────
    def _deny_if_masked(self, path: str, *, mirror_ok: bool = True) -> None:
        """Refuse a write to a masked path.

        `mirror_ok=False` refuses even an exact copy of an anchor, for the ops that move bytes
        the guard never compared (rename, symlink, link) or reshape a mirror without writing
        one (truncate). A mirror is creatable through create+write only.
        """
        kind, _ = self._classify(path)
        if kind != "pass":
            raise FuseOSError(REFUSED)
        if self._protected(path) and not (mirror_ok and self._mirrorable(path)):
            raise FuseOSError(REFUSED)

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
        for entry in sorted(added):
            if entry == dangerous.AMBIGUOUS_ENTRY:
                log.error(
                    "kib-fuse: refusing git config write — it holds a BOM, a lone CR or a "
                    "Unicode line separator, so what git resolves cannot be read off it"
                )
                continue
            section, key, _ = entry
            log.error(
                "kib-fuse: refusing git config write — '%s.%s' names a command the host "
                "would execute",
                section,
                key,
            )
        return not added

    def create(self, path: str, mode: int, fi: object = None) -> int:
        self._deny_if_masked(path)
        fd = os.open(self._real(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
        self._adopt(fd=fd)
        self._track_mirror(path, fd)
        return fd

    def write(self, path: str, data: bytes, offset: int, fh: int) -> int:
        # A mirror may only REPRODUCE: every byte is compared with the anchor's at the same
        # offset before it lands, so a payload is refused at its first differing byte and
        # nothing partial ever reaches the disk.
        if self._protected(path) and data != self._anchor_bytes(path, offset, len(data)):
            raise FuseOSError(REFUSED)
        return os.pwrite(fh, data, offset)  # same offset race as read(), same fix

    def truncate(self, path: str, length: int, fh: int | None = None) -> None:
        # No mirror: a standalone truncate cannot produce an identical copy, only a short one.
        self._deny_if_masked(path, mirror_ok=False)
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
        real = self._real(path)
        os.mkdir(real, mode)
        self._adopt(real)

    def rename(self, old: str, new: str) -> None:
        # No mirror at either end: a rename moves bytes the guard never compared, so it would
        # launder an unchecked payload onto a host-executed name in one op.
        self._deny_if_masked(old, mirror_ok=False)
        if self._is_git_config(self._rel(new)):
            if not self._git_config_write_ok(self._real(old), self._real(new)):
                raise FuseOSError(REFUSED)
        else:
            self._deny_if_masked(new, mirror_ok=False)
        os.rename(self._real(old), self._real(new))

    def chmod(self, path: str, mode: int) -> None:
        self._deny_if_masked(path)
        os.chmod(self._real(path), mode)

    def chown(self, path: str, uid: int, gid: int) -> None:
        self._deny_if_masked(path)
        # Under the remap the caller is echoing back the ids we invented (`cp -p`, `tar -x`,
        # `git checkout` all do), so forwarding them would rewrite the real file's owner to a
        # uid the backing store never had. -1 keeps that component unchanged.
        if self.uid is not None and uid == self.uid:
            uid = -1
        if self.gid is not None and gid == self.gid:
            gid = -1
        os.chown(self._real(path), uid, gid)

    def utimens(self, path: str, times: tuple[float, float] | None = None) -> None:
        self._deny_if_masked(path)
        os.utime(self._real(path), times=times)

    def symlink(self, target: str, source: str) -> None:
        # No mirror: a symlink's content is a path, never the anchor's bytes — it could point
        # anywhere while occupying a host-executed name.
        self._deny_if_masked(target, mirror_ok=False)
        real = self._real(target)
        os.symlink(source, real)
        self._adopt(real, deref=False)  # the link itself, never what it points at

    def link(self, target: str, source: str) -> None:
        self._deny_if_masked(target, mirror_ok=False)
        # The source matters as much as the name: a hardlink is a second directory entry
        # for the *same inode*, and the VFS does not re-resolve it (a symlink does, which
        # is why the symlink form is already blocked). Without this, an unmasked alias
        # launders a protected inode past every path-based check — readable and writable.
        # No mirror either way: the inode's bytes are whatever the source holds, and it
        # keeps changing after the check.
        self._deny_if_masked(source, mirror_ok=False)
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
    # Required, like --patterns-file: an optional guard file fails OPEN. Dropping the flag
    # would start a sidecar with ZERO [protect]/[redact] rules, report the mount as active,
    # and launch the box unprotected — with the only witness a `guard=0` on a stderr nothing
    # reads. "No rules" is spelled as an EMPTY FILE (host/redaction.sh), never a missing flag.
    ap.add_argument("--guard-file", required=True)
    # kib always passes the agent's ids (see Redact.__init__). Optional so the module stays
    # usable standalone, where reporting the backing store's real ownership is the right default.
    ap.add_argument("--uid", type=int, default=None, help="report this owner in the root's place")
    ap.add_argument("--gid", type=int, default=None, help="report this group in the root's place")
    args = ap.parse_args(argv)

    # Guard rules first for readability only: verdict() tallies immune rules separately, so
    # they outrank project rules regardless of position here. Their order relative to *each
    # other* is what matters (last match wins).
    rule_list = rules.load(args.guard_file, guard=True)
    guard_count = len(rule_list)
    rule_list += rules.load(args.patterns_file)
    ops = Redact(args.src, rule_list, uid=args.uid, gid=args.gid)
    print(
        f"kib-fuse: src={args.src} mnt={args.mnt} guard={guard_count} "
        f"remap={ops.base_uid}:{ops.base_gid}->{args.uid}:{args.gid} "
        f"rules={[str(r) for r in rule_list]}",
        file=sys.stderr,
        flush=True,
    )

    FUSE(
        ops,
        args.mnt,
        foreground=True,
        allow_other=True,
        nothreads=False,
        # The backing syscalls run as the SERVER, so a passthrough enforces no POSIX permission
        # at all by default — a `chmod 000` file reads and writes fine. This makes the KERNEL
        # re-apply a standard owner/mode check against the CALLER's ids on every op. Additive:
        # a handler's own refusal still stands, so the stubs (0444/0555) and the write denials
        # are unaffected.
        default_permissions=True,
    )


if __name__ == "__main__":
    main()
