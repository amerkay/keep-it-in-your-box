"""The VM seed: redacted files as renders, protected ones verbatim, nothing else."""

import io
import os
import tarfile
from pathlib import Path

from kib.host import vmseed
from kib.shared import render, rules

GUARD = Path(__file__).resolve().parents[2] / "guest" / "policy" / "global.kibignore"


def test_seed_carries_only_what_the_sync_ignores(tmp_path: Path) -> None:
    files = {
        ".env": "API_KEY=s3cret\n",
        "a/creds.pem": "-----BEGIN-----\n",
        ".git/config": "[core]\n",
        ".git/hooks/pre-commit": "#!/bin/sh\n",
        ".git/objects/ab/cd": "blob",
        ".vscode/tasks.json": "{}",
        "a.txt": "plain",
        "node_modules/x/.env": "K=v\n",
    }
    for rel, text in files.items():
        (tmp_path / rel).parent.mkdir(parents=True, exist_ok=True)
        (tmp_path / rel).write_text(text)
    os.symlink("/etc/hostname", tmp_path / ".env.local")
    out = io.BytesIO()
    vmseed.seed(str(tmp_path), rules.load(str(GUARD), guard=True) + rules.parse(["*.pem"]), out)
    out.seek(0)
    with tarfile.open(fileobj=out) as tar:
        got = {m.name: tar.extractfile(m).read() for m in tar if m.isfile()}  # type: ignore[union-attr]
    assert got == {
        ".env": b"API_KEY=<redacted>\n",
        "a/creds.pem": render.STUB,
        ".env.local": render.STUB,
        ".git/config": b"[core]\n",
        ".git/hooks/pre-commit": b"#!/bin/sh\n",
        ".vscode/tasks.json": b"{}",
    }
