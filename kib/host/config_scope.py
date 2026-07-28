"""Assemble one project's slice of the canonical `~/.claude`, and merge it back out.

`kib` keeps `~/.claude` and `~/.claude.json` canonical and stock-untouched — the same login,
transcripts and history a plain host `claude` sees. Isolation comes from assembling each
container's config from that store at launch and merging this project's changes back on exit,
never from restructuring the originals. This module is the JSON/JSONL surgery for that seam:

Every verb takes ONE project path. The sidecar binds the view at the project's own host
path, so Claude's resolved cwd inside the box is the host's and canonical and the session
share a key — there is nothing to translate (see "One key" below).

    scope-in-json  <src .claude.json> <project-path> <dst>
        Globals + ONLY this project's `projects[path]` entry (+ its githubRepoPaths).

    merge-out-json <scratch .claude.json> <project-path> <canonical .claude.json>
        Read-modify-write ONLY the `projects[path]` subtree back into canonical, leaving
        every global key and every other project untouched, and only after the subtree passes
        `vet_project_entry`. Fail-closed: an unparseable file writes nothing.

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

from kib.host.pins import PINS
from kib.shared import cli, jsonio

# ── Manifest ────────────────────────────────────────────────────────────────
# Every top-level entry kib knows how to place. The actual bind allowlist is a small fixed
# list in bash; this manifest exists ONLY to answer "is this entry known?" — an unknown entry
# is safe (container-private) but worth a log line.

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

# Globals kib pins into every session config. They are a sandbox behaviour, not the user's
# choice, so they must never ride out into canonical — including on the one path that seeds a
# fresh canonical from the session's globals. Derived from kib.host.pins rather than retyped:
# a pin added there but missed here would be seeded into the user's live host config.
PINNED_GLOBALS = tuple(PINS)


def _globals_only(cfg: dict[str, Any]) -> dict[str, Any]:
    """Every key except the project-scoped ones."""
    return {k: v for k, v in cfg.items() if k not in GLOBAL_ONLY_DROP}


# ── The merge-out vet ───────────────────────────────────────────────────────
# `projects[path]` carries approved tools, MCP servers and trust flags, and a HOST `claude`
# reads it unsandboxed. `.claude.json` is box-writable (it is what `claude mcp add` writes) and
# lives OUTSIDE the FUSE-guarded project tree, so nothing else vets it — settings.json gets
# exactly this treatment on its way back (`merge_out_shared_settings`), and the asymmetry was
# the finding. Reduce, never refuse: a whole-entry rejection would drop the session's ordinary
# state (history, mode, onboarding) along with the payload.

#: Flags that widen what the next session may do without being asked. A session may lower one,
#: never raise it. Prefix-matched as well, so a future `hasTrustDialog*` sibling is covered the
#: day Claude adds it rather than the day someone notices.
TRUST_FLAGS = ("enableAllProjectMcpServers",)
TRUST_FLAG_PREFIX = "hasTrustDialog"

#: Exempt from the guard by the user's decision (2026-07-28): the box reassembles its config from
#: canonical every cold start, so a folder trusted only inside kib re-prompted and re-raised this
#: flag every launch — the refusal warned at every teardown and could never converge. Cost
#: accepted: a session can now pre-trust the folder for the next HOST claude, and
#: `.claude/settings.json` is box-writable, so that chain is DETECTED (`audit_project_configs`)
#: rather than refused. Siblings Claude adds later stay guarded by the prefix.
TRUST_FLAGS_EXEMPT = ("hasTrustDialogAccepted",)

#: List-valued keys that name what the next session may run without asking, clamped to what
#: canonical already held. `enabledMcpjsonServers` belongs with them, not with the booleans:
#: `.mcp.json` is writable from the box (mixed-use, watched), so approving a name here is how a
#: session hands a host `claude` a server whose `command` mcpServers-vetting never sees.
#: `disabledMcpjsonServers` is deliberately absent — adding to it only ever removes reach.
CLAMPED_LISTS = ("allowedTools", "enabledMcpjsonServers")


def _is_trust_flag(key: str) -> bool:
    if key in TRUST_FLAGS_EXEMPT:
        return False
    return key in TRUST_FLAGS or key.startswith(TRUST_FLAG_PREFIX)


def vet_project_entry(entry: Any, prior: Any) -> tuple[Any, list[str]]:
    """`projects[path]` reduced to what a sandboxed session may hand a host `claude`.

    Returns `(entry, notes)`; `notes` names everything dropped, for the user's teardown
    warning. Judged against `prior` (canonical's current entry) rather than absolutely, like
    the git-config validator: the user's own host-side MCP servers and trust flags round-trip
    through the box untouched, and only what this session ADDED is refused.
    """
    if not isinstance(entry, dict):
        return entry, []
    prior = prior if isinstance(prior, dict) else {}
    out = dict(entry)
    notes: list[str] = []

    servers = out.get("mcpServers")
    if isinstance(servers, dict):
        was = prior.get("mcpServers")
        was = was if isinstance(was, dict) else {}
        kept = {}
        for name, spec in servers.items():
            cmd = spec.get("command") if isinstance(spec, dict) else None
            if cmd and spec != was.get(name):
                notes.append(f"mcpServers.{name}.command = {cmd}")
                # Revert, never delete: the session may have EDITED a server the user set up
                # host-side, and refusing that edit must leave canonical's own entry standing —
                # dropping it would silently destroy the user's real config on exit.
                if name in was:
                    kept[name] = was[name]
                continue
            kept[name] = spec
        # Never invent a key canonical did not have: if everything the session listed was
        # refused and there was no entry before, the merge must leave no trace at all.
        if kept or "mcpServers" in prior:
            out["mcpServers"] = kept
        else:
            del out["mcpServers"]

    for key, value in list(out.items()):
        if key in CLAMPED_LISTS and isinstance(value, list):
            old = prior.get(key)
            old = old if isinstance(old, list) else []
            added = [t for t in value if t not in old]
            if added:
                notes.append(f"{key} += {added}")
                if key in prior:
                    out[key] = old
                else:
                    del out[key]
        elif _is_trust_flag(key) and value and not prior.get(key):
            notes.append(f"{key} = {value}")
            if key in prior:
                out[key] = prior[key]
            else:
                del out[key]
    return out, notes


# ── One key ─────────────────────────────────────────────────────────────────
# Claude keys projects/, .claude.json and history.jsonl by its RESOLVED cwd, and the FUSE
# sidecar binds the project at its own HOST path — so that cwd is the host path and canonical
# and the session key everything identically. These verbs therefore take one path, not two.
#
# It was two. While the box mounted the project at /home/hostuser/<project>, every verb
# re-keyed on the way in and back on the way out, or the host's `--resume` and ↑ history
# could not see the box's sessions. The sidecar restore removed the mismatch itself, which is
# what made the translation deletable: remove the mismatch, never translate it.


def _canon_line(line: str) -> str:
    """Serialisation-independent identity for a history line (see merge_history)."""
    try:
        obj = json.loads(line)
    except (ValueError, TypeError):
        return line
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


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
            repo: ([path] if path in paths else [])
            for repo, paths in grp_all.items()
            if isinstance(paths, list)
        }
        grp = {repo: paths for repo, paths in grp.items() if paths}
        if grp:
            out["githubRepoPaths"] = grp
    jsonio.write_atomic(dst, out)
    return cli.OK


def merge_out_json(scratch: str, path: str, canonical: str) -> int:
    """Write ONLY projects[path] from scratch back into canonical."""
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
        entry, notes = vet_project_entry(entry, projects.get(path))
        if notes:
            sys.stderr.write(
                "kib: this session's .claude.json asked to give the next HOST claude more than\n"
                "     it had in this project — NOT merged back:\n"
                + "".join(f"       {n}\n" for n in notes)
            )
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
