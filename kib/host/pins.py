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

SEEDS are the other half: written only when ABSENT, so they set a default the user can then
change, rather than forcing a value every launch.
"""

from __future__ import annotations

import sys

from kib.shared import cli, jsonio

PINS: dict[str, object] = {"leftArrowOpensAgents": False}

#: Seeded only when the credential is BROKERED (start_container, once a token exists).
#: Claude Code's first-run onboarding *is* its login flow — a falsy `hasCompletedOnboarding`
#: puts "Select login method" on screen — and a brokered box must never run that: the token is
#: held host-side on purpose and the in-box flow would try to mint one the sandbox may not see.
#: It bites hardest on a new machine, where canonical `.claude.json` does not exist yet, so the
#: first launch ever opens on a login prompt with a perfectly good brokered token behind it.
BROKERED_SEEDS: dict[str, object] = {"hasCompletedOnboarding": True}


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


def seed_brokered(path: str) -> int:
    """Set BROKERED_SEEDS keys the config does not already carry. Never overwrites one."""
    cfg, status = jsonio.load(path)
    if status != "ok" or not isinstance(cfg, dict):
        return cli.FAIL  # unreadable or not JSON: leave it well alone
    missing = {k: v for k, v in BROKERED_SEEDS.items() if k not in cfg}
    if not missing:
        return cli.OK
    cfg.update(missing)
    jsonio.write_atomic(path, cfg)
    sys.stderr.write(
        "🔧 kib: credential is brokered — skipped Claude Code's first-run login in the box "
        "(set your theme with /theme).\n"
    )
    return cli.OK


def main(argv: list[str]) -> int:
    table = {"apply": (apply, 1), "seed-brokered": (seed_brokered, 1)}
    return cli.dispatch("kib.host.pins", table, argv)


if __name__ == "__main__":
    cli.run(main)
