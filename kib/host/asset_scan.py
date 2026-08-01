"""Scan a shared `~/.claude` asset tree (skills|agents|commands|plugins|hooks) for what a HOST
`claude` would AUTO-run, and for symlinks pointing out of the tree.

All five trees mount writable and shared with every project, so a session can write any of them.
That is deliberate: an install or an authored skill should be shared exactly as it is on the host,
and the lock that used to sit on `plugins/` + `hooks/` cost a mount-mode flag, a lock witness, an
attach refusal and a per-project symlink farm to buy a control this replaces. So there is nothing
to prevent here — only to REPORT, before the next reader loads it.

The line is **auto-execution, not executability**. A `hooks` / `mcpServers` / `lspServers` /
`monitors` block's `command` runs with no one deciding to run it. A bundled script is different:
it runs only if the agent reads the skill and chooses to, and a skill that is pure prose saying
"now run this installer" is just as dangerous and cannot be detected at all. Refusing the exec bit
would therefore buy almost nothing while breaking ordinary skills — most non-trivial ones ship a
helper script. So scripts pass, `command` does not.

A symlink out of the tree is the other half, and it is a READ primitive rather than an exec one:
these trees are host-backed and NOT behind the redaction FUSE, so `skills/x/SKILL.md ->
~/.ssh/id_rsa` persists to host state, auto-loads into every future session and into the host's
own unsandboxed `claude` — and the loader follows it and ingests the target. Content the box
cannot read itself, delivered by the host. (audit MAC-M1)

Three limits worth knowing:

* **JSON only.** Hooks may also be declared in a skill's or agent's YAML *frontmatter*, and the
  host has no YAML parser in the 3.9 stdlib. An accepted gap, like the prose one above.
* **One hop.** A `plugin.json` may point `hooks`/`mcpServers`/`lspServers`/`experimental.monitors`
  at another path; that path is resolved and read, but what IT names is not. A manifest must not
  be able to walk the scanner around the filesystem, and a pointer landing outside the tree is
  reported by name and never opened.
* **Detection, at teardown.** These trees are plain bind mounts with no layer to interpose on.

`scan` walks everything; `scan-new` reports only entries modified since a stamp file, which is
what the launch path uses — the plugin cache is 100k+ entries, and an unscoped scan would report
every legitimately installed plugin on every exit, which is an alarm that is always on. A missing
stamp means "no reference": scan everything.

Prints one `path — finding` line per finding. Exit: 0 clean · 1 findings · 4 unreadable (fail
closed: a file we cannot check must not pass into every project's next session).
"""

from __future__ import annotations

import json
import os
from collections.abc import Callable, Iterator
from typing import Any

from kib.shared import cli, dangerous

#: Deep enough for a plugin's own manifest under the installer's layout —
#: `plugins/cache/<marketplace>/<plugin>/<version>/.claude-plugin/plugin.json` — plus a couple of
#: levels of a skill's `references/`. Bounded so a pathological tree cannot make the walk
#: unbounded work. A silent truncation in a security scanner is worse than no scanner, so the
#: bound is set past every layout kib knows rather than at the shallowest one that fits.
MAX_DEPTH = 9

#: Never descended into. `node_modules` is a plugin's vendored dependencies — thousands of
#: `package.json`s, none of them loaded by Claude. `.git` is pruned from the ordinary walk and
#: inspected directly instead (`_git_findings`), because what matters in there is two fixed paths.
PRUNE = frozenset({"node_modules", ".git"})

#: Schemas with no arming key anywhere above the command, so the disarmed walk below would never
#: fire on them: the filename is the arming signal instead. `monitors.json` is a bare JSON *array*
#: of `{name, command, …}`, and one marked `"when": "always"` starts at session start at the same
#: trust level as a hook. `hooks.json` is a plugin's hook block, which may be written bare
#: (`{"PreToolUse": […]}`) — and arming it by name is also what keeps it visible to `scan-new`
#: when the `plugin.json` pointing at it is older than the stamp and so filtered out of the walk.
ARMED_FILENAMES = frozenset({"monitors.json", "hooks.json"})

#: Manifest keys whose value may be a PATH to the real declaration instead of the declaration
#: itself. Resolved exactly one level. `experimental` carries `monitors` today; arming the wrapper
#: rather than the leaf is what keeps this working when the leaf is renamed.
POINTER_KEYS = ("hooks", "mcpServers", "lspServers", "experimental")

PLUGIN_MANIFEST = os.path.join(".claude-plugin", "plugin.json")


def inside(target_real: str, root_real: str) -> bool:
    """Is *target_real* the tree at *root_real*, or under it? Both must already be resolved."""
    return target_real == root_real or target_real.startswith(root_real + os.sep)


def _escaped_target(full: str, root_real: str) -> str | None:
    """The resolved target of *full* if it is a symlink landing outside the tree, else None.

    Judged on the fully resolved target, so a chain through an in-tree link is followed to
    where it really lands. A link that stays inside the tree is ordinary skill plumbing.
    """
    if not os.path.islink(full):
        return None
    target = os.path.realpath(full)
    return None if inside(target, root_real) else target


def _walk(root: str, newer_than: float | None) -> Iterator[tuple[str, list[str], list[str]]]:
    """`os.walk` bounded by MAX_DEPTH and PRUNE, yielding `(dirpath, dirnames, filenames)`.

    `newer_than` filters FILES by `changed_at` only — a directory is always descended into,
    because a file rewritten in place leaves its parent's timestamps untouched.
    """
    root = root.rstrip(os.sep)  # else the depth below is off by one for a trailing slash
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        if dirpath[len(root) :].count(os.sep) >= MAX_DEPTH:
            dirnames[:] = []
            continue
        dirnames[:] = [d for d in dirnames if d not in PRUNE]
        if newer_than is not None:
            filenames = [f for f in filenames if changed_at(os.path.join(dirpath, f)) > newer_than]
        yield dirpath, dirnames, filenames


def changed_at(path: str) -> float:
    """The later of mtime and ctime.

    mtime ALONE is not a change signal here: these trees are writable from a session, so the very
    thing being detected can `touch -d 2000-01-01` its payload and drop straight out of a
    `scan-new`. ctime moves on every write and no unprivileged caller can set it backwards, so the
    pair is what the stamp is compared against. (`redaction-config-guard.md`)
    """
    try:
        st = os.lstat(path)
    except OSError:
        return 0.0
    return max(st.st_mtime, st.st_ctime)


def _load_json(full: str, findings: list[str]) -> Any:
    """Parsed JSON at *full*, or None. Raises `_UnreadableError` on an I/O error — a file we cannot
    check must not pass silently into every project's next session.

    A parse failure is NOT a finding: nothing executes a file that does not parse. `RecursionError`
    is caught with the rest because `[` * 30000 is valid JSON that overflows the decoder, and a
    stray file must not be able to take the whole report down.
    """
    try:
        with open(full, encoding="utf-8", errors="replace") as fh:
            return json.load(fh)
    except (ValueError, RecursionError):
        return None
    except OSError as e:
        findings.append(f"{full} — cannot read it ({e.strerror})")
        raise _UnreadableError from e


class _UnreadableError(Exception):
    """A file that must be checked could not be read. Fails the whole scan closed."""


def _commands(cfg: Any, *, armed: bool) -> list[str]:
    return dangerous.json_commands(cfg, arm=dangerous.AUTO_RUN_KEYS, armed=armed)


def pointer_paths(manifest: Any, base: str, root_real: str) -> Iterator[tuple[str, str, bool]]:
    """Yield `(key, resolved path, is_inside)` for each of a `plugin.json`'s block pointers.

    A pointer is a path STRING where the declaration itself would otherwise be; a plugin that
    declares its hooks inline is covered by the ordinary walk instead. Resolved exactly ONE level
    — what the pointed-at file names in turn is not followed, or a manifest could walk a scanner
    around the filesystem. `is_inside` false means the caller must name it and never open it:
    following it is the read primitive this whole scan exists to refuse.

    Shared with the project-side audit (`kib.host.gitaudit`), which resolves the same pointers
    against the repository root — one definition, so the two cannot drift on what a pointer is.
    """
    if not isinstance(manifest, dict):
        return
    for key in POINTER_KEYS:
        raw = manifest.get(key)
        if isinstance(raw, dict):  # `experimental: {monitors: "path"}` — one level in
            raw = raw.get("monitors")
        if not isinstance(raw, str) or not raw.strip():
            continue
        target = os.path.realpath(os.path.join(base, raw))
        yield key, target, inside(target, root_real)


def _pointer_findings(manifest: Any, base: str, root_real: str, findings: list[str]) -> None:
    """`pointer_paths`, reported as pointer AND command together — the path alone says nothing
    about what runs, and the command alone says nothing about how it got loaded.
    """
    for key, target, ok in pointer_paths(manifest, base, root_real):
        if not ok:
            findings.append(f"{base}/{PLUGIN_MANIFEST} — {key} points out of the tree, to {target}")
            continue
        if not os.path.exists(target):
            continue  # a pointer at nothing is inert; not a file we tried and failed to check
        cfg = _load_json(target, findings)
        if cfg is None:
            continue
        # Armed: this file IS the block the manifest named, so there is no wrapper key to arm on.
        findings += [f"{target} — {key} (via plugin.json) {c}" for c in _commands(cfg, armed=True)]


def _git_findings(gitdir: str, findings: list[str]) -> None:
    """A marketplace is a git CLONE, and `.git/` is pruned from the ordinary walk — but the host
    runs `.git/config`'s command-valued keys and `.git/hooks`' scripts on any ordinary git command
    against it. Neither is JSON, so nothing else here would ever see them.
    """
    cfg = os.path.join(gitdir, "config")
    try:
        with open(cfg, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        text = ""  # no config, or unreadable: the hooks check below still runs
    for section, key, value in sorted(dangerous.git_ini_entries(text)):
        findings.append(f"{cfg} — {section}.{key} = {value}")
    hooks = os.path.join(gitdir, "hooks")
    for name in sorted(_listdir(hooks)):
        full = os.path.join(hooks, name)
        if name.endswith(".sample") or not os.path.isfile(full):
            continue
        if os.access(full, os.X_OK):
            findings.append(f"{full} — an executable git hook, run by any git command here")


def _listdir(path: str) -> list[str]:
    try:
        return os.listdir(path)
    except OSError:
        return []


def _scan(root: str, newer_than: float | None) -> int:
    findings: list[str] = []
    root = root.rstrip(os.sep)
    root_real = os.path.realpath(root)
    try:
        for dirpath, dirnames, filenames in _walk(root, newer_than):
            # Dirs as well as files: `skills/x -> ~/.ssh` shares a whole directory, and the walk
            # does not descend into it (followlinks=False), so this is its only sighting. Not
            # mtime-filtered — a link is its own act, and lstat'ing every dir every walk is the
            # cost `newer_than` exists to avoid.
            escaping = set()
            for name in dirnames + filenames:
                full = os.path.join(dirpath, name)
                target = _escaped_target(full, root_real)
                if target is not None:
                    escaping.add(name)
                    findings.append(f"{full} — a symlink out of the tree, to {target}")
            # One stat, not a listdir: this runs for EVERY directory, and the plugin cache is
            # 100k+ entries — reading each one twice is the cost the depth bound exists to avoid.
            if os.path.isdir(os.path.join(dirpath, ".git")):
                _git_findings(os.path.join(dirpath, ".git"), findings)
            for name in filenames:
                # Already a finding, and opening it would pull the out-of-tree target's contents
                # in here — the very thing this refuses to let a skill do.
                if not name.endswith(".json") or name in escaping:
                    continue
                full = os.path.join(dirpath, name)
                cfg = _load_json(full, findings)
                if cfg is None:
                    continue
                findings += [f"{full} — {c}" for c in _commands(cfg, armed=name in ARMED_FILENAMES)]
                if os.path.join(os.path.basename(dirpath), name) == PLUGIN_MANIFEST:
                    findings.append(f"{full} — a plugin manifest: it loads with no install step")
                    _pointer_findings(cfg, os.path.dirname(dirpath), root_real, findings)
    except _UnreadableError:
        print("\n".join(findings))
        return cli.UNREADABLE
    if not findings:
        return cli.OK  # print nothing: a clean tree is silent, so callers can test the output
    print("\n".join(findings))
    return cli.FAIL


def scan(root: str) -> int:
    return _scan(root, None)


def scan_new(root: str, stamp: str) -> int:
    """Only what changed since *stamp* was last touched. A missing stamp means "no reference" —
    scan everything, which is what `kib audit` wants on a machine that has never launched.
    """
    # Plain mtime for the STAMP, `changed_at` for the files it is compared against. The stamp is
    # a checkpoint kib sets itself, in host-only state no session can reach; the files are the
    # sandbox's to write, which is the asymmetry `changed_at` exists for.
    newer_than: float | None = None
    try:
        newer_than = os.stat(stamp).st_mtime
    except OSError:
        newer_than = None  # no reference point — scan everything
    return _scan(root, newer_than)


def main(argv: list[str]) -> int:
    cmds: dict[str, tuple[Callable[..., int], int]] = {"scan": (scan, 1), "scan-new": (scan_new, 2)}
    return cli.dispatch("kib.host.asset_scan", cmds, argv)


if __name__ == "__main__":
    cli.run(main)
