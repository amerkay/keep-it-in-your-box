"""Logging for every kib module. Two channels, deliberately unalike.

`get_logger()` is human-facing prose on stderr with a message-only format. The messages
are already written as sentences (several open with an emoji), so `logging`'s default
`WARNING:` prefix would only get in the way; what the module buys is levels — set
`KIB_LOG_LEVEL=DEBUG` to see the quiet ones without touching a call site.

`stdout_line()` is the broker sidecar's breadcrumb channel and is NOT logging: the host
notifier tails `docker logs` and greps for `BROKER-*`, so each record must stay one line,
on stdout, flushed immediately. Routing it through `logging` would let a formatter or a
level filter silently break that contract.
"""

import logging
import os
import sys
import threading

_LEVEL = os.environ.get("KIB_LOG_LEVEL", "INFO").upper()
_stdout_lock = threading.Lock()


def get_logger(name: str) -> logging.Logger:
    """A stderr logger that prints the message and nothing else.

    Idempotent: repeated calls for one name reuse the single handler, so importing a
    module twice (the guest shims do `-m`, the tests import directly) cannot double
    every line.
    """
    logger = logging.getLogger(name)
    if not logger.handlers:
        handler = logging.StreamHandler(sys.stderr)
        handler.setFormatter(logging.Formatter("%(message)s"))
        logger.addHandler(handler)
        logger.setLevel(getattr(logging, _LEVEL, logging.INFO))
        logger.propagate = False
    return logger


def stdout_line(msg: str) -> None:
    """One flushed line on stdout, under a lock — the broker's `BROKER-*` grep contract.

    The lock matters: the proxy is threaded, and two half-written lines interleaved would
    hide a `BROKER-FATAL` from the notifier that greps for it.
    """
    with _stdout_lock:
        sys.stdout.write(msg + "\n")
        sys.stdout.flush()
