"""What may reach the host clipboard from the sandbox — the one definition, both platforms.

A clipboard write is host code execution at the user's next terminal paste: an embedded
`ESC[201~` ends bracketed paste and the rest is interpreted as typed input. That sequence, not
the write itself, is the danger — so writes are allowed and the *content* is filtered.

Two callers, deliberately one filter: `kib.guest.wayland_guard` cleans the bytes in flight
through the compositor's pipe on Linux, and `host/clipboard-bridge.sh` cleans the spooled file
before `pbcopy` on macOS. A second copy of this predicate would drift, and the drift is a
platform where the escape survives.

As a CLI it takes a PATH, not stdin, so it can open with `O_NOFOLLOW`: the macOS spool is
bind-mounted read-write into the sandbox, and a symlink planted there would otherwise put a
host file the box cannot read onto the clipboard, where `pbpaste` hands it straight back.

    python3 -m kib.shared.clipboard <file>   # cleaned bytes on stdout, strip count on stderr
"""

from __future__ import annotations

import os
import sys

# Unicode category Cc — C0, DEL and C1 — minus the two that are content rather than control.
# The ranges are frozen by Unicode's stability policy, so this says exactly what
# `unicodedata.category(c) == "Cc"` says, in C rather than a per-character Python loop.
CONTROLS = {c: None for c in [*range(0x20), *range(0x7F, 0xA0)] if c not in (0x09, 0x0A)}

MAX_WRITE = 1 << 20  # a selection is text; anything larger is not a copy


def clean_text(data: bytes) -> tuple[bytes, int]:
    """Strip control characters bar tab and newline; return (bytes, count removed).

    Every visible glyph survives — emoji, CJK, box drawing — so an ordinary select-to-copy is
    byte-identical in practice. Invalid UTF-8 becomes U+FFFD rather than an error: the caller
    has already established this is a text flavour.
    """
    text = data.decode("utf-8", "replace")
    kept = text.translate(CONTROLS)
    return kept.encode("utf-8"), len(text) - len(kept)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: python3 -m kib.shared.clipboard <file>", file=sys.stderr)
        return 2
    try:
        fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as e:
        print(f"unreadable: {e}", file=sys.stderr)
        return 1
    with os.fdopen(fd, "rb") as fh:
        data = fh.read(MAX_WRITE + 1)
    if len(data) > MAX_WRITE:
        print(f"over {MAX_WRITE} bytes", file=sys.stderr)
        return 1
    cleaned, stripped = clean_text(data)
    sys.stdout.buffer.write(cleaned)
    print(stripped, file=sys.stderr)  # the host half alerts when this is non-zero
    return 0


if __name__ == "__main__":
    sys.exit(main())
