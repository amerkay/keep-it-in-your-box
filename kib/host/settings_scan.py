"""Scan one settings.json for keys whose value is a command Claude runs.

`~/.claude/settings.json` is staged into EVERY project's box and folded back out on exit,
so one poisoned session reaches every other project's next session AND a host `claude`. The
file has to stay writable — `/config` and theme changes are normal — so the control lives
here instead: the host runs this before any container reads the file, and again on the way
back out before the session's copy may re-enter canonical.

Prints the offending `key = value` lines on stdout, one per line.

Exit: 0 clean · 1 findings · 3 not JSON (warn, don't block — Claude ignores an unparseable
settings file anyway) · 4 unreadable (fail closed: a file we cannot check must not pass).
"""

import json

from kib.shared import cli, dangerous


def scan(path: str) -> int:
    try:
        with open(path) as fh:
            cfg = json.load(fh)
    except ValueError:
        return cli.MALFORMED
    except OSError:
        return cli.UNREADABLE
    if not isinstance(cfg, dict):
        return cli.MALFORMED

    findings = dangerous.settings_findings(cfg)
    print("\n".join(findings))
    return cli.FAIL if findings else cli.OK


def main(argv: list[str]) -> int:
    return cli.dispatch("kib.host.settings_scan", {"scan": (scan, 1)}, argv)


if __name__ == "__main__":
    cli.run(main)
