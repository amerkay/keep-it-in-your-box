"""Assemble one project's slice of the canonical `~/.claude`, and merge it back out.

`kib` keeps `~/.claude` and `~/.claude.json` canonical and stock-untouched — the same login,
transcripts and history a plain host `claude` sees. Isolation comes from assembling each
container's config from that store at launch and merging this project's changes back on exit,
never from restructuring the originals. This module is the JSON/JSONL surgery for that seam:

Every verb takes the project's HOST path and its BOX path. They differ for any project under
$HOME, where Claude's resolved cwd inside the box is not the host's (see "Host key vs box key"
below). Canonical is always keyed by the host path; the session by the box path.

    scope-in-json  <src .claude.json> <project-path> <dst> <box-path>
        Globals + ONLY this project's `projects[path]` entry (+ its githubRepoPaths),
        re-keyed to <box-path>.

    merge-out-json <scratch .claude.json> <project-path> <canonical .claude.json> <box-path>
        Read-modify-write ONLY the `projects[box]` subtree back into `projects[path]`, leaving
        every global key and every other project untouched. Fail-closed: an unparseable file
        writes nothing.

    seed-history   <src history.jsonl> <project-path> <dst> <box-path>
        Filter canonical prompt history to this project's lines (↑ shows only this project),
        re-keyed to <box-path>.

    merge-history  <scratch history.jsonl> <project-path> <canonical history.jsonl> <box-path>
        Append this project's NEW lines back under the host key, so a concurrent host `claude`
        append is safe.

    classify       <~/.claude>
        Print top-level entries NOT in the versioned manifest below — the drift canary.

All writes are atomic or append-only; the caller serialises canonical writes under a flock
on `~/.claude.json.lock`.
"""

from __future__ import annotations

import json
import os
import sys
from typing import Any

from kib.shared import cli, jsonio

# ── Manifest (versioned) ────────────────────────────────────────────────────
# Every top-level entry kib knows how to place. Bump MANIFEST_VERSION when Claude Code adds
# a store and this list is updated, so the drift canary's log line can say so. The actual
# bind allowlist is a small fixed list in bash; this manifest exists ONLY to answer "is this
# entry known?" — an unknown entry is safe (container-private) but worth a log line.
MANIFEST_VERSION = 1

# Shared/global — same for every project (bound from canonical, rw or ro).
KNOWN_SHARED = {
    ".credentials.json",
    "settings.json",
    "keybindings.json",
    "CLAUDE.md",
    "plugins",
    "skills",
    "agents",
    "commands",
    "hooks",
}
# Per-project — naturally keyed; this project's slice is bound/scoped in.
KNOWN_PROJECT = {"projects", "history.jsonl"}
# Machine-runtime singletons + caches — always container-private, never shared with host.
KNOWN_PRIVATE = {
    "daemon",
    "daemon.lock",
    "daemon.log",
    "daemon.status.json",
    "sessions",
    "session-env",
    "tasks",
    "jobs",
    "todos",
    "file-history",
    "shell-snapshots",
    "statsig",
    "cache",
    "stats-cache.json",
    "mcp-needs-auth-cache.json",
    "paste-cache",
    "debug",
    "backups",
    "downloads",
    "plans",
    "ide",
    ".last-cleanup",
    ".sleep-inhibit",
    ".DS_Store",  # Finder writes it into every macOS directory; a permanent canary otherwise
    ".claude.json",
    ".claude.json.backup",
    ".claude.json.lock",
}
KNOWN = KNOWN_SHARED | KNOWN_PROJECT | KNOWN_PRIVATE

GLOBAL_ONLY_DROP = ("projects", "githubRepoPaths")

# Globals kib pins into every session config (see kib.host.pins). They are a sandbox
# behaviour, not the user's choice, so they must never ride out into canonical — including
# on the one path that seeds a fresh canonical from the session's globals.
PINNED_GLOBALS = ("leftArrowOpensAgents",)


def _globals_only(cfg: dict[str, Any]) -> dict[str, Any]:
    """Every key except the project-scoped ones."""
    return {k: v for k, v in cfg.items() if k not in GLOBAL_ONLY_DROP}


# ── Host key vs box key ─────────────────────────────────────────────────────
# Claude keys projects/, .claude.json and history.jsonl by its RESOLVED cwd. There is no $PWD
# bind: the redacted view is mounted at $PWD, and $HOST_HOME is a symlink to the container
# home, so the kernel resolves the cwd to /home/hostuser/<project> and Claude keys everything
# by THAT. Left alone, the box wrote a second set of entries under the container path — the
# host's `--resume` and ↑ history could not see the box's sessions, and the box could not see
# the host's, which is the seamless switch these functions exist to preserve. So: translate on
# the way in, translate back on the way out. Canonical only ever holds the host key.
#
# `box` still defaults to `path`: a project OUTSIDE $HOME resolves to itself in the box, and
# the unit tests exercise both spellings.


def _canon_line(line: str) -> str:
    """Serialisation-independent identity for a history line (see merge_history)."""
    try:
        obj = json.loads(line)
    except (ValueError, TypeError):
        return line
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


def _rekey_history(line: str, frm: str, to: str) -> str:
    """Rewrite a history line's `project` field, byte-preserving when there is nothing to do."""
    if frm == to:
        return line
    try:
        obj = json.loads(line)
    except (ValueError, TypeError):
        return line
    if not isinstance(obj, dict) or obj.get("project") != frm:
        return line
    obj["project"] = to
    return json.dumps(obj)


def scope_in_json(src: str, path: str, dst: str, box: str = "") -> int:
    """Globals + this project's entry only → dst (a fresh session .claude.json).

    `path` is canonical's key (the host path); `box` is the key Claude will use inside the
    container. Equal for a project outside $HOME.
    """
    box = box or path  # no translation needed
    cfg, status = jsonio.load(src)
    if status == "bad":
        # A corrupt canonical file must not abort the launch; start the box from an empty
        # global config (Claude repopulates onboarding flags). Warn on stderr.
        sys.stderr.write(
            "kib: canonical .claude.json is unparseable — seeding an empty session config.\n"
        )
        cfg = {}
    elif status == "absent" or not isinstance(cfg, dict):
        cfg = {}

    out = _globals_only(cfg)
    projects = cfg.get("projects") or {}
    entry = projects.get(path) if isinstance(projects, dict) else None
    out["projects"] = {box: entry} if entry is not None else {}

    grp_all = cfg.get("githubRepoPaths") or {}
    if isinstance(grp_all, dict):
        grp = {
            repo: ([box] if path in paths else [])
            for repo, paths in grp_all.items()
            if isinstance(paths, list)
        }
        grp = {repo: paths for repo, paths in grp.items() if paths}
        if grp:
            out["githubRepoPaths"] = grp
    jsonio.write_atomic(dst, out)
    return cli.OK


def merge_out_json(scratch: str, path: str, canonical: str, box: str = "") -> int:
    """Write ONLY projects[box] from scratch back into canonical's projects[path]."""
    box = box or path  # no translation needed
    sc, sc_status = jsonio.load(scratch)
    if sc_status != "ok" or not isinstance(sc, dict):
        # Fail-closed: never touch canonical from an unreadable scratch.
        sys.stderr.write(
            "kib: session .claude.json unreadable — not merging back (canonical untouched).\n"
        )
        return cli.MALFORMED

    base, base_status = jsonio.load(canonical)
    if base_status == "bad":
        sys.stderr.write("kib: canonical .claude.json unparseable — refusing to overwrite it.\n")
        return cli.UNREADABLE
    if base_status == "absent" or not isinstance(base, dict):
        # No canonical yet (fresh skeleton): rebuild it from this session's globals, minus
        # the pins kib forces into every box.
        base = _globals_only(sc)
        for k in PINNED_GLOBALS:
            base.pop(k, None)
    projects = base.get("projects")
    if not isinstance(projects, dict):
        projects = {}
    sc_projects = sc.get("projects") or {}
    entry = sc_projects.get(box) if isinstance(sc_projects, dict) else None
    # Write-if-present, never delete. "No entry in the session config" is indistinguishable
    # from "the session config was reset/re-created" (a failed scope-in, a corrupt file
    # Claude rewrote from scratch, a run that never started Claude) — and deleting
    # canonical's entry there would silently drop the project's approved tools, MCP servers
    # and trust flags. A merge loses at most this session's edit.
    if entry is not None:
        projects[path] = entry
    base["projects"] = projects
    jsonio.write_atomic(canonical, base)
    return cli.OK


def _project_of(line: str) -> Any:
    try:
        obj = json.loads(line)
    except (ValueError, TypeError):
        return None
    return obj.get("project") if isinstance(obj, dict) else None


def seed_history(src: str, path: str, dst: str, box: str = "") -> int:
    """Filter canonical history.jsonl to this project's lines → dst, re-keyed to the box."""
    box = box or path  # no translation needed
    lines: list[str] = []
    if os.path.isfile(src):
        with open(src, errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if line and _project_of(line) == path:
                    lines.append(_rekey_history(line, path, box))
    os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
    with open(dst, "w") as fh:
        if lines:
            fh.write("\n".join(lines) + "\n")
    return cli.OK


def merge_history(scratch: str, path: str, canonical: str, box: str = "") -> int:
    """Append this project's NEW lines from scratch back to canonical (append-only).

    The session wrote them under the box key; canonical only ever holds the host key.
    """
    box = box or path  # no translation needed
    if not os.path.isfile(scratch):
        return cli.OK
    with open(scratch, errors="replace") as fh:
        session_lines = [
            _rekey_history(ln.strip(), box, path)
            for ln in fh
            if ln.strip() and _project_of(ln.strip()) == box
        ]
    if not session_lines:
        return cli.OK

    # Compare PARSED, not raw. Claude writes these lines with JS `JSON.stringify` (no space
    # after a separator); re-keying one round-trips it through Python's dumps, which does not
    # produce the same bytes. A raw compare then matched nothing and every launch re-appended
    # the whole seeded history. Unparseable lines fall back to their own text.
    existing: set[str] = set()
    if os.path.isfile(canonical):
        with open(canonical, errors="replace") as fh:
            existing = {_canon_line(ln.strip()) for ln in fh if ln.strip()}
    new = [ln for ln in session_lines if _canon_line(ln) not in existing]
    if not new:
        return cli.OK
    os.makedirs(os.path.dirname(canonical) or ".", exist_ok=True)
    # A canonical file whose last line has no trailing newline (a host `claude` killed
    # mid-append) would otherwise be glued to our first line, corrupting both.
    need_nl = False
    if os.path.isfile(canonical) and os.path.getsize(canonical):
        with open(canonical, "rb") as probe:
            probe.seek(-1, os.SEEK_END)
            need_nl = probe.read(1) != b"\n"
    with open(canonical, "a") as fh:
        if need_nl:
            fh.write("\n")
        fh.write("\n".join(new) + "\n")
    return cli.OK


def classify(claude_home: str) -> int:
    """Print top-level entries NOT in the manifest (one per line). Empty = no drift."""
    if not os.path.isdir(claude_home):
        return cli.OK
    for name in sorted(os.listdir(claude_home)):
        if name not in KNOWN:
            print(name)
    return cli.OK


TABLE: dict[str, tuple[cli.Command, int]] = {
    "scope-in-json": (scope_in_json, 4),
    "merge-out-json": (merge_out_json, 4),
    "seed-history": (seed_history, 4),
    "merge-history": (merge_history, 4),
    "classify": (classify, 1),
}


def main(argv: list[str]) -> int:
    return cli.dispatch("kib.host.config_scope", TABLE, argv)


if __name__ == "__main__":
    cli.run(main)
