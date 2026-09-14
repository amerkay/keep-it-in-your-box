#!/usr/bin/env python3
"""Claude Code hook → the sleep guard's activity state. Runs INSIDE the box, once per event.

Replaces the old `wchar` TUI-byte sampler, which could not see a background subagent (it
writes almost nothing to the terminal) and could not tell a long think from a question
waiting on the user. Hooks report Claude's own state machine, so both are exact.

The state is a directory of MARKER FILES per session tag, never a counter in one file:
concurrent hooks run in parallel, and create/unlink are atomic where a read-modify-write of a
shared counter would lose updates.

    <root>/<tag>/live              hooks are working at all (SessionStart)
    <root>/<tag>/turn              a turn is in flight (UserPromptSubmit → Stop)
    <root>/<tag>/wait              blocked on the USER (question, permission prompt)
    <root>/<tag>/agents/<id>       one live subagent (SubagentStart → SubagentStop)
    <root>/<tag>/tools/<id>.<min>  one tool call (PreToolUse → PostToolUse*), named with the
                                   minutes it may stay silent

    BUSY := (turn AND NOT wait) OR any agents/* OR any tools/* — each counted only while
            younger than ITS OWN window (host/sleep-state.sh)

ESC FIRES NO HOOK AND WRITES NOTHING: an interrupted turn's Stop/PostToolUse* run with the
abort signal that just fired (`if (signal?.aborted) return`), and its transcript stops at the
user's own prompt until the session next continues. So nothing marks the end of an interrupted
turn, and every event here doubles as a heartbeat — the host expires what stops being touched.
A tool call carries its own window because it, alone, can legitimately be silent for minutes.

`wait` suppresses only the turn, never the agents: background subagents keep running while a
question sits unanswered, and that has to hold the machine awake. Bound :ro at
/etc/claude-code/, so the session cannot edit the code that reports on it.

NEVER writes stdout — on UserPromptSubmit and SessionStart that is injected into the model's
context — and ALWAYS exits 0: a sleep inhibitor must not be able to break a session.
"""

from __future__ import annotations

import glob
import json
import math
import os
import shutil
import sys

ROOT = "/run/kib/sleep"  # kib's own bind; the container path is a constant, not configurable
DEFAULT_TOOL_MS = 120_000  # Claude's own default tool timeout, for a call that declares none
MAX_TOOL_MIN = 15  # cap on a declared timeout, so a silly one cannot pin the machine
BLOCKING_TOOLS = ("AskUserQuestion", "ExitPlanMode")  # the tools that wait on a human


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


def _beat(path: str) -> None:
    """Refresh an EXISTING marker's mtime — never create one (utime raises if it is gone)."""
    try:
        os.utime(path, None)
    except OSError:
        pass


def _tool_marker(base: str, payload: dict[str, object]) -> str | None:
    """`tools/<tool_use_id>.<minutes>` — a call in flight, and how long it may stay silent.

    The budget is the call's own timeout, capped: a call cannot outlive it, so that is both how
    long a live one may be quiet and how long an interrupted one's marker can lie.
    """
    tool_id = str(payload.get("tool_use_id") or "").replace("/", "_")
    if not tool_id:
        return None
    args = payload.get("tool_input")
    ms = args.get("timeout") if isinstance(args, dict) else None
    if not isinstance(ms, (int, float)) or isinstance(ms, bool) or ms <= 0:
        ms = DEFAULT_TOOL_MS
    minutes = max(1, min(MAX_TOOL_MIN, math.ceil(ms / 60_000)))
    return os.path.join(base, "tools", f"{tool_id}.{minutes}")


def _rm_tool(base: str, payload: dict[str, object]) -> None:
    """By glob, not by rebuilding the name: the closing event need not report the same timeout
    as the opening one, and a marker left behind holds the machine awake for its budget."""
    tool_id = str(payload.get("tool_use_id") or "").replace("/", "_")
    if tool_id:
        for path in glob.glob(os.path.join(base, "tools", glob.escape(tool_id) + ".*")):
            _rm(path)


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
    marker = os.path.join(agents, str(agent_id).replace("/", "_"))

    # A subagent's own tool calls carry agent_id and share the parent's session_id. They must
    # not touch the parent's turn/wait markers — the agents/ files already cover them, and a
    # subagent's PostToolUse would otherwise clear a `wait` the user is still sitting on. They
    # do keep their own marker warm, which is what stops a long-running one being read as dead.
    if agent_id and event not in ("SubagentStart", "SubagentStop"):
        _beat(marker)
        return

    # Same for the turn: every main-agent event is the evidence the host needs to keep trusting
    # a marker that an interrupt would otherwise leave behind for good.
    turn = os.path.join(base, "turn")
    _beat(turn)

    if event == "SessionStart":
        _touch(os.path.join(base, "live"))
    elif event == "UserPromptSubmit":
        _touch(turn)
        _rm(os.path.join(base, "wait"))  # a new prompt means the previous wait was answered
    elif event in ("Stop", "StopFailure"):
        # StopFailure too: a turn that died on an API error never sees Stop, and without this
        # the turn marker would pin the machine awake until the staleness backstop fired.
        _rm(turn)
        _rm(os.path.join(base, "wait"))
    elif event == "SubagentStart":
        if agent_id:
            _touch(marker)
    elif event == "SubagentStop":
        if agent_id:
            _rm(marker)
    elif event in ("PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionDenied"):
        # Every tool, so a call that runs silently for minutes says so — that marker is what
        # lets the turn's own window be short enough to matter after an interrupt.
        # AskUserQuestion is an ordinary tool call in flight — Claude is "waiting on a tool
        # result", so no Notification or Elicitation event fires for it (anthropics/claude-code
        # #59908, #44326). PreToolUse is the only edge that brackets the wait; matched here now
        # that the settings matcher has to let every tool through. Clearing is unmatched: a
        # permission prompt granted mid-turn is cleared by ITS tool completing.
        tool = _tool_marker(base, payload)
        if event != "PreToolUse":
            _rm(os.path.join(base, "wait"))
            _rm_tool(base, payload)
        elif str(payload.get("tool_name", "")) in BLOCKING_TOOLS:
            # No work marker for these two: they are Claude waiting on a human, and a marker
            # would hold the machine awake for its budget with nobody working.
            _touch(os.path.join(base, "wait"))
        elif tool:
            _touch(tool)
    elif event in ("PermissionRequest", "Notification"):
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
