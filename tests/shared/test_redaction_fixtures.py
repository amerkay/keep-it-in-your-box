"""The host's one Python copy of the Go view's logic, `dangerous.py` (the asset scan), stays on
its spec: tests/fixtures/redaction/gitconfig.json."""

import json
from pathlib import Path
from typing import Any

import pytest

from kib.shared import dangerous

HERE = Path(__file__).resolve().parents[1] / "fixtures" / "redaction"


def _load(name: str) -> Any:
    return json.loads((HERE / name).read_text())


@pytest.mark.parametrize("case", _load("gitconfig.json")["entries"])
def test_git_entries(case: dict[str, Any]) -> None:
    assert sorted(list(e) for e in dangerous.git_ini_entries(case["text"])) == case["want"]
