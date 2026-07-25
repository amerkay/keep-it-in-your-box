"""Shared pytest fixtures, and the one sys.path entry that makes `import kib` work.

The repo is scripts plus one importable package, with no `[project]` table and nothing
installed — so the package root has to go on sys.path explicitly. Doing it here rather than
in each suite keeps the test files free of import boilerplate.
"""

import json
import os
import subprocess
import sys
from collections.abc import Callable, Iterator
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

import pytest  # noqa: E402  — must follow the sys.path insertion above


@pytest.fixture
def write_file(tmp_path: Path) -> Callable[[str, str], Path]:
    """Write text to `tmp_path/<name>`, creating parents. Returns the path."""

    def _write(name: str, text: str) -> Path:
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    return _write


@pytest.fixture
def write_json(tmp_path: Path) -> Callable[[str, object], Path]:
    """Write an object as JSON to `tmp_path/<name>`. Returns the path."""

    def _write(name: str, obj: object) -> Path:
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(obj))
        return path

    return _write


@pytest.fixture
def git_repo(tmp_path: Path) -> Callable[..., Path]:
    """Create a real git repo under tmp_path. `GIT_TEMPLATE_DIR=` keeps sample hooks out."""

    def _repo(name: str, *args: str) -> Path:
        path = tmp_path / name
        env = {**os.environ, "GIT_TEMPLATE_DIR": ""}
        subprocess.run(
            ["git", "init", "-q", *args, str(path)], check=True, env=env, capture_output=True
        )
        return path

    return _repo


@pytest.fixture
def providers_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Iterator[Path]:
    """An isolated `providers.d`, wired up via KIB_PROVIDERS_DIR.

    The registry is module-level state, so it is snapshotted and restored: a user def merged
    by one test must not leak into the next one's view of the table.
    """
    from kib.broker import registry

    original = {k: dict(v) for k, v in registry.PROVIDERS.items()}
    path = tmp_path / "providers.d"
    path.mkdir(parents=True, exist_ok=True)
    monkeypatch.setenv("KIB_PROVIDERS_DIR", str(path))
    yield path
    registry.PROVIDERS.clear()
    registry.PROVIDERS.update(original)
