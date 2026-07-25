"""Assemble one project's slice of the canonical `~/.claude`, and merge it back out.

`kib` keeps `~/.claude` and `~/.claude.json` canonical and stock-untouched — the same login,
transcripts and history a plain host `claude` sees. Isolation comes from assembling each
container's config from that store at launch and merging this project's changes back on exit,
never from restructuring the originals. This module is the JSON/JSONL surgery for that seam:

    scope-in-json  <src .claude.json> <project-path> <dst>
        Globals + ONLY this project's `projects[path]` entry (+ its githubRepoPaths).

    merge-out-json <scratch .claude.json> <project-path> <canonical .claude.json>
        Read-modify-write ONLY the `projects[path]` subtree back, leaving every global key
        and every other project untouched. Fail-closed: an unparseable file writes nothing.

    seed-history   <src history.jsonl> <project-path> <dst>
        Filter canonical prompt history to this project's lines (↑ shows only this project).

    merge-history  <scratch history.jsonl> <project-path> <canonical history.jsonl>
        Append this project's NEW lines back, so a concurrent host `claude` append is safe.

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


def scope_in_json(src: str, path: str, dst: str) -> int:
    """Globals + this project's entry only → dst (a fresh session .claude.json)."""
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
    out["projects"] = {path: entry} if entry is not None else {}

    grp_all = cfg.get("githubRepoPaths") or {}
    if isinstance(grp_all, dict):
        grp = {
            repo: [p for p in paths if p == path]
            for repo, paths in grp_all.items()
            if isinstance(paths, list)
        }
        grp = {repo: paths for repo, paths in grp.items() if paths}
        if grp:
            out["githubRepoPaths"] = grp
    jsonio.write_atomic(dst, out)
    return cli.OK


def merge_out_json(scratch: str, path: str, canonical: str) -> int:
    """Write ONLY projects[path] from scratch back into canonical; globals untouched."""
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
    entry = sc_projects.get(path) if isinstance(sc_projects, dict) else None
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


def seed_history(src: str, path: str, dst: str) -> int:
    """Filter canonical history.jsonl to this project's lines → dst."""
    lines: list[str] = []
    if os.path.isfile(src):
        with open(src, errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if line and _project_of(line) == path:
                    lines.append(line)
    os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
    with open(dst, "w") as fh:
        if lines:
            fh.write("\n".join(lines) + "\n")
    return cli.OK


def merge_history(scratch: str, path: str, canonical: str) -> int:
    """Append this project's NEW lines from scratch back to canonical (append-only)."""
    if not os.path.isfile(scratch):
        return cli.OK
    with open(scratch, errors="replace") as fh:
        session_lines = [ln.strip() for ln in fh if ln.strip() and _project_of(ln.strip()) == path]
    if not session_lines:
        return cli.OK

    existing: set[str] = set()
    if os.path.isfile(canonical):
        with open(canonical, errors="replace") as fh:
            existing = {ln.strip() for ln in fh if ln.strip()}
    new = [ln for ln in session_lines if ln not in existing]
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
    "scope-in-json": (scope_in_json, 3),
    "merge-out-json": (merge_out_json, 3),
    "seed-history": (seed_history, 3),
    "merge-history": (merge_history, 3),
    "classify": (classify, 1),
}


def main(argv: list[str]) -> int:
    return cli.dispatch("kib.host.config_scope", TABLE, argv)


if __name__ == "__main__":
    cli.run(main)
