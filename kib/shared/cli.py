"""Exit-code convention and the argv plumbing every kib entry point shares.

One meaning per status, repo-wide, so a bash caller can branch on `$?` instead of
inheriting whatever a Python traceback happened to produce:

    0  OK          did the thing
    1  FAIL        tried and could not
    2  USAGE       the caller passed the wrong arguments
    3  MALFORMED   input parsed as the wrong shape (a settings.json that is not JSON)
    4  UNREADABLE  the input exists but could not be read — always fail *closed*
    5  REFUSED     policy said no (a host-executed git config key, an inline MCP secret)

Parameters travel as ARGV, never environment variables and never JSON the shell has to
assemble: argv has no quoting hazard, `set -x` shows the real call, and a caller cannot leak a
value into a child process by accident. Structured payloads stay in the files being edited, so
there is no stdin protocol to get wrong.
"""

from __future__ import annotations

import sys
from collections.abc import Callable, Mapping, Sequence
from typing import NoReturn

OK = 0
FAIL = 1
USAGE = 2
MALFORMED = 3
UNREADABLE = 4
REFUSED = 5


class AbortError(Exception):
    """Stop with a message on stderr and one of the codes above."""

    def __init__(self, message: str, code: int = FAIL) -> None:
        super().__init__(message)
        self.message = message
        self.code = code


def run(main: Callable[[list[str]], int]) -> NoReturn:
    """Module entry point: call `main(argv[1:])`, turning AbortError into its exit code."""
    try:
        raise SystemExit(main(sys.argv[1:]))
    except AbortError as exc:
        sys.stderr.write(f"{exc.message}\n")
        raise SystemExit(exc.code) from exc


# Subcommand tables are heterogeneous in arity, so the callables are `...`; `argc` is what
# enforces the shape before the call.
Command = Callable[..., int]


def dispatch(prog: str, table: Mapping[str, tuple[Command, int]], argv: Sequence[str]) -> int:
    """Route `argv[0]` through a `{name: (fn, argc)}` table of fixed-arity subcommands.

    For entry points whose subcommands take positional paths only. Anything with real
    flags uses argparse instead — a hand-rolled flag parser is the bug this repo already
    paid for once, in bash.
    """
    if not argv:
        raise AbortError(f"{prog}: expected one of: {', '.join(sorted(table))}", USAGE)
    name, rest = argv[0], argv[1:]
    if name not in table:
        raise AbortError(f"{prog}: unknown subcommand {name!r}", USAGE)
    fn, argc = table[name]
    if len(rest) != argc:
        raise AbortError(f"{prog}: {name} needs {argc} argument(s), got {len(rest)}", USAGE)
    return fn(*rest)
