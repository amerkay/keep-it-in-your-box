"""The forced/seeded keys in a session's `.claude.json`.

Two behaviours that must not drift into each other: a PIN is re-asserted every launch (the
sandbox depends on the value), a SEED is written only when absent (the user owns it after
that). Both write in place, so both have to leave an unreadable file alone.
"""

import json
from collections.abc import Callable
from pathlib import Path

from kib.host import pins
from kib.shared import cli


def read(path: Path) -> dict[str, object]:
    obj = json.loads(path.read_text())
    assert isinstance(obj, dict)
    return obj


# ── pins ─────────────────────────────────────────────────────────
def test_apply_forces_a_wrong_pin(write_json: Callable[[str, object], Path]) -> None:
    cfg = write_json("c.json", {"leftArrowOpensAgents": True, "theme": "dark"})
    assert pins.apply(str(cfg)) == cli.OK
    out = read(cfg)
    assert out["leftArrowOpensAgents"] is False
    assert out["theme"] == "dark"  # nothing else touched


def test_apply_does_not_rewrite_an_already_pinned_file(
    write_json: Callable[[str, object], Path],
) -> None:
    cfg = write_json("c.json", {"leftArrowOpensAgents": False})
    before = cfg.stat().st_mtime_ns
    assert pins.apply(str(cfg)) == cli.OK
    assert cfg.stat().st_mtime_ns == before  # no clobber window for a concurrent session


# ── brokered seeds ───────────────────────────────────────────────
def test_seed_skips_the_in_box_login_when_the_credential_is_brokered(
    write_json: Callable[[str, object], Path],
) -> None:
    """The bug: a fresh host has no flag to inherit, so the box opened on 'Select login
    method' while the broker held a working token."""
    cfg = write_json("c.json", {"projects": {}})
    assert pins.seed_brokered(str(cfg)) == cli.OK
    assert read(cfg)["hasCompletedOnboarding"] is True


def test_seed_never_overwrites_the_users_own_value(
    write_json: Callable[[str, object], Path],
) -> None:
    cfg = write_json("c.json", {"hasCompletedOnboarding": False})
    assert pins.seed_brokered(str(cfg)) == cli.OK
    assert read(cfg)["hasCompletedOnboarding"] is False


def test_seed_leaves_an_unreadable_config_alone(
    write_file: Callable[[str, str], Path],
) -> None:
    cfg = write_file("c.json", "{not json")
    assert pins.seed_brokered(str(cfg)) == cli.FAIL
    assert cfg.read_text() == "{not json"
