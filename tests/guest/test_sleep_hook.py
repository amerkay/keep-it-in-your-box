"""The sleep hook's heartbeat — the half of the liveness rule that lives in the box.

host/sleep-state.sh reads a marker nothing has touched within its window as work that is over,
because an interrupted turn clears nothing. That is only safe if live work keeps its own marker
warm, and if a silent tool call declares how long it may be silent — which is what these
assert. Host half: tests/check/shims.sh.
"""

import importlib.util
import io
import json
import os
import sys
from pathlib import Path
from types import ModuleType

import pytest

HOOK = Path(__file__).resolve().parents[2] / "guest" / "policy" / "sleep-hook.py"


@pytest.fixture
def hook(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> ModuleType:
    """The hook module, with its marker root redirected out of /run/kib/sleep."""
    spec = importlib.util.spec_from_file_location("sleep_hook", HOOK)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    monkeypatch.setattr(mod, "ROOT", str(tmp_path))
    monkeypatch.setenv("KIB_SESSION_TAG", "tag")
    return mod


def fire(hook: ModuleType, event: str, **extra: object) -> None:
    payload = {"hook_event_name": event, **extra}
    sys.stdin = io.StringIO(json.dumps(payload))  # main() reads the event off stdin
    try:
        hook.main()
    finally:
        sys.stdin = sys.__stdin__


def test_events_keep_their_own_marker_warm(hook: ModuleType, tmp_path: Path) -> None:
    """The host expires what stops being touched, so live work has to keep touching it — and
    nothing may resurrect a marker whose work is over, or the next idle session is pinned."""
    session = tmp_path / "tag"
    agent, turn = session / "agents" / "a1", session / "turn"

    fire(hook, "SubagentStart", agent_id="a1", agent_type="general-purpose")
    fire(hook, "UserPromptSubmit")
    os.utime(agent, (0, 0))
    os.utime(turn, (0, 0))

    # A subagent's own tool call warms ITS marker and touches nothing else — clearing the
    # parent's `wait` here would let the machine sleep on a question the user is still reading.
    (session / "wait").touch()
    fire(hook, "PostToolUse", agent_id="a1", tool_use_id="t0")
    assert agent.stat().st_mtime > 0
    assert turn.stat().st_mtime == 0
    assert (session / "wait").exists()

    fire(hook, "PostToolUse", tool_use_id="t0")
    assert turn.stat().st_mtime > 0

    fire(hook, "SubagentStop", agent_id="a1")
    fire(hook, "Stop")
    fire(hook, "PostToolUse", agent_id="a1", tool_use_id="t0")
    fire(hook, "PostToolUse", tool_use_id="t0")
    assert not agent.exists() and not turn.exists()


def tools(tmp_path: Path) -> list[str]:
    d = tmp_path / "tag" / "tools"
    return sorted(p.name for p in d.iterdir()) if d.is_dir() else []


def test_a_tool_call_declares_how_long_it_may_stay_silent(hook: ModuleType, tmp_path: Path) -> None:
    """The budget is the call's own timeout: how long a live call may be quiet, and — since Esc
    fires no PostToolUse — how long an abandoned marker can lie. Default when undeclared,
    capped so a silly timeout cannot pin the machine, and removed by the call's own end."""
    fire(hook, "PreToolUse", tool_name="Bash", tool_use_id="t1", tool_input={"timeout": 600_000})
    fire(hook, "PreToolUse", tool_name="Read", tool_use_id="t2", tool_input={})
    fire(hook, "PreToolUse", tool_name="Bash", tool_use_id="t3", tool_input={"timeout": 9_000_000})
    assert tools(tmp_path) == ["t1.10", "t2.2", "t3.15"]

    fire(hook, "PostToolUse", tool_name="Bash", tool_use_id="t1", tool_input={"timeout": 600_000})
    fire(hook, "PostToolUseFailure", tool_name="Bash", tool_use_id="t3", tool_input={})
    assert tools(tmp_path) == ["t2.2"]

    # The two tools that block on a human get `wait` and NO work marker: a marker would hold the
    # machine awake for its budget with nobody working — the case the guard exists to avoid.
    fire(hook, "PreToolUse", tool_name="AskUserQuestion", tool_use_id="q", tool_input={})
    assert tools(tmp_path) == ["t2.2"]
    assert (tmp_path / "tag" / "wait").exists()
