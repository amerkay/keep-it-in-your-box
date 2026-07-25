#!/usr/bin/env python3
"""Offline tests for ccignore-fuse's matcher and git-config validator.

Runs anywhere, including inside the sandbox: it stubs the `fuse` module so
ccignore-fuse.py imports without libfuse, and touches no real mount. This is
the only way to exercise the guard from in here, since building the image or
starting the sidecar needs a docker daemon the sandbox does not have.

    python3 test-ccignore-fuse.py
"""

import importlib.util
import os
import sys
import tempfile
import types

HERE = os.path.dirname(os.path.abspath(__file__))

_fuse = types.ModuleType("fuse")
_fuse.FUSE = lambda *a, **k: None
_fuse.Operations = object
_fuse.FuseOSError = type("FuseOSError", (OSError,), {})
sys.modules["fuse"] = _fuse

_spec = importlib.util.spec_from_file_location("ccfuse", os.path.join(HERE, "ccignore-fuse.py"))
m = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m)

GUARD = os.path.join(HERE, "global.ccignore")
fails = []


def check(label, got, want):
    if got != want:
        fails.append(f"{label}: got {got!r}, want {want!r}")
    print(f"  {'ok  ' if got == want else 'FAIL'} {label:50} -> {got!r}")


def build(project_rules=""):
    """A Redact instance with the shipped guard + a project .ccignore."""
    path = write(project_rules)
    r = m.Redact.__new__(m.Redact)
    r.src = "/nonexistent"
    r.rules = m.load_rules(GUARD, guard=True) + m.load_rules(path)
    os.unlink(path)
    return r


def write(text):
    fd, path = tempfile.mkstemp()
    with os.fdopen(fd, "w") as f:
        f.write(text)
    return path


r = build()

print("\n== .env placeholders are readable (committed, hold no secrets) ==")
for p in (
    ".env.example",
    ".env.sample",
    ".env.template",
    ".env.dist",
    ".env.defaults",
    "newd/.env.example",
    "a/b/c/.env.sample",
):
    check(p, r._verdict(p), None)

print("\n== secret-bearing .env variants are redacted ==")
for p in (
    ".env",
    ".env.local",
    ".env.production",
    ".env.staging",
    "newd/.env",
    ".env.example.local",
):
    check(p, r._verdict(p), "redact")

print("\n== a project's '!' cannot un-protect itself ==")
r2 = build("!.env\n!.env.local\n!.vscode\n!.git/config\n")
check("project '!.env'", r2._verdict(".env"), "redact")
check("project '!.env.local'", r2._verdict(".env.local"), "redact")
check("project '!.vscode'", r2._verdict(".vscode/tasks.json"), "protect")
check("project '!.git/config'", r2._protected("/.git/config"), True)

print("\n== a project may still ADD redaction over a placeholder ==")
check("project redacts .env.example", build(".env.example\n")._verdict(".env.example"), "redact")

print("\n== guard patterns are tail-matched at any depth ==")
for p in (
    ".vscode/tasks.json",
    "deep/.vscode/settings.json",
    ".envrc",
    "a/b/.devcontainer/devcontainer.json",
    ".idea/workspace.xml",
):
    check(p, r._verdict(p), "protect")

print("\n== git paths are structural: submodules, worktrees, nested repos ==")
for p in (
    ".git/config",
    "sub/.git/config",
    ".git/modules/x/config",
    ".git/modules/x/modules/y/config",
    ".git/worktrees/w/config.worktree",
    ".git/hooks/pre-commit",
    "sub/.git/hooks/pre-push",
    ".git/modules/x/hooks/pre-commit",
):
    check(p, r._protected("/" + p), True)
for p in ("src/main.py", "hooks/deploy.sh", "config", "src/config"):
    check("not protected: " + p, r._protected("/" + p), False)

print("\n== unrelated paths pass through ==")
for p in ("src/main.py", "README.md", ".github/workflows/ci.yml", "envrc"):
    check(p, r._verdict(p), None)

print("\n== existing .ccignore semantics unchanged ==")
r2 = build("dir/*\n!dir/keep\n")
check("dir/secret masked by 'dir/*'", r2._verdict("dir/secret"), "redact")
check("dir/keep re-included by '!'", r2._verdict("dir/keep"), None)
check("masked parent seals children", build("secrets\n")._verdict("secrets/a/b"), "redact")
check("bare rule never matches in .git", build("build\n")._verdict(".git/build"), None)
check("glob rule '*.pem'", build("*.pem\n")._verdict("certs/server.pem"), "redact")

print("\n== reads: protect passes through, redact serves the stub ==")
check("_classify('/.git/config')", r._classify("/.git/config")[0], "pass")
check("_classify('/.env')", r._classify("/.env")[0], "file")
check("_classify('/.env.example')", r._classify("/.env.example")[0], "pass")

print("\n== git config validation ==")
SAFE = '[core]\n\trepositoryformatversion = 0\n[remote "origin"]\n\turl = https://x/y\n'
LFS = SAFE + '[filter "lfs"]\n\tclean = git-lfs clean\n'
old_safe, old_lfs = write(SAFE), write(LFS)
check("unchanged safe config", r._git_config_write_ok(write(SAFE), old_safe), True)
check(
    "adds core.fsmonitor",
    r._git_config_write_ok(write(SAFE + "[core]\n\tfsmonitor = /e\n"), old_safe),
    False,
)
check(
    "adds core.hooksPath",
    r._git_config_write_ok(write(SAFE + "[core]\n\thooksPath = .git/alt\n"), old_safe),
    False,
)
check(
    "adds an alias", r._git_config_write_ok(write(SAFE + "[alias]\n\tst = !/e\n"), old_safe), False
)
check("adds a filter", r._git_config_write_ok(write(LFS), old_safe), False)
# A pre-existing dangerous entry is the user's own host-side config: adding an
# unrelated remote must not trip over it, but adding a NEW one must still fail.
check(
    "pre-existing lfs + new remote",
    r._git_config_write_ok(write(LFS + '[remote "n"]\n\turl = h\n'), old_lfs),
    True,
)
check(
    "pre-existing lfs + NEW fsmonitor",
    r._git_config_write_ok(write(LFS + "[core]\n\tfsmonitor = /e\n"), old_lfs),
    False,
)
check("unreadable source fails closed", r._git_config_write_ok("/nonexistent", old_safe), False)

print()
if fails:
    print(f"{len(fails)} FAILURE(S):")
    for f in fails:
        print("  " + f)
    sys.exit(1)
print("all tests passed")
