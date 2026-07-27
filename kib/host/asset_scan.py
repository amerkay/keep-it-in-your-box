"""Scan a shared PROMPT-asset tree (`~/.claude/skills|agents|commands`) for an AUTO-run command.

Those three trees mount writable and shared with every project because they hold prompt text.
With `plugins/` and `hooks/` locked, a skill directory is the obvious next parking spot for the
same payload — so this is the check that keeps the premise true.

The line is **auto-execution, not executability**. A `hooks` / `mcpServers` block's `command`
runs with no one deciding to run it, which is exactly why `plugins/` and `hooks/` are locked. A
bundled script is different: it runs only if the agent reads the skill and chooses to, and a
skill that is pure prose saying "now run this installer" is just as dangerous and cannot be
detected at all. Refusing the exec bit would therefore buy almost nothing while breaking
ordinary skills — most non-trivial ones ship a helper script. So scripts pass, `command` does
not.

Limit worth knowing: JSON only. Hooks and MCP servers are configured in JSON (`hooks.json`,
`.mcp.json`, `settings.json`), and the host has no YAML parser in the 3.9 stdlib.

Prints one `path — command` line per finding. Exit: 0 clean · 1 findings · 4 unreadable (fail
closed: a file we cannot check must not pass into every project's next session).
"""

from __future__ import annotations

import json
import os
from typing import Any

from kib.shared import cli

#: Deep enough for `skills/<name>/references/<file>`, bounded so a pathological tree cannot
#: turn the walk into unbounded work.
MAX_DEPTH = 6


def commands_in(obj: Any, *, armed: bool = False) -> list[str]:
    """Every `command` reachable from a `hooks` / `mcpServers` key.

    Armed-then-look, not any `command` anywhere: a skill's own docs may well mention one, and
    flagging that trains the user to ignore the warning that matters.
    """
    out: list[str] = []
    if isinstance(obj, dict):
        for key, val in obj.items():
            if armed and key == "command" and isinstance(val, str) and val.strip():
                out.append(val.strip())
            out += commands_in(val, armed=armed or key in ("hooks", "mcpServers"))
    elif isinstance(obj, list):
        for item in obj:
            out += commands_in(item, armed=armed)
    return out


def scan(root: str) -> int:
    findings: list[str] = []
    root = root.rstrip(os.sep)  # else the depth below is off by one for a trailing slash
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        if dirpath[len(root) :].count(os.sep) >= MAX_DEPTH:
            dirnames[:] = []
            continue
        for name in filenames:
            if not name.endswith(".json"):
                continue
            full = os.path.join(dirpath, name)
            try:
                with open(full, encoding="utf-8", errors="replace") as fh:
                    cfg = json.load(fh)
            except ValueError:
                continue  # not JSON despite the name — nothing executes it either
            except OSError as e:
                print(f"{full} — cannot read it ({e.strerror})")
                return cli.UNREADABLE
            findings += [f"{full} — {c}" for c in commands_in(cfg)]
    if not findings:
        return cli.OK  # print nothing: a clean tree is silent, so callers can test the output
    print("\n".join(findings))
    return cli.FAIL


def main(argv: list[str]) -> int:
    return cli.dispatch("kib.host.asset_scan", {"scan": (scan, 1)}, argv)


if __name__ == "__main__":
    cli.run(main)
