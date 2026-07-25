#!/usr/bin/env python3
"""claude-config-scope.py — assemble one project's slice of the canonical ~/.claude.

`cc` keeps the host ~/.claude and ~/.claude.json *canonical and stock-untouched*: the
same login, transcripts and history a plain host `claude` sees. Per-project isolation is
achieved by assembling each container's config from that canonical store at launch, and
merging this project's changes back out on exit — never by restructuring the originals.

This helper is the JSON/JSONL surgery for that seam (kept in python, not bash, so the
manifest and the read-modify-write stay portable — no `declare -A`, no bash-3.2 traps):

  scope-in-json  <src .claude.json> <project-path> <dst>
      Write globals + ONLY this project's `projects[path]` entry (+ its githubRepoPaths)
      into a fresh session .claude.json. No other project is visible in the box.

  merge-out-json <scratch .claude.json> <project-path> <canonical .claude.json>
      Read-modify-write ONLY the `projects[path]` subtree back into canonical, leaving
      every global key and every other project's entry untouched. Atomic. Fail-closed:
      an unparseable scratch or canonical file writes nothing.

  seed-history   <src history.jsonl> <project-path> <dst>
      Filter canonical prompt history to this project's lines (↑ shows only this project).

  merge-history  <scratch history.jsonl> <project-path> <canonical history.jsonl>
      Append this project's NEW lines back to canonical (append-only; other projects'
      lines are never rewritten, so a concurrent host `claude` append can't be lost).

  classify       <~/.claude>
      Print top-level entries NOT in the versioned manifest below — the input to cc's
      silent-log drift canary. Everything unrecognised is treated as container-private by
      cc anyway (fail-closed), so this only surfaces "Claude Code grew a new store".

All writes are atomic (temp + os.replace) or append-only; the caller serialises canonical
writes under a flock on ~/.claude.json.lock.
"""

import json
import os
import sys
import tempfile
from collections.abc import Callable
from typing import Any

# ── Manifest (versioned) ────────────────────────────────────────────────────
# Every top-level entry cc knows how to place. Bump MANIFEST_VERSION when Claude Code
# adds a store and this list is updated, so the drift canary's log line can say so.
# cc's actual bind allowlist is a small fixed list in bash; this manifest exists ONLY to
# answer "is this entry known?" for the canary — an unknown entry is safe (private) but
# worth a log line.
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
    ".claude.json",
    ".claude.json.backup",
    ".claude.json.lock",
}
KNOWN = KNOWN_SHARED | KNOWN_PROJECT | KNOWN_PRIVATE

GLOBAL_ONLY_DROP = ("projects", "githubRepoPaths")

# Globals cc pins into every session config (see pin_global_config). They are a sandbox
# behaviour, not the user's choice, so they must never ride out into canonical — including on
# the one path that seeds a fresh canonical from the session's globals (merge_out_json below).
CC_PINNED_GLOBALS = ("leftArrowOpensAgents",)


# ── helpers ─────────────────────────────────────────────────────────────────
def _load_json(path: str) -> tuple[Any, str]:
    """Return (obj, status): status 'ok' | 'absent' | 'bad'."""
    if not os.path.exists(path):
        return None, "absent"
    try:
        with open(path) as fh:
            return json.load(fh), "ok"
    except (OSError, ValueError):
        return None, "bad"


def _atomic_write_json(path: str, obj: Any) -> None:
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".ccscope.")
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(obj, fh, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _globals_only(cfg: dict[str, Any]) -> dict[str, Any]:
    """Every key except the project-scoped ones."""
    return {k: v for k, v in cfg.items() if k not in GLOBAL_ONLY_DROP}


# ── subcommands ─────────────────────────────────────────────────────────────
def scope_in_json(src: str, path: str, dst: str) -> int:
    """globals + this project's entry only → dst (a fresh session .claude.json)."""
    cfg, status = _load_json(src)
    if status == "bad":
        # A corrupt canonical file must not abort the launch; start the box from an empty
        # global config (Claude repopulates onboarding flags). Warn on stderr.
        sys.stderr.write(
            "cc-scope: canonical .claude.json is unparseable — seeding an empty session config.\n"
        )
        cfg = {}
    elif status == "absent":
        cfg = {}
    if not isinstance(cfg, dict):
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
    _atomic_write_json(dst, out)
    return 0


def merge_out_json(scratch: str, path: str, canonical: str) -> int:
    """Write ONLY projects[path] from scratch back into canonical; globals untouched."""
    sc, sc_status = _load_json(scratch)
    if sc_status != "ok" or not isinstance(sc, dict):
        # Fail-closed: never touch canonical from an unreadable scratch.
        sys.stderr.write(
            "cc-scope: session .claude.json unreadable — "
            "not merging back (canonical left untouched).\n"
        )
        return 2

    base, base_status = _load_json(canonical)
    if base_status == "bad":
        sys.stderr.write(
            "cc-scope: canonical .claude.json unparseable — refusing to overwrite it.\n"
        )
        return 3
    if base_status == "absent" or not isinstance(base, dict):
        # No canonical yet (fresh skeleton): rebuild it from this session's globals, minus the
        # pins cc forces into every box.
        base = _globals_only(sc)
        for k in CC_PINNED_GLOBALS:
            base.pop(k, None)

    projects = base.get("projects")
    if not isinstance(projects, dict):
        projects = {}
    sc_projects = sc.get("projects") or {}
    entry = sc_projects.get(path) if isinstance(sc_projects, dict) else None
    # Write-if-present, never delete. "No entry in the session config" is indistinguishable from
    # "the session config was reset/re-created" (a failed scope-in, a corrupt file Claude
    # rewrote from scratch, a run that never started Claude) — and deleting canonical's entry
    # there would silently drop the project's approved tools, MCP servers and trust flags.
    # Fail-closed matches the rest of this module: a merge loses at most this session's edit.
    if entry is not None:
        projects[path] = entry
    base["projects"] = projects
    _atomic_write_json(canonical, base)
    return 0


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
    d = os.path.dirname(dst) or "."
    os.makedirs(d, exist_ok=True)
    with open(dst, "w") as fh:
        if lines:
            fh.write("\n".join(lines) + "\n")
    return 0


def merge_history(scratch: str, path: str, canonical: str) -> int:
    """Append this project's NEW lines from scratch back to canonical (append-only)."""
    if not os.path.isfile(scratch):
        return 0
    with open(scratch, errors="replace") as fh:
        session_lines = [ln.strip() for ln in fh if ln.strip() and _project_of(ln.strip()) == path]
    if not session_lines:
        return 0

    existing: set[str] = set()
    if os.path.isfile(canonical):
        with open(canonical, errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if line:
                    existing.add(line)
    new = [ln for ln in session_lines if ln not in existing]
    if not new:
        return 0
    d = os.path.dirname(canonical) or "."
    os.makedirs(d, exist_ok=True)
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
    return 0


def classify(claude_home: str) -> int:
    """Print top-level entries NOT in the manifest (one per line). Empty = no drift."""
    if not os.path.isdir(claude_home):
        return 0
    for name in sorted(os.listdir(claude_home)):
        if name not in KNOWN:
            print(name)
    return 0


# ── dispatch ────────────────────────────────────────────────────────────────
def main(argv: list[str]) -> int:
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    cmd, rest = argv[1], argv[2:]
    # Heterogeneous arity, so the callables are `...`; `argc` is what enforces it.
    table: dict[str, tuple[Callable[..., int], int]] = {
        "scope-in-json": (scope_in_json, 3),
        "merge-out-json": (merge_out_json, 3),
        "seed-history": (seed_history, 3),
        "merge-history": (merge_history, 3),
        "classify": (classify, 1),
    }
    if cmd not in table:
        sys.stderr.write(f"cc-scope: unknown subcommand {cmd!r}\n")
        return 2
    fn, argc = table[cmd]
    if len(rest) != argc:
        sys.stderr.write(f"cc-scope: {cmd} needs {argc} argument(s)\n")
        return 2
    return fn(*rest)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
