"""Guest — the broker's read-only view of one static token, and placeholder minting.

There is deliberately no write path to any credential in this module; see the package
docstring for the post-mortem of the version that had one.
"""

import json
import os
import threading
from typing import Any

from kib.shared.log import stdout_line

# A far-future expiry (ms) baked into the placeholder credential so in-sandbox claude
# regards its token as valid and never tries to refresh or /login — it just sends the
# placeholder to the broker, which swaps in the real token. 2286-11-20 in ms.
FAR_FUTURE_MS = 10_000_000_000_000
FAKE_PREFIX = "fake_value_"  # sandbox-runtime's sentinel shape


def fake(prefix: str = "") -> str:
    """A structurally-plausible but obviously-fake token.

    `os.urandom` keeps uuid off the import list; FAKE_PREFIX makes it greppable in a log
    or a leaked transcript.
    """
    return prefix + FAKE_PREFIX + os.urandom(16).hex()


def _ptr_parts(pointer: str) -> list[str]:
    """RFC 6901 JSON pointer, the minimal subset the placeholder templates need."""
    return [p.replace("~1", "/").replace("~0", "~") for p in pointer.strip("/").split("/")]


def json_set(obj: dict[str, Any], pointer: str, value: Any) -> None:
    parts = _ptr_parts(pointer)
    cur = obj
    for part in parts[:-1]:
        cur = cur.setdefault(part, {})
    cur[parts[-1]] = value


def mint_placeholder(out_path: str, provider: dict[str, Any]) -> bool:
    """Write the fake credential file that SHADOWS the real one inside the container.

    Built from `placeholder_template`, never cloned from the user's real credential: the
    broker has no access to it and must not acquire any. Non-secret fields are plausible
    constants so Claude parses the file exactly as it would the real thing.

    The signature is load-bearing — `tests/broker/test_broker.py` asserts it takes no
    real-credential path, so threading one back in fails the suite.
    """
    template = provider.get("placeholder_template")
    if template is None:
        return False
    data = json.loads(json.dumps(template))  # deep copy
    for ptr in provider.get("placeholder_fake_pointers", []):
        json_set(data, ptr, fake())
    tmp = out_path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh)
    os.chmod(tmp, 0o600)  # fake tokens only, but claude warns on a world-readable cred
    os.replace(tmp, out_path)
    return True


class Credential:
    """Read-only view of one route's static token.

    Cached in memory and re-read only when the file's mtime/size changes, so a host-side
    `kib broker login` mid-session is picked up without a restart.
    """

    def __init__(self, pid: str, provider: dict[str, Any], token_path: str) -> None:
        self.pid = pid
        self.provider = provider
        self.path = token_path
        self.lock = threading.Lock()
        self._stamp: tuple[int, int] | None = None
        self._value: str | None = None

    def current_secret(self) -> str | None:
        try:
            st = os.stat(self.path)
            stamp = (st.st_mtime_ns, st.st_size)
        except OSError as e:
            stdout_line(f"BROKER-ERR {self.pid} token file unreadable: {e.strerror}")
            return None
        with self.lock:
            if stamp != self._stamp:
                try:
                    with open(self.path) as fh:
                        value = fh.read().strip()
                except OSError as e:
                    stdout_line(f"BROKER-ERR {self.pid} token file unreadable: {e.strerror}")
                    return None
                if not value:
                    stdout_line(f"BROKER-ERR {self.pid} token file is empty")
                    return None
                self._value, self._stamp = value, stamp
            return self._value
