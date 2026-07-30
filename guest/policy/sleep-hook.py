#!/usr/bin/env python3
"""Claude Code hook → the sleep guard's activity state. Runs INSIDE the box, once per event.

Replaces the old `wchar` TUI-byte sampler, which could not see a background subagent (it
writes almost nothing to the terminal) and could not tell a long think from a question
waiting on the user. Hooks report Claude's own state machine, so both are exact.

The state is a directory of MARKER FILES per session tag, never a counter in one file:
concurrent hooks run in parallel, and create/unlink are atomic where a read-modify-write of a
shared counter would lose updates.

    <root>/<tag>/live          hooks are working at all (SessionStart)
    <root>/<tag>/turn          a turn is in flight (UserPromptSubmit → Stop)
    <root>/<tag>/wait          blocked on the USER (question, permission prompt)
    <root>/<tag>/agents/<id>   one file per live subagent (SubagentStart → SubagentStop)

    BUSY := (turn AND NOT wait) OR any agents/*

`wait` suppresses only the turn, never the agents: background subagents keep running while a
question sits unanswered, and that has to hold the machine awake. Bound :ro at
/etc/claude-code/, so the session cannot edit the code that reports on it.

NEVER writes stdout — on UserPromptSubmit and SessionStart that is injected into the model's
context — and ALWAYS exits 0: a sleep inhibitor must not be able to break a session.
"""

from __future__ import annotations

import json
import os
import shutil
import sys

ROOT = "/run/kib/sleep"  # kib's own bind; the container path is a constant, not configurable


def _session_dir() -> str | None:
    """This terminal's state dir. Scoped by KIB_SESSION_TAG, which hooks inherit from the
    session's environ — one container serves every terminal, so a container-wide state would
    have three tabs hold three inhibitors for one tab's work."""
    tag = os.environ.get("KIB_SESSION_TAG", "")
    # No path separators: the tag is kib's own (`kib-<pid>-<epoch>`), but this file must not be
    # the thing that turns a surprising value into a write outside ROOT.
    if not tag or "/" in tag or tag.startswith("."):
        return None
    return os.path.join(ROOT, tag)


def _touch(path: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w"):
        pass


def _rm(path: str) -> None:
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except Exception:  # noqa: BLE001 — a malformed payload must not break the session
        return
    if not isinstance(payload, dict):
        return

    base = _session_dir()
    if base is None:
        return

    event = str(payload.get("hook_event_name", ""))
    agent_id = payload.get("agent_id")
    agents = os.path.join(base, "agents")

    # A subagent's own tool calls carry agent_id and share the parent's session_id. They must
    # not touch the parent's turn/wait markers — the agents/ files already cover them, and a
    # subagent's PostToolUse would otherwise clear a `wait` the user is still sitting on.
    if agent_id and event not in ("SubagentStart", "SubagentStop"):
        return

    if event == "SessionStart":
        _touch(os.path.join(base, "live"))
    elif event == "UserPromptSubmit":
        _touch(os.path.join(base, "turn"))
        _rm(os.path.join(base, "wait"))  # a new prompt means the previous wait was answered
    elif event in ("Stop", "StopFailure"):
        # StopFailure too: a turn that died on an API error never sees Stop, and without this
        # the turn marker would pin the machine awake until the staleness backstop fired.
        _rm(os.path.join(base, "turn"))
        _rm(os.path.join(base, "wait"))
    elif event == "SubagentStart":
        if agent_id:
            _touch(os.path.join(agents, str(agent_id).replace("/", "_")))
    elif event == "SubagentStop":
        if agent_id:
            _rm(os.path.join(agents, str(agent_id).replace("/", "_")))
    elif event in ("PreToolUse", "PermissionRequest"):
        # AskUserQuestion is an ordinary tool call in flight — Claude is "waiting on a tool
        # result", so no Notification or Elicitation event fires for it (anthropics/claude-code
        # #59908, #44326). PreToolUse is the only edge that brackets the wait, and its matcher
        # keeps this to the two tools that actually block on a human.
        _touch(os.path.join(base, "wait"))
    elif event in ("PostToolUse", "PostToolUseFailure", "PermissionDenied"):
        # Unmatched (every tool), not just the blocking ones: a permission prompt granted
        # mid-turn is cleared by ITS tool completing. Matching only the blocking tools here
        # would leave `wait` set for the rest of the turn and let the machine sleep mid-work.
        _rm(os.path.join(base, "wait"))
    elif event == "Notification":
        _touch(os.path.join(base, "wait"))
    elif event == "SessionEnd":
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    try:
        main()
    except Exception:  # noqa: BLE001
        pass
    # Always 0, always silent: exit 2 would block the event, and stdout on UserPromptSubmit /
    # SessionStart is fed to the model as context.
    sys.exit(0)
