"""The Go port's fixtures must say what today's Python does (TMP_PLAN_GO_FUSE.md Phase 0)."""

import importlib.util
from pathlib import Path

HERE = Path(__file__).resolve().parents[1] / "fixtures" / "redaction"


def test_the_fixtures_are_current() -> None:
    spec = importlib.util.spec_from_file_location("record", HERE / "record.py")
    assert spec and spec.loader
    record = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(record)
    stale = [rel for rel, body in record.build().items() if (HERE / rel).read_bytes() != body]
    assert not stale, f"run python3 tests/fixtures/redaction/record.py: {stale}"
