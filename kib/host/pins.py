"""Re-assert the global-config keys the sandbox forces, in this session's `.claude.json`.

These live in Claude's GLOBAL config, not settings.json. That file is reassembled per-project
on each cold start and Claude may rewrite it wholesale mid-session, so the pins are re-applied
every launch. They stay in-box — merge-out pushes back only the `projects[path]` subtree.

`leftArrowOpensAgents=false`: from a foreground session `←` means "background this session",
not "go back". With a turn in flight it aborts the running Workflow and every subagent before
forking, and that work is structurally non-carryable, so it is lost. Each press also mints a
session id, littering the resume list with title-only stubs.

Writes only when a pin is missing or wrong, so the common attach path touches nothing: a
concurrent session holds this file in memory and rewrites it wholesale, and losing a pin
(re-applied next cold start) beats clobbering that session's state.
"""

from __future__ import annotations

import sys

from kib.shared import cli, jsonio

PINS: dict[str, object] = {"leftArrowOpensAgents": False}


def apply(path: str) -> int:
    cfg, status = jsonio.load(path)
    if status != "ok" or not isinstance(cfg, dict):
        return cli.FAIL  # unreadable or not JSON: leave it well alone
    if all(cfg.get(k) == v for k, v in PINS.items()):
        return cli.OK  # already pinned — no write, no clobber window
    cfg.update(PINS)
    jsonio.write_atomic(path, cfg)
    sys.stderr.write(f"🔧 kib: pinned {', '.join(PINS)} in .claude.json\n")
    return cli.OK


def main(argv: list[str]) -> int:
    return cli.dispatch("kib.host.pins", {"apply": (apply, 1)}, argv)


if __name__ == "__main__":
    cli.run(main)
