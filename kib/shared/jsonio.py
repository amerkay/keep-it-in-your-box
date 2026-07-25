"""Read and atomically write the JSON files kib edits on the user's behalf.

Every writer here does mkstemp → chmod 600 → `os.replace` in the *destination directory*,
which is the only shape that is both atomic and never briefly world-readable. It was
written out twice before (the `.claude.json` pin and the config-scope merge) and the two
copies had already drifted on the chmod.

`load()` reports *why* it failed rather than raising, because every caller has to tell
"absent" (start from a default) apart from "corrupt" (leave the original alone). Silently
treating a corrupt canonical file as empty is how a config gets overwritten.
"""

import json
import os
import tempfile
from typing import Any

Status = str  # 'ok' | 'absent' | 'bad'


def load(path: str) -> tuple[Any, Status]:
    """Return `(obj, status)` where status is 'ok', 'absent' or 'bad'."""
    if not os.path.exists(path):
        return None, "absent"
    try:
        with open(path) as fh:
            return json.load(fh), "ok"
    except (OSError, ValueError):
        return None, "bad"


def load_dict(path: str) -> dict[str, Any]:
    """The object at `path` if it is a dict, else `{}`. For read-modify-write callers."""
    obj, status = load(path)
    return obj if status == "ok" and isinstance(obj, dict) else {}


def write_atomic(path: str, obj: Any, mode: int = 0o600) -> None:
    """Atomically replace `path` with `obj` as indented JSON, never world-readable.

    The temp file is created in the destination directory so `os.replace` stays a rename
    within one filesystem; a `/tmp` staging file would fall back to a copy and lose
    atomicity exactly when it matters.
    """
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".kib.")
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(obj, fh, indent=2)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
