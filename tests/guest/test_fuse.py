"""The FUSE server's own logic: what is a git dir, what is protected, what a read serves.

Rule parsing and matching are covered in tests/shared/test_rules.py — this suite is the
filesystem translation on top of them, plus the git-config write validator, which is the one
place the sandbox is allowed to write a host-executed file at all.

Runs anywhere, including inside the sandbox: the `fuse` module is stubbed so the server
imports without libfuse, and no real mount is touched.
"""

import sys
import types
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest

# Stub fusepy before importing the server: the image has it, a bare test host may not, and
# nothing here needs a real mount.
_fuse = types.ModuleType("fuse")
_fuse.__dict__.update(
    FUSE=lambda *a, **k: None,
    Operations=object,
    FuseOSError=type("FuseOSError", (OSError,), {}),
)
sys.modules.setdefault("fuse", _fuse)

from kib.guest import fuse  # noqa: E402  — must follow the stub above
from kib.shared import rules  # noqa: E402

GUARD = Path(__file__).resolve().parent.parent.parent / "guest" / "policy" / "global.kibignore"

SAFE = '[core]\n\trepositoryformatversion = 0\n[remote "origin"]\n\turl = https://x/y\n'
LFS = SAFE + '[filter "lfs"]\n\tclean = git-lfs clean\n'


@pytest.fixture
def redact(tmp_path: Path) -> Callable[[str], Any]:
    """A Redact bound to a real (empty) src dir, with the shipped guard + project rules."""

    def _build(project: str = "") -> Any:
        src = tmp_path / "src"
        src.mkdir(exist_ok=True)
        rule_list = rules.load(str(GUARD), guard=True) + rules.parse(project.splitlines())
        return fuse.Redact(str(src), rule_list)

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


def test_read_of_a_masked_path_returns_the_stub(redact: Callable[[str], Any]) -> None:
    assert redact("")._classify("/.env")[0] == "file"
    assert redact("").read("/.env", 4096, 0, 0) == fuse.STUB


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


@pytest.mark.parametrize("path", ["src/main.py", "hooks/deploy.sh", "config", "src/config"])
def test_lookalike_paths_are_not_protected(redact: Callable[[str], Any], path: str) -> None:
    assert redact("")._protected("/" + path) is False


def test_a_project_cannot_un_protect_its_own_git_config(redact: Callable[[str], Any]) -> None:
    assert redact("!.git/config\n")._protected("/.git/config") is True


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
