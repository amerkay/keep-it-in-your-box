"""The host's Python copies stay on the Go view's spec (tests/fixtures/redaction): `rules.py`
for the sync and the audit, `render.py` for the sync, `dangerous.py` for the asset scan. A
fixture's `note` marks where Go deliberately differs; those cases are Go's to check."""

import json
from pathlib import Path
from typing import Any

import pytest

from kib.shared import dangerous, render, rules

HERE = Path(__file__).resolve().parents[1] / "fixtures" / "redaction"
GUARD = HERE.parents[2] / "guest" / "policy" / "global.kibignore"


def _load(name: str) -> Any:
    return json.loads((HERE / name).read_text())


@pytest.mark.parametrize("case", [c for c in _load("rules.json")["verdict"] if "note" not in c])
def test_verdicts(case: dict[str, Any]) -> None:
    project = rules.parse(case["project"].splitlines())
    guard = rules.load(str(GUARD), guard=True) if case["guard"] else []
    assert rules.verdict(guard + project, case["path"]) == case["want"]


@pytest.mark.parametrize("name", sorted(_load("render.json")["cases"]))
def test_renders(name: str) -> None:
    want = _load("render.json")["cases"][name]
    out = render.render(str(HERE / "render" / name))
    if want["shape"] == "stub":
        assert out == render.STUB
    elif want["shape"] == "dotenv":
        assert [ln.split("=")[0] for ln in out.decode().splitlines()] == want["keys"]
    elif want["shape"] == "json":
        assert json.loads(out) == want["tree"]
    else:
        import yaml

        assert json.loads(json.dumps(list(yaml.safe_load_all(out)))) == want["docs"]
    assert b"s3cr3t" not in out


@pytest.mark.parametrize("case", _load("gitconfig.json")["entries"])
def test_git_entries(case: dict[str, Any]) -> None:
    assert sorted(list(e) for e in dangerous.git_ini_entries(case["text"])) == case["want"]
