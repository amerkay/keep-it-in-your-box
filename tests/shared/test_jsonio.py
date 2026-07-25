"""Atomic JSON writes — the dance that was written out twice and had already drifted.

The mode matters as much as the atomicity: these files hold a session's whole config, and one
of the two old copies forgot the chmod.
"""

import json
import os
import tempfile
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest

from kib.shared import jsonio


def test_load_reports_absent(tmp_path: Path) -> None:
    obj, status = jsonio.load(str(tmp_path / "nope.json"))
    assert (obj, status) == (None, "absent")


def test_load_reports_bad(write_file: Callable[[str, str], Path]) -> None:
    obj, status = jsonio.load(str(write_file("bad.json", "{not json")))
    assert (obj, status) == (None, "bad")


def test_load_reports_ok(write_json: Callable[[str, object], Path]) -> None:
    obj, status = jsonio.load(str(write_json("ok.json", {"a": 1})))
    assert (obj, status) == ({"a": 1}, "ok")


def test_load_dict_swallows_absent_and_bad(
    tmp_path: Path, write_file: Callable[[str, str], Path]
) -> None:
    assert jsonio.load_dict(str(tmp_path / "nope.json")) == {}
    assert jsonio.load_dict(str(write_file("bad.json", "[1,2]"))) == {}


def test_write_atomic_creates_parents_and_writes_json(tmp_path: Path) -> None:
    path = tmp_path / "deep" / "nested" / "cfg.json"
    jsonio.write_atomic(str(path), {"b": [1, 2]})
    assert json.loads(path.read_text()) == {"b": [1, 2]}


def test_write_atomic_is_never_world_readable(tmp_path: Path) -> None:
    path = tmp_path / "cred.json"
    jsonio.write_atomic(str(path), {"secret": "x"})
    assert path.stat().st_mode & 0o777 == 0o600


def test_write_atomic_replaces_in_place(write_json: Callable[[str, object], Path]) -> None:
    path = write_json("cfg.json", {"old": True})
    jsonio.write_atomic(str(path), {"new": True})
    assert json.loads(path.read_text()) == {"new": True}


def test_write_atomic_leaves_no_temp_file_behind(tmp_path: Path) -> None:
    jsonio.write_atomic(str(tmp_path / "cfg.json"), {"a": 1})
    assert [p.name for p in tmp_path.iterdir()] == ["cfg.json"]


def test_write_atomic_stages_in_the_destination_directory(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A /tmp staging file would make os.replace a cross-device copy — no longer atomic."""
    seen: list[str] = []
    real_mkstemp = tempfile.mkstemp

    def spy(*args: Any, **kwargs: Any) -> tuple[int, str]:
        seen.append(str(kwargs.get("dir")))
        return real_mkstemp(*args, **kwargs)

    monkeypatch.setattr(tempfile, "mkstemp", spy)
    jsonio.write_atomic(str(tmp_path / "cfg.json"), {"a": 1})
    assert seen == [str(tmp_path)]


def test_write_atomic_cleans_up_when_serialisation_fails(tmp_path: Path) -> None:
    class Unserialisable:
        pass

    try:
        jsonio.write_atomic(str(tmp_path / "cfg.json"), {"bad": Unserialisable()})
    except TypeError:
        pass
    assert os.listdir(tmp_path) == []
