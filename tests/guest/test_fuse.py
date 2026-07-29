"""The FUSE server's own logic: what is a git dir, what is protected, what a read serves.

Rule parsing and matching are covered in tests/shared/test_rules.py — this suite is the
filesystem translation on top of them, plus the git-config write validator, which is the one
place the sandbox is allowed to write a host-executed file at all.

Runs anywhere, including inside the sandbox: the `fuse` module is stubbed so the server
imports without libfuse, and no real mount is touched.
"""

import errno
import os
import sys
import types
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest


# Stub fusepy before importing the server: the image has it, a bare test host may not, and
# nothing here needs a real mount.
class _FuseOSError(OSError):
    """As fusepy defines it — the errno must land on `.errno`, which is what the kernel
    returns to the agent and the only channel saying WHICH layer refused."""

    def __init__(self, err: int) -> None:
        super().__init__(err, os.strerror(err))


_fuse = types.ModuleType("fuse")
_fuse.__dict__.update(
    FUSE=lambda *a, **k: None,
    Operations=object,
    FuseOSError=_FuseOSError,
    fuse_get_context=lambda: (os.getuid(), os.getgid(), os.getpid()),
)
sys.modules.setdefault("fuse", _fuse)

from kib.guest import fuse  # noqa: E402  — must follow the stub above
from kib.shared import rules  # noqa: E402

GUARD = Path(__file__).resolve().parent.parent.parent / "guest" / "policy" / "global.kibignore"

SAFE = '[core]\n\trepositoryformatversion = 0\n[remote "origin"]\n\turl = https://x/y\n'
LFS = SAFE + '[filter "lfs"]\n\tclean = git-lfs clean\n'


@pytest.fixture
def redact(tmp_path: Path) -> Callable[..., Any]:
    """A Redact bound to a real (empty) src dir, with the shipped guard + project rules."""

    def _build(project: str = "", **kw: Any) -> Any:
        src = tmp_path / "src"
        src.mkdir(exist_ok=True)
        rule_list = rules.load(str(GUARD), guard=True) + rules.parse(project.splitlines())
        return fuse.Redact(str(src), rule_list, **kw)

    return _build


# ── classification: what a read serves ───────────────────────────
def test_a_protected_path_reads_through(redact: Callable[[str], Any]) -> None:
    """Masking .git/config with the stub would break in-container git outright — it reads
    that file on virtually every command."""
    assert redact("")._classify("/.git/config")[0] == "pass"


def test_a_redacted_file_serves_the_stub(redact: Callable[[str], Any], tmp_path: Path) -> None:
    (tmp_path / "src").mkdir(exist_ok=True)
    (tmp_path / "src" / ".env").write_text("K=v\n")
    assert redact("")._classify("/.env")[0] == "file"


def test_a_placeholder_is_not_redacted(redact: Callable[[str], Any]) -> None:
    assert redact("")._classify("/.env.example")[0] == "pass"


def test_a_redacted_directory_serves_a_single_marker(
    redact: Callable[[str], Any], tmp_path: Path
) -> None:
    (tmp_path / "src" / "secrets").mkdir(parents=True, exist_ok=True)
    r = redact("secrets\n")
    assert r._classify("/secrets") == ("dir", "secrets")
    assert r._classify("/secrets/inner") == ("inside", "secrets")
    assert r.readdir("/secrets", 0) == [".", "..", fuse.REDACTED_NAME]


def test_the_root_always_passes(redact: Callable[[str], Any]) -> None:
    assert redact("")._classify("/") == ("pass", "")


def test_read_of_a_masked_path_with_no_known_shape_returns_the_stub(
    redact: Callable[[str], Any], tmp_path: Path
) -> None:
    (tmp_path / "src").mkdir(exist_ok=True)
    (tmp_path / "src" / "secret.pem").write_text("-----BEGIN KEY-----\nabc\n")
    assert redact("secret.pem\n").read("/secret.pem", 4096, 0, 0) == fuse.STUB


def test_a_masked_path_the_host_does_not_have_is_enoent(
    redact: Callable[[str], Any], tmp_path: Path
) -> None:
    """Redaction hides values, it does not conjure files.

    A synthesised stub made `.env.local` and `.env.development` stat successfully in a project
    holding only `.env`; `nuxi dev` watches that whole set, so the phantoms drove an endless
    restart loop (and leaked an inotify instance per restart, which then read as EMFILE).
    """
    (tmp_path / "src").mkdir(exist_ok=True)
    r = redact("")
    assert r._classify("/.env.local") == ("absent", ".env.local")
    with pytest.raises(OSError) as e:
        r.getattr("/.env.local")
    assert e.value.errno == errno.ENOENT
    with pytest.raises(OSError) as e:
        r.open("/.env.local", os.O_RDONLY)
    assert e.value.errno == errno.ENOENT


def test_a_masked_path_the_host_does_not_have_still_refuses_writes(
    redact: Callable[[str], Any], tmp_path: Path
) -> None:
    """ENOENT on read must not become a create: 'absent' is not 'pass'."""
    (tmp_path / "src").mkdir(exist_ok=True)
    r = redact("")
    with pytest.raises(OSError) as e:
        r.create("/.env.local", 0o644)
    assert e.value.errno == fuse.REFUSED
    assert not (tmp_path / "src" / ".env.local").exists()


# ── format-aware redaction: names visible, values never ──────────
def test_a_dotenv_reads_as_its_key_names(redact: Callable[[str], Any], tmp_path: Path) -> None:
    """The stub hid which settings exist, so the agent asked the user, who pasted the secret
    into the transcript — the stub caused the leak it was preventing."""
    (tmp_path / "src").mkdir(exist_ok=True)
    (tmp_path / "src" / ".env").write_text(
        "# a comment\nAPI_KEY=s3cr3t\n\nexport DB_URL = postgres://u:p@h/db\n"
    )
    out = redact("").read("/.env", 4096, 0, 0).decode()
    assert out == "API_KEY=<redacted>\nDB_URL=<redacted>\n"


def test_a_json_secret_reads_as_its_structure(redact: Callable[[str], Any], tmp_path: Path) -> None:
    (tmp_path / "src").mkdir(exist_ok=True)
    (tmp_path / "src" / "creds.json").write_text('{"tok":"s3cr3t","n":{"list":[1,2]},"ok":true}')
    out = redact("creds.json\n").read("/creds.json", 4096, 0, 0).decode()
    assert "s3cr3t" not in out
    assert '"tok": "<redacted>"' in out and '"list"' in out


@pytest.mark.parametrize(
    "body",
    [
        'CERT="-----BEGIN-----\nMIIsecret\n-----END-----"\n',  # value spans lines
        "NOTKEYVALUE\n",  # nothing parses as an assignment
        '{"unterminated": ',  # not JSON after all
    ],
)
def test_a_shape_the_parser_cannot_vouch_for_falls_back_to_the_stub(
    redact: Callable[[str], Any], tmp_path: Path, body: str
) -> None:
    """A multi-line value's own interior lines match the key pattern, so a lenient parser
    would print fragments of the secret as if they were names."""
    (tmp_path / "src").mkdir(exist_ok=True)
    (tmp_path / "src" / ".env").write_text(body)
    out = redact("").read("/.env", 4096, 0, 0)
    assert out == fuse.STUB
    assert b"MIIsecret" not in out


def test_deeply_nested_json_falls_back_instead_of_erroring(
    redact: Callable[[str], Any], tmp_path: Path
) -> None:
    """Valid JSON that overflows the decoder must read as the stub, not as an I/O error the
    caller cannot explain — RecursionError is not a ValueError."""
    (tmp_path / "src").mkdir(exist_ok=True)
    (tmp_path / "src" / "creds.json").write_text("[" * 30_000 + "]" * 30_000)
    assert redact("creds.json\n").read("/creds.json", 4096, 0, 0) == fuse.STUB


def test_an_oversized_file_is_not_rendered(redact: Callable[[str], Any], tmp_path: Path) -> None:
    """Beyond the cap it is not one of these shapes, whatever it parses as."""
    (tmp_path / "src").mkdir(exist_ok=True)
    (tmp_path / "src" / ".env").write_text("K=v\n" * (fuse.RENDER_MAX // 2))
    assert redact("").read("/.env", 4096, 0, 0) == fuse.STUB


def test_the_reported_size_matches_what_read_serves(
    redact: Callable[[str], Any], tmp_path: Path
) -> None:
    """getattr and read must see ONE render of one version: a size that disagrees with the
    bytes splices two versions of a changing file across a partial read."""
    (tmp_path / "src").mkdir(exist_ok=True)
    (tmp_path / "src" / ".env").write_text("A=1\nB=2\n")
    r = redact("")
    assert r.getattr("/.env")["st_size"] == len(r.read("/.env", 1 << 20, 0, 0))


def test_the_render_cache_follows_the_file(redact: Callable[[str], Any], tmp_path: Path) -> None:
    """Keyed on identity+mtime+size, so an edited file is re-rendered, not served stale."""
    (tmp_path / "src").mkdir(exist_ok=True)
    env = tmp_path / "src" / ".env"
    env.write_text("A=1\n")
    r = redact("")
    assert r.read("/.env", 4096, 0, 0) == b"A=<redacted>\n"
    os.utime(env, (0, 0))
    env.write_text("A=1\nB=2\n")
    assert r.read("/.env", 4096, 0, 0) == b"A=<redacted>\nB=<redacted>\n"


# ── the verdict memo: free, and never stale ──────────────────────
# _classify re-asks _verdict for every ancestor of every getattr/open/read, which at
# node_modules depth was ~0.3 ms of fnmatch per op recomputing an answer that cannot change.
def test_the_verdict_cache_agrees_with_an_uncached_lookup(redact: Callable[..., Any]) -> None:
    """Memoised or not, the answer is the rule list's — including on the second ask."""
    project = "secret.pem\nbuild/*\n!build/keep.txt\n"
    r = redact(project)
    for rel in (
        ".env",
        ".env.example",
        "deep/node_modules/pkg/dist/index.js",
        "sub/.git/config",
        "a/b/.vscode/tasks.json",
        "secret.pem",
        "nested/secret.pem",
        "build/x",
        "build/keep.txt",
    ):
        want = rules.verdict(r.rules, rel)
        assert r._verdict(rel) == want, rel
        assert r._verdict(rel) == want, rel  # the cached hit, not just the cold one


def test_the_verdict_cache_does_not_freeze_the_filesystem_view(
    redact: Callable[..., Any], tmp_path: Path
) -> None:
    """Cache the RULE verdict, never `_classify` — the difference is a shipped bug.

    `_classify` asks the filesystem whether the masked path is actually there, and that answer
    changes under us. Freezing it would restore the phantom `.env.local` that drove `nuxi dev`
    into an endless restart loop (see the 'absent' test above).
    """
    src = tmp_path / "src"
    src.mkdir(exist_ok=True)
    r = redact("")
    assert r._classify("/.env") == ("absent", ".env")
    (src / ".env").write_text("A=1\n")
    assert r._classify("/.env") == ("file", ".env")  # seen at once, no cache to evict
    (src / ".env").unlink()
    assert r._classify("/.env") == ("absent", ".env")


def test_the_verdict_cache_is_bounded(redact: Callable[..., Any]) -> None:
    """A project can hold any number of paths; the sidecar's memory cannot."""
    r = redact("")
    for i in range(fuse.VERDICT_CACHE_MAX + 5):
        r._verdict(f"d{i}/f.js")
    assert len(r._verdicts) <= fuse.VERDICT_CACHE_MAX


# ── protection: what a write is refused ──────────────────────────
@pytest.mark.parametrize(
    "path",
    [
        ".git/config",
        "sub/.git/config",
        ".git/modules/x/config",
        ".git/modules/x/modules/y/config",
        ".git/worktrees/w/config.worktree",
        ".git/hooks/pre-commit",
        "sub/.git/hooks/pre-push",
        ".git/modules/x/hooks/pre-commit",
    ],
)
def test_git_paths_are_protected_at_any_nesting(redact: Callable[[str], Any], path: str) -> None:
    """Submodules and worktrees nest arbitrarily — a tail rule cannot express this, which is
    why it is code rather than a guard pattern."""
    assert redact("")._protected("/" + path) is True


@pytest.mark.parametrize(
    "path",
    [
        ".githooks/pre-commit",
        ".gitmodules",
        ".claude/hooks/notify.sh",
        ".cursor/mcp.json",
        ".zed/tasks.json",
        ".zed/debug.json",
        ".run/app.run.xml",
        ".mvn/jvm.config",
        ".exrc",
        ".nvim.lua",
        ".ripgreprc",
        ".yarnrc.yml",
        "sub/.githooks/pre-push",  # tail-matched, so any depth
        "vendor/pkg/.claude/hooks/x.sh",
    ],
)
def test_non_git_host_executed_paths_are_protected(redact: Callable[[str], Any], path: str) -> None:
    """Every entry names a file the HOST runs later. Writing one from in here is host code
    execution that no container boundary sees."""
    assert redact("")._protected("/" + path) is True


@pytest.mark.parametrize(
    "path",
    [
        "src/main.py",
        "hooks/deploy.sh",
        "config",
        "src/config",
        ".cursor/rules/style.md",  # prompt text, not execution
        ".claude/commands/deploy.md",
        ".claude/settings.json",  # mixed-use: detected by the audit gate, not refused
        ".mcp.json",
        "mise.toml",
    ],
)
def test_lookalike_and_mixed_use_paths_are_not_protected(
    redact: Callable[[str], Any], path: str
) -> None:
    """The guard is pure-exec files only. A refused write here would end the session over
    ordinary work, so mixed-use config is warned about host-side instead."""
    assert redact("")._protected("/" + path) is False


@pytest.mark.parametrize(
    "path", ["/.vscode/settings.json", "/.git/config", "/sub/.githooks/pre-push", "/.envrc"]
)
def test_a_guarded_path_cannot_be_deleted_either(redact: Callable[..., Any], path: str) -> None:
    """Protection covers unlink/rmdir, not only the write: a delete is half of a REPLACE, and
    what is deleted here is the file a host `git checkout` puts straight back. Every path here
    is an ANCHOR (or git's own), so none of them is mirrorable and the refusal is absolute —
    see the mirror cases below for the nested form, and redaction-config-guard.md."""
    with pytest.raises(OSError) as exc:
        redact("").unlink(path)
    assert exc.value.errno == errno.EPERM


def test_a_project_cannot_un_protect_its_own_git_config(redact: Callable[[str], Any]) -> None:
    assert redact("!.git/config\n")._protected("/.git/config") is True


@pytest.mark.parametrize("path", ["/.env", "/.envrc", "/.githooks/pre-commit"])
def test_a_guard_refusal_is_eperm_not_eacces(redact: Callable[[str], Any], path: str) -> None:
    """The reason is logged to the SIDECAR's stderr — a different container — so the agent
    sees an errno and nothing else. EPERM is what distinguishes "the guard refused this"
    from an ordinary owner/mode failure, which `default_permissions` reports as EACCES."""
    with pytest.raises(OSError) as exc:
        redact("").open(path, os.O_WRONLY)
    assert exc.value.errno == errno.EPERM


def test_a_gitdir_is_recognised_by_layout_not_by_name(
    redact: Callable[[str], Any], tmp_path: Path
) -> None:
    """`git init --bare store` puts config+hooks somewhere not called '.git'."""
    store = tmp_path / "src" / "store"
    for marker in fuse.GITDIR_MARKERS:
        (store / marker).mkdir(parents=True, exist_ok=True)
    r = redact("")
    assert r._is_gitdir("store") is True
    assert r._protected("/store/config") is True
    assert r._protected("/store/hooks/pre-commit") is True


# ── mirrors: reproduce, never author ─────────────────────────────
# A guarded path may be written at a NESTED location only as a byte-identical copy of the same
# guarded tail at the project ROOT. That is what lets `git worktree add` check out a repo which
# tracks .vscode/, without ever letting the box author a file the host executes.
ENVRC = "export FOO=1\n"


@pytest.fixture
def anchored(redact: Callable[..., Any], tmp_path: Path) -> Any:
    """A Redact whose src carries the root anchors a host would have committed."""
    src = tmp_path / "src"
    (src / ".vscode").mkdir(parents=True, exist_ok=True)
    (src / ".vscode" / "settings.json").write_text('{"a": 1}\n')
    (src / ".envrc").write_text(ENVRC)
    (src / "wt").mkdir(exist_ok=True)
    return redact("")


def _put(r: Any, path: str, data: bytes) -> None:
    """create + write + release, the only route by which a mirror may appear."""
    fh = r.create(path, 0o644)
    try:
        if data:
            r.write(path, data, 0, fh)
    finally:
        r.release(path, fh)


def test_a_nested_guarded_path_may_be_written_when_it_matches_the_root_copy(
    anchored: Any, tmp_path: Path
) -> None:
    """The checkout half of `git worktree add`. The root copy is one the box cannot write, so
    reproducing it grants nothing the host does not already run."""
    _put(anchored, "/wt/.envrc", ENVRC.encode())
    assert (tmp_path / "src" / "wt" / ".envrc").read_text() == ENVRC


def test_a_nested_guarded_path_is_refused_when_one_byte_differs(anchored: Any) -> None:
    """The bypass that sank the previous attempt: the box can `git commit`, so it decides what
    is "tracked" and could check out a payload of its own. Bytes are the boundary, not tracking."""
    fh = anchored.create("/wt/.envrc", 0o644)
    with pytest.raises(OSError) as exc:
        anchored.write("/wt/.envrc", b"export FOO=2\n", 0, fh)
    assert exc.value.errno == errno.EPERM


def test_a_nested_guarded_path_with_no_root_copy_is_refused(anchored: Any) -> None:
    """The exact payload shape: .vscode/settings.json is tracked, tasks.json is not, and
    tasks.json is the one VS Code executes on folderOpen."""
    with pytest.raises(OSError) as exc:
        anchored.create("/wt/.vscode/tasks.json", 0o644)
    assert exc.value.errno == errno.EPERM


@pytest.mark.parametrize("path", ["/.envrc", "/.vscode/settings.json", "/.vscode"])
def test_the_root_copy_is_never_its_own_mirror(anchored: Any, path: str) -> None:
    """An anchor has no shorter guarded suffix than itself, so it stays absolutely immutable —
    which is the whole reason a mirror of it can be trusted."""
    assert anchored._mirror_anchor(anchored._rel(path)) is None
    assert anchored._mirrorable(path) is False


def test_a_short_mirror_is_unlinked_at_release(anchored: Any, tmp_path: Path) -> None:
    """write() cannot catch this: a prefix of the anchor matches byte for byte as far as it
    goes, and a truncated script is a different script (`rm -rf /tmp/x` cut to `rm -rf /`)."""
    fh = anchored.create("/wt/.envrc", 0o644)
    anchored.write("/wt/.envrc", ENVRC.encode()[:6], 0, fh)
    with pytest.raises(OSError) as exc:
        anchored.release("/wt/.envrc", fh)
    assert exc.value.errno == errno.EPERM
    assert not (tmp_path / "src" / "wt" / ".envrc").exists()  # the unlink IS the enforcement


def test_a_read_only_open_of_a_protected_path_is_never_size_checked(
    anchored: Any, tmp_path: Path
) -> None:
    """release() gets no flags. If it inferred one, every ordinary read of .git/config — which
    has no anchor — would unlink it."""
    (tmp_path / "src" / ".git").mkdir(exist_ok=True)
    (tmp_path / "src" / ".git" / "config").write_text(SAFE)
    anchored.release("/.git/config", anchored.open("/.git/config", os.O_RDONLY))
    assert (tmp_path / "src" / ".git" / "config").exists()


@pytest.mark.parametrize("path", ["/wt/.git/config", "/wt/.git/hooks/pre-commit"])
def test_git_paths_are_never_mirrorable(anchored: Any, tmp_path: Path, path: str) -> None:
    """Checked before any suffix walk. These fire on an ordinary git command with nobody
    asking, so 'the host already runs identical bytes elsewhere' is not a reason to allow one."""
    (tmp_path / "src" / ".git" / "hooks").mkdir(parents=True, exist_ok=True)
    (tmp_path / "src" / ".git" / "config").write_text(SAFE)
    (tmp_path / "src" / ".git" / "hooks" / "pre-commit").write_text("#!/bin/sh\n")
    assert anchored._mirror_anchor(anchored._rel(path)) is None


def test_a_redacted_path_is_never_mirrorable(redact: Callable[..., Any], tmp_path: Path) -> None:
    """Mirroring is a PROTECT relaxation only: a copy of a secret is still the secret."""
    (tmp_path / "src").mkdir(exist_ok=True)
    (tmp_path / "src" / ".env").write_text("A=1\n")
    r = redact("")
    assert r._mirror_anchor("wt/.env") is None
    with pytest.raises(OSError) as exc:
        r.create("/wt/.env", 0o644)
    assert exc.value.errno == errno.EPERM


def test_a_mirror_cannot_be_laundered_in_by_rename(anchored: Any, tmp_path: Path) -> None:
    """A rename moves bytes the guard never compared. Without the opt-out, writing the payload
    to an unguarded name and renaming it onto a guarded one bypasses every content check."""
    (tmp_path / "src" / "wt" / "payload").write_text("export FOO=2\n")
    with pytest.raises(OSError) as exc:
        anchored.rename("/wt/payload", "/wt/.envrc")
    assert exc.value.errno == errno.EPERM


@pytest.mark.parametrize(("op", "source"), [("symlink", "/etc/passwd"), ("link", "/wt/payload")])
def test_a_mirror_cannot_be_laundered_in_by_a_link(
    anchored: Any, tmp_path: Path, op: str, source: str
) -> None:
    """A symlink's content is a path, and a hardlink's inode keeps changing after the check."""
    (tmp_path / "src" / "wt" / "payload").write_text("export FOO=2\n")
    with pytest.raises(OSError) as exc:
        getattr(anchored, op)("/wt/.envrc", source)
    assert exc.value.errno == errno.EPERM


def test_a_mirror_cannot_be_reshaped_by_truncate(anchored: Any) -> None:
    """A standalone truncate cannot produce an identical copy, only a short one — and it never
    passes through release()'s size check."""
    _put(anchored, "/wt/.envrc", ENVRC.encode())
    with pytest.raises(OSError) as exc:
        anchored.truncate("/wt/.envrc", 6)
    assert exc.value.errno == errno.EPERM


def test_a_guarded_directory_may_be_created_when_the_root_one_exists(
    anchored: Any, tmp_path: Path
) -> None:
    """`git worktree add` makes .vscode/ before it writes into it. An empty directory executes
    nothing, and what goes inside is checked file by file."""
    anchored.mkdir("/wt/.vscode", 0o755)
    assert (tmp_path / "src" / "wt" / ".vscode").is_dir()


def test_a_mirror_may_be_deleted_but_its_anchor_may_not(anchored: Any, tmp_path: Path) -> None:
    """`git worktree remove` has to work. Deleting is safe precisely because recreating is
    constrained: the only thing that can come back is the anchor's own bytes."""
    _put(anchored, "/wt/.envrc", ENVRC.encode())
    anchored.unlink("/wt/.envrc")
    assert not (tmp_path / "src" / "wt" / ".envrc").exists()
    with pytest.raises(OSError) as exc:
        anchored.unlink("/.envrc")
    assert exc.value.errno == errno.EPERM


# ── git config write validation ──────────────────────────────────
@pytest.mark.parametrize(
    ("candidate", "current", "allowed"),
    [
        (SAFE, SAFE, True),
        (SAFE + "[core]\n\tfsmonitor = /e\n", SAFE, False),
        (SAFE + "[core]\n\thooksPath = .git/alt\n", SAFE, False),
        (SAFE + "[alias]\n\tst = !/e\n", SAFE, False),
        (SAFE + "[include]\n\tpath = evil.inc\n", SAFE, False),
        ("[core]hooksPath = /tmp/evil\n", SAFE, False),  # the one-line form
        (LFS, SAFE, False),  # newly ADDED filter
        (LFS + '[remote "n"]\n\turl = h\n', LFS, True),  # pre-existing filter, new remote
        (LFS + "[core]\n\tfsmonitor = /e\n", LFS, False),  # pre-existing filter, NEW fsmonitor
    ],
)
def test_git_config_write_validation(
    redact: Callable[[str], Any],
    write_file: Callable[[str, str], Path],
    candidate: str,
    current: str,
    allowed: bool,
) -> None:
    """Compared against the current file, not judged absolutely: a repo that already has a
    git-lfs filter is the user's own host-side config, and adding a remote must not trip
    over it. Only entries the sandbox is *adding* are refused."""
    src = write_file("candidate", candidate)
    dst = write_file("current", current)
    assert redact("")._git_config_write_ok(str(src), str(dst)) is allowed


def test_unreadable_candidate_fails_closed(
    redact: Callable[[str], Any], write_file: Callable[[str, str], Path]
) -> None:
    dst = write_file("current", SAFE)
    assert redact("")._git_config_write_ok("/nonexistent", str(dst)) is False


def test_undecodable_candidate_fails_closed(
    redact: Callable[[str], Any], tmp_path: Path, write_file: Callable[[str, str], Path]
) -> None:
    binary = tmp_path / "binary"
    binary.write_bytes(b"\xff\xfe\x00config")
    dst = write_file("current", SAFE)
    assert redact("")._git_config_write_ok(str(binary), str(dst)) is False


def test_a_missing_current_file_is_treated_as_empty(
    redact: Callable[[str], Any], write_file: Callable[[str, str], Path]
) -> None:
    """A brand-new repo has no config to compare against; a dangerous key is still refused."""
    src = write_file("candidate", SAFE + "[core]\n\tfsmonitor = /e\n")
    assert redact("")._git_config_write_ok(str(src), "/nonexistent") is False


# ── ownership remap (macOS virtiofs reports root:root) ───
def test_ownership_passes_through_by_default(redact: Callable[..., Any], tmp_path: Path) -> None:
    """A standalone mount with no --uid/--gid must keep reporting the real ownership."""
    (tmp_path / "src").mkdir(exist_ok=True)
    (tmp_path / "src" / "f").write_text("x")
    attr = redact("").getattr("/f")
    assert (attr["st_uid"], attr["st_gid"]) == (os.getuid(), os.getgid())


def test_the_project_owner_is_reported_as_the_agent(
    redact: Callable[..., Any], tmp_path: Path
) -> None:
    """Without this git reads the whole tree as another user's and refuses it."""
    (tmp_path / "src").mkdir(exist_ok=True)
    (tmp_path / "src" / "f").write_text("x")
    attr = redact("", uid=501, gid=20).getattr("/f")
    assert (attr["st_uid"], attr["st_gid"]) == (501, 20)


def test_the_remap_covers_the_redaction_stub(redact: Callable[..., Any], tmp_path: Path) -> None:
    """A stubbed path is synthesised, not stat'd — it needs the same owner or `ls` of a
    redacted file disagrees with its directory."""
    (tmp_path / "src").mkdir(exist_ok=True)
    (tmp_path / "src" / ".env").write_text("K=v\n")
    attr = redact("", uid=501, gid=20).getattr("/.env")
    assert (attr["st_uid"], attr["st_gid"]) == (501, 20)


def test_the_remap_does_not_change_the_verdict(redact: Callable[..., Any], tmp_path: Path) -> None:
    """Redaction is presentation-independent: the remap must not open a masked path."""
    (tmp_path / "src").mkdir(exist_ok=True)
    (tmp_path / "src" / ".env").write_text("K=v\n")
    assert redact("", uid=501, gid=20)._classify("/.env")[0] == "file"


def test_chown_to_the_invented_owner_is_a_no_op(
    redact: Callable[..., Any], tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """`cp -p`/`git checkout` echo back the ids we invented; forwarding them would rewrite the
    backing file to an owner it never had."""
    (tmp_path / "src").mkdir(exist_ok=True)
    (tmp_path / "src" / "f").write_text("x")
    seen: list[tuple[int, int]] = []
    monkeypatch.setattr(os, "chown", lambda p, u, g: seen.append((u, g)))
    redact("", uid=501, gid=20).chown("/f", 501, 20)
    assert seen == [(-1, -1)]


def test_chown_to_a_different_owner_still_passes_through(
    redact: Callable[..., Any], tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    (tmp_path / "src").mkdir(exist_ok=True)
    (tmp_path / "src" / "f").write_text("x")
    seen: list[tuple[int, int]] = []
    monkeypatch.setattr(os, "chown", lambda p, u, g: seen.append((u, g)))
    redact("", uid=501, gid=20).chown("/f", 4242, 20)
    assert seen == [(4242, -1)]


def test_chown_of_a_masked_path_is_still_refused(redact: Callable[..., Any]) -> None:
    with pytest.raises(OSError):
        redact("", uid=501, gid=20).chown("/.env", 501, 20)


def test_a_foreign_owner_is_reported_as_itself(redact: Callable[..., Any], tmp_path: Path) -> None:
    """The remap covers the project's own owner and nobody else — otherwise a root-owned
    file inside the tree would report as the agent's and `default_permissions` would let the
    agent write it."""
    (tmp_path / "src").mkdir(exist_ok=True)
    (tmp_path / "src" / "f").write_text("x")
    r = redact("", uid=501, gid=20)
    r.base_uid, r.base_gid = os.getuid() + 4242, os.getgid() + 4242  # nobody owns the file
    attr = r.getattr("/f")
    assert (attr["st_uid"], attr["st_gid"]) == (os.getuid(), os.getgid())


# ── adoption: the root server must not leave root-owned files ─────
def test_a_created_file_is_given_to_the_caller(
    redact: Callable[..., Any], tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The server is root, so an un-adopted create lands on the HOST owned by root."""
    (tmp_path / "src").mkdir(exist_ok=True)
    seen: list[tuple[int, int]] = []
    monkeypatch.setattr(os, "fchown", lambda fd, u, g: seen.append((u, g)))
    os.close(redact("", uid=501, gid=20).create("/new", 0o644))
    assert seen == [(os.getuid(), os.getgid())]


def test_a_created_directory_is_given_to_the_caller(
    redact: Callable[..., Any], tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    (tmp_path / "src").mkdir(exist_ok=True)
    seen: list[tuple[int, int]] = []
    monkeypatch.setattr(os, "chown", lambda p, u, g, follow_symlinks=True: seen.append((u, g)))
    redact("", uid=501, gid=20).mkdir("/d", 0o755)
    assert seen == [(os.getuid(), os.getgid())]


def test_an_adopted_symlink_is_not_dereferenced(
    redact: Callable[..., Any], tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Following it would re-own the target — which may be anywhere, including outside src."""
    (tmp_path / "src").mkdir(exist_ok=True)
    seen: list[bool] = []
    monkeypatch.setattr(
        os, "chown", lambda p, u, g, follow_symlinks=True: seen.append(follow_symlinks)
    )
    redact("", uid=501, gid=20).symlink("/l", "/etc/passwd")
    assert seen == [False]


def test_adoption_failure_does_not_fail_the_create(
    redact: Callable[..., Any], tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """virtiofs ignores chown outright; a create must not start failing because of it."""
    (tmp_path / "src").mkdir(exist_ok=True)

    def _boom(fd: int, u: int, g: int) -> None:
        raise OSError(1, "Operation not permitted")

    monkeypatch.setattr(os, "fchown", _boom)
    os.close(redact("", uid=501, gid=20).create("/new", 0o644))
    assert (tmp_path / "src" / "new").exists()
