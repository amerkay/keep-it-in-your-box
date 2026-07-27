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


def test_a_redacted_file_serves_the_stub(redact: Callable[[str], Any]) -> None:
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


def test_a_missing_masked_file_still_serves_the_stub(redact: Callable[[str], Any]) -> None:
    """Nothing on disk to render, and the path must stay masked rather than 404 into a create."""
    assert redact("").read("/.env", 4096, 0, 0) == fuse.STUB


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
    what is deleted here is the file a host `git checkout` puts straight back. The cost is that
    a guarded path which is also TRACKED cannot be checked out in the box at all — see
    redaction-config-guard.md."""
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


def test_the_remap_covers_the_redaction_stub(redact: Callable[..., Any]) -> None:
    """A stubbed path is synthesised, not stat'd — it needs the same owner or `ls` of a
    redacted file disagrees with its directory."""
    attr = redact("", uid=501, gid=20).getattr("/.env")
    assert (attr["st_uid"], attr["st_gid"]) == (501, 20)


def test_the_remap_does_not_change_the_verdict(redact: Callable[..., Any]) -> None:
    """Redaction is presentation-independent: the remap must not open a masked path."""
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
