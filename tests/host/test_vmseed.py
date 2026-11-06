"""The VM seed: redacted files as renders, protected ones verbatim, nothing else — and never
through a symlink the VM planted in the shadow."""

import os
from pathlib import Path

import pytest

from kib.host import vmseed
from kib.shared import render, rules

GUARD = Path(__file__).resolve().parents[2] / "guest" / "policy" / "global.kibignore"


def _tree(root: Path, files: dict[str, str]) -> None:
    for rel, text in files.items():
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).write_text(text)


def _files(root: Path) -> dict[str, bytes]:
    return {
        str(p.relative_to(root)): p.read_bytes()
        for p in root.rglob("*")
        if p.is_file() and not p.is_symlink()
    }


def test_seed_carries_only_what_the_sync_ignores(tmp_path: Path) -> None:
    project, shadow = tmp_path / "p", tmp_path / "s"
    _tree(
        project,
        {
            ".env": "API_KEY=s3cret\n",
            "a/creds.pem": "-----BEGIN-----\n",
            ".git/config": "[core]\n",
            ".git/hooks/pre-commit": "#!/bin/sh\n",
            ".git/objects/ab/cd": "blob",
            ".vscode/tasks.json": "{}",
            "a.txt": "plain",
            "node_modules/x/.env": "K=v\n",
        },
    )
    os.chmod(project / ".git/hooks/pre-commit", 0o755)
    os.symlink("/etc/hostname", project / ".env.local")
    shadow.mkdir()
    vmseed.seed(
        str(project), str(shadow), rules.load(str(GUARD), guard=True) + rules.parse(["*.pem"])
    )
    assert _files(shadow) == {
        ".env": b"API_KEY=<redacted>\n",
        "a/creds.pem": render.STUB,
        ".env.local": render.STUB,
        ".git/config": b"[core]\n",
        ".git/hooks/pre-commit": b"#!/bin/sh\n",
        ".vscode/tasks.json": b"{}",
    }
    assert os.stat(shadow / ".git/hooks/pre-commit").st_mode & 0o111  # a hook stays executable


def test_a_tightened_rule_swaps_the_shadow_copy_for_its_render(tmp_path: Path) -> None:
    project, shadow = tmp_path / "p", tmp_path / "s"
    files = {"keys/prod.txt": "TOKEN=real\n", "a.txt": "plain"}
    _tree(project, files)
    _tree(shadow, files)  # synced before the rule existed
    vmseed.redact(str(project), str(shadow), rules.parse(["keys"]), rules.VM_LOCAL)
    assert _files(shadow) == {"keys/prod.txt": b"TOKEN=<redacted>\n", "a.txt": b"plain"}


def test_a_link_planted_in_the_shadow_is_never_followed(tmp_path: Path) -> None:
    project, shadow, outside = tmp_path / "p", tmp_path / "s", tmp_path / "home"
    _tree(project, {"secrets/.env": "K=v\n"})
    outside.mkdir()
    shadow.mkdir()
    os.symlink(outside, shadow / "secrets")  # VM root, through the VM hop
    with pytest.raises(OSError):
        vmseed.seed(str(project), str(shadow), rules.load(str(GUARD), guard=True))
    assert list(outside.iterdir()) == []
