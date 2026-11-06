"""Records today's Python redaction behaviour as the fixtures the Go port must match.

`python3 tests/fixtures/redaction/record.py` rewrites them; `test_redaction_fixtures.py` fails
when they are stale. This script goes with the Python (TMP_PLAN_GO_FUSE.md Phase 2); the JSON
and `render/` stay as the spec. Every value in a case is spelled `s3cr3t`, so a leak is a grep.
"""

from __future__ import annotations

import errno
import json
import logging
import os
import stat
import sys
import tempfile
import types
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
GUARD = ROOT / "guest" / "policy" / "global.kibignore"
sys.path.insert(0, str(ROOT))


class _FuseOSError(OSError):
    def __init__(self, err: int) -> None:
        super().__init__(err, os.strerror(err))


# The server imports fusepy; nothing here mounts, so a stub stands in (as in test_fuse.py).
_stub = types.ModuleType("fuse")
_stub.__dict__.update(
    FUSE=lambda *a, **k: None,
    Operations=object,
    FuseOSError=_FuseOSError,
    fuse_get_context=lambda: (os.getuid(), os.getgid(), os.getpid()),
)
sys.modules.setdefault("fuse", _stub)

from kib.guest import fuse  # noqa: E402
from kib.shared import dangerous, render, rules  # noqa: E402

# ── rules: (project rules, path); the shipped guard applies unless the case says guard=False ──
VERDICT_CASES: list[tuple[str, str]] = [
    *(("", p) for p in (".env.example", ".env.sample", ".env.template", "newd/.env.example")),
    *(("", p) for p in ("a/b/c/.env.sample", ".env.example.tmp.170.e4cc80fbd4d5", ".env.example~")),
    *(("", p) for p in (".env.sample.tmp.4.beef", "a/b/.env.template~")),
    *(
        ("", p)
        for p in (".env", ".env.local", ".env.production", "newd/.env", ".env.example.local")
    ),
    *(("", p) for p in (".env.tmp.170.abc", ".env.local.tmp.170.abc", ".env.local~")),
    *(("", p) for p in (".env.examples", ".env.example.bak", ".env.defaults", ".env.dist")),
    ("!.vscode", ".vscode/tasks.json"),
    ("!.vscode/tasks.json", ".vscode/tasks.json"),
    ("!.envrc", ".envrc"),
    ("!.gitmodules", ".gitmodules"),
    ("!.env", ".env"),
    ("!.env.local", ".env.local"),
    ("!.env.*", ".env.production"),
    ("!config/.env", "config/.env"),
    ("!.env", ".env.local"),
    ("!.env.local", ".env"),
    ("!secrets", "secrets/.env"),
    ("!config", "config/.env"),
    (".env.example", ".env.example"),
    *(("", p) for p in (".vscode/tasks.json", "deep/.vscode/settings.json", ".envrc")),
    *(("", p) for p in ("a/b/.devcontainer/devcontainer.json", ".claude/hooks/pre.sh")),
    *(("", p) for p in (".idea/workspace.xml", "src/main.py", "README.md", "envrc")),
    *(("", p) for p in (".github/workflows/ci.yml", ".git/config", ".git/hooks/pre-commit")),
    *(("", p) for p in (".cursor/mcp.json", ".cursor/rules/r.md", "x/.zed/tasks.json")),
    ("dir/*\n!dir/keep", "dir/secret"),
    ("dir/*\n!dir/keep", "dir/keep"),
    ("secrets", "secrets/a/b"),
    ("secrets\n!secrets/README.md", "secrets/README.md"),
    ("secrets/*\n!secrets/README.md", "secrets/README.md"),
    ("secrets/*\n!secrets/README.md", "secrets/key"),
    ("build", ".git/build"),
    ("build", "sub/.git/build"),
    ("build", "a/build"),
    ("*.pem", "certs/server.pem"),
    ("*.pem", ".pem"),
    ("a/*", "a/b/c"),
    ("a/*.txt", "a/b/c.txt"),
    *(("**/*.pem", p) for p in ("k.pem", "a/k.pem", "a/b/k.pem")),
    ("/etc", "etc"),
    ("../x", "x"),
    ("a/../b", "b"),
    ("[protect]\n.vscode", "[protect]"),
    ("[redact]", "[redact]"),
    ("we[!i]d.txt", "weid.txt"),
    ("we[!i]d.txt", "wexd.txt"),
    ("b{1,2}.txt", "b{1,2}.txt"),
    ("b{1,2}.txt", "b1.txt"),
    ("back\\slash.txt", "back\\slash.txt"),
    ("a[b", "a[b"),
    ("a[]]b", "a]b"),
    ("a[!]]b", "a]b"),
    ("f?o", "foo"),
    ("f?o", "f/o"),
    ("*", ".hidden"),
    ("x # comment", "x"),
    ("dir/", "dir/f"),
    ("!", "!"),
    ("docs\n!docs\nREADME.md\n!README.md\nREADME.md", "README.md"),
    ("docs\n!docs\nREADME.md\n!README.md\nREADME.md", "docs/a.md"),
    ("!*", ".env"),
    ("!*", ".vscode/x"),
    (".*\n!.claude", ".claude/settings.json"),
    (".*\n!.claude", ".hidden/x"),
    ("Secrets", "secrets"),
    *(("", p) for p in (".ENV", ".Env.local", ".VSCode/tasks.json", ".ENVRC")),
]
#: Where the Go port is meant to differ: stricter, never looser.
RULE_NOTES = {
    "secrets": "case-sensitive here; Go matches case-insensitively (macOS disks are)",
    **dict.fromkeys(
        (".ENV", ".Env.local", ".VSCode/tasks.json", ".ENVRC"),
        "case-sensitive here, so a case-insensitive disk opens the real file; Go must guard it",
    ),
}
OPTOUT_NOTES = {"!*": "un-redacts every .env yet is not reported; Go must report it"}
#: Project rules alone, no guard — the matcher's own semantics.
BARE_CASES: list[tuple[str, str]] = [
    ("!foo\nfoo", "foo"),
    ("foo\n!foo", "foo"),
    ("secrets\n!secrets/ok", "secrets"),
    ("secrets\n!secrets/ok", "other"),
]
OPTOUT_CASES = ["!.env\n!.vscode\n!build\nsecrets", "!.env.*\n!config/.env", "", "!*"]
TIGHTEN_CASES: list[tuple[str, str]] = [
    ("*.pem", "*.pem\nsecrets"),
    ("*.pem", "*.pem\n!.env"),
    ("*.pem\nsecrets", "secrets"),
    ("!foo\nfoo", "foo\n!foo"),
    ("", "secrets"),
    ("", "!.env"),
    ("a\n!b", "x\na\ny\n!b"),
    ("a", "a\na"),
]


def _guarded(project: str) -> list[rules.Rule]:
    return rules.load(str(GUARD), guard=True) + rules.parse(project.splitlines())


def record_rules() -> dict[str, Any]:
    guard = rules.load(str(GUARD), guard=True)
    return {
        "guard_file": "guest/policy/global.kibignore",
        "verdict": [
            {"project": p, "path": x, "guard": True, "want": rules.verdict(_guarded(p), x)}
            | ({"note": RULE_NOTES[x]} if x in RULE_NOTES else {})
            for p, x in VERDICT_CASES
        ]
        + [
            {
                "project": p,
                "path": x,
                "guard": False,
                "want": rules.verdict(rules.parse(p.splitlines()), x),
            }
            for p, x in BARE_CASES
        ],
        "optouts": [
            {"project": p, "want": rules.redact_optouts(guard, rules.parse(p.splitlines()))}
            | ({"note": OPTOUT_NOTES[p]} if p in OPTOUT_NOTES else {})
            for p in OPTOUT_CASES
        ],
        "tightens": [
            {
                "old": o,
                "new": n,
                "want": rules.tightens(rules.parse(o.splitlines()), rules.parse(n.splitlines())),
            }
            for o, n in TIGHTEN_CASES
        ],
    }


# ── renders: one input file each under render/, named by shape-free case names ──
def _bomb() -> str:
    names = "abcdefghi"
    return 'a: [&a ["lol","lol","lol","lol","lol","lol","lol","lol","lol"]]\n' + "".join(
        f"{names[i]}: [&{names[i]} [" + ",".join([f"*{names[i - 1]}"] * 9) + "]]\n"
        for i in range(1, len(names))
    )


_RAW: dict[str, str | bytes] = {
    "dotenv-basic": "# a comment\nAPI_KEY=s3cr3t\n\nexport DB_URL = postgres://u:s3cr3t@h/db\n",
    "dotenv-quoted": "A=\"s3cr3t\"\nB='s3cr3t'\nC = s3cr3t # s3cr3t\n",
    "dotenv-bom": "\ufeffAPI_KEY=s3cr3t\n",
    "dotenv-crlf": "A=s3cr3t\r\nB=s3cr3t\r\n",
    "dotenv-lone-cr": "A=s3cr3t\rB=s3cr3t\r",
    "dotenv-colon-value": "URL=http://h:80/s3cr3t\n",
    "dotenv-export-lower": "export a_b=s3cr3t\n",
    "dotenv-multiline": 'CERT="-----BEGIN-----\nMIIs3cr3t\n-----END-----"\n',
    "dotenv-escaped-close": 'A="s3cr3t\\"\n',
    "dotenv-comment-only": "# just a comment\n",
    "prose-one-assignment": "Deploy notes for s3cr3t.\nAPI_KEY=s3cr3t\nMore prose.\n",
    "no-assignment": "NOTKEYVALUE\n",
    "empty": "",
    "json-basic": '{"tok":"s3cr3t","n":{"list":[1,2]},"ok":true}',
    "json-bom": '\ufeff{"a":"s3cr3t"}',
    "json-array-top": '["s3cr3t", {"a": "s3cr3t"}]',
    "json-scalar-top": '"s3cr3t"',
    "json-nan": '{"a": NaN}',
    "json-dup-keys": '{"a": "s3cr3t", "a": "s3cr3t", "b": null}',
    "json-unterminated": '{"unterminated": ',
    "json-deep": "[" * 30_000 + "]" * 30_000,
    "yaml-basic": "provider:\n  stage: s3cr3t\n  env:\n    API_KEY: s3cr3t\nregions:\n  - s3cr3t\n",
    "yaml-multidoc": "a: s3cr3t\n---\nb: s3cr3t\n",
    "yaml-anchor-no-alias": "a: &x s3cr3t\n",
    "yaml-star-in-value": "a: 's3cr3t*'\n",
    "yaml-alias": "base: &a\n  k: s3cr3t\nprod: *a\n",
    "yaml-flow-alias": "a: [&x s3cr3t]\nb: [*x]\n",
    "yaml-recursive-alias": "k: [&x [*x]]\nv: s3cr3t\n",
    "yaml-bomb": _bomb(),
    "yaml-scalar": "just a s3cr3t line of text\n",
    "yaml-list-top": "- a: s3cr3t\n",
    "yaml-1.1-keys": "on: s3cr3t\nyes: s3cr3t\nkey: s3cr3t\n",
    "yaml-int-keys": "1: s3cr3t\n2: s3cr3t\n",
    "yaml-null-value": "a:\nb: ~\n",
    "pem": "-----BEGIN RSA PRIVATE KEY-----\nMIIs3cr3t\n-----END RSA PRIVATE KEY-----\n",
    "oversize": "K=v\n" * (render.RENDER_MAX // 4 + 1),
    "at-limit": "K=" + "s" * (render.RENDER_MAX - 3) + "\n",
    "undecodable": b"\xff\xfeA=s3cr3t\n",
}
RENDER_CASES = {k: v.encode() if isinstance(v, str) else v for k, v in _RAW.items()}
#: Where the Go port may print a key differently (format may differ; no value may ever show).
RENDER_NOTES = {
    "yaml-1.1-keys": "PyYAML reads on/yes as true (YAML 1.1); Go may keep the names",
    "json-nan": "Python's json accepts NaN; Go may render it as YAML instead, same keys",
    "dotenv-lone-cr": "Python's text mode reads a lone CR as a newline; Go may stub instead",
}


def _shape(text: str) -> str | None:
    for renderer in render.RENDERERS:
        if renderer(text) is not None:
            return renderer.__name__.removeprefix("_render_")
    return None


def record_render() -> dict[str, Any]:
    out: dict[str, Any] = {"stub": render.STUB.decode(), "redacted": render.REDACTED_VALUE}
    cases: dict[str, Any] = {}
    with tempfile.TemporaryDirectory() as d:
        for name, body in RENDER_CASES.items():
            path = os.path.join(d, name)
            Path(path).write_bytes(body)
            got = render.render(path)
            want: dict[str, Any]
            if got == render.STUB:
                want = {"shape": "stub"}
            else:
                text = got.decode()
                with open(path, encoding="utf-8-sig") as fh:
                    shape = _shape(fh.read())
                if shape == "dotenv":
                    want = {"shape": shape, "keys": [ln.split("=")[0] for ln in text.splitlines()]}
                elif shape == "json":
                    want = {"shape": shape, "tree": json.loads(text)}
                else:
                    import yaml

                    docs = list(yaml.safe_load_all(text))
                    want = {"shape": shape, "docs": json.loads(json.dumps(docs))}
                assert "s3cr3t" not in text, name
            if name in RENDER_NOTES:
                want["note"] = RENDER_NOTES[name]
            cases[name] = want
    out["cases"] = cases
    return out


# ── git config: the entries a write may not ADD (dangerous.git_ini_entries) ──
SAFE = '[core]\n\trepositoryformatversion = 0\n[remote "origin"]\n\turl = https://x/y\n'
LFS = SAFE + '[filter "lfs"]\n\tclean = git-lfs clean\n'
GITINI_CASES = [
    "[core]hooksPath = /tmp/evil",
    "[core]\n\tfsmonitor = /tmp/fsm.sh\n",
    '[filter "lfs"]\n\tclean = git-lfs clean\n',
    "# core.hooksPath = x\n; fsmonitor = y\n",
    '[filter "e]v"]clean = payload',
    '[filter "a\\"]b"]clean = payload',
    '\t[filter "e]v"]clean = payload',
    '[filter "a;b"]clean = payload',
    '[filter "a#b"]clean = payload',
    "[include]\n\tpath\n",
    '[core]\n\tsshCommand = "ssh #x"\n',
    "\ufeff[core]fsmonitor = /tmp/payload",
    "\ufeff[core]\n\thooksPath = /tmp/payload\n",
    *(f'[filter "{s}x"]clean = /tmp/payload' for s in "\u2028\u2029\x85\v\f\x1c\x1d\x1e"),
    "[core]\rhooksPath = x",
    "[core]\r\n\tbare = false\r\n",
    SAFE,
    LFS,
    "[alias]\n\tst = !/e\n",
    '[includeIf "gitdir:/x/"]\n\tpath = y\n',
    "[pager]\n\tlog = less\n",
    "[core]\n\tpager = less\n\teditor = vim\n",
    "[credential]\n\thelper = store\n",
    '[submodule "lib"]\n\tupdate = !sh\n',
    "[CORE]\n\tHOOKSPATH = x\n",
    "[core.x]\n\thooksPath = y\n",
    "[core]\n\thooksPath\n",
    "[core] # c\n\tfsmonitor = x ; c\n",
]
#: (candidate, current or None for no file): may the rename install the candidate?
GITWRITE_CASES: list[tuple[str, str | None]] = [
    (SAFE, SAFE),
    (SAFE + "[core]\n\tfsmonitor = /e\n", SAFE),
    (SAFE + "[core]\n\thooksPath = .git/alt\n", SAFE),
    (SAFE + "[alias]\n\tst = !/e\n", SAFE),
    (SAFE + "[include]\n\tpath = evil.inc\n", SAFE),
    ("[core]hooksPath = /tmp/evil\n", SAFE),
    (LFS, SAFE),
    (LFS + '[remote "n"]\n\turl = h\n', LFS),
    (LFS + "[core]\n\tfsmonitor = /e\n", LFS),
    (SAFE + "[core]\n\tfsmonitor = /e\n", None),
    (SAFE, None),
]


def _entries(text: str) -> list[list[str]]:
    return sorted(list(e) for e in dangerous.git_ini_entries(text))


def record_gitconfig() -> dict[str, Any]:
    ambiguous = list(dangerous.AMBIGUOUS_ENTRY)
    write = []
    with tempfile.TemporaryDirectory() as d:
        r = fuse.Redact(d, [])
        for cand, cur in GITWRITE_CASES:
            Path(d, "cand").write_text(cand)
            Path(d, "cur").unlink(missing_ok=True)
            if cur is not None:
                Path(d, "cur").write_text(cur)
            ok = r._git_config_write_ok(str(Path(d, "cand")), str(Path(d, "cur")))
            write.append({"candidate": cand, "current": cur, "want": ok})
    return {
        "ambiguous_entry": ambiguous,
        "entries": [{"text": t, "want": _entries(t)} for t in GITINI_CASES],
        "write_ok": write,
    }


# ── the view: steps against a tree, as a mount sees them ──
# A tree maps a path to its text (a trailing "/" is a directory). Steps: put (open with O_CREAT,
# write, close), open-r / open-w and read (symlinks followed), stat (lstat), readdir, unlink,
# rmdir, mkdir, rename, link, symlink, truncate. A step's parent directories exist on the backing
# side first. `@close` errors may not surface on a real mount: there `after` is what counts.
ENVRC = "export FOO=1\n"
ANCHORED = {".vscode/settings.json": '{"a": 1}\n', ".envrc": ENVRC, "wt/": ""}
GITDIR = {".git/config": SAFE, ".git/HEAD": "ref: refs/heads/main\n", ".git/objects/": ""}


def _puts(paths: list[str], data: str = "x\n") -> list[dict[str, Any]]:
    return [{"op": "put", "path": p, "data": data} for p in paths]


FS_CASES: list[dict[str, Any]] = [
    {"name": "a protected path reads through", "tree": GITDIR,
     "steps": [{"op": "read", "path": ".git/config"}]},
    {"name": "a redacted file reads as keys", "tree": {".env": "K=s3cr3t\n"},
     "steps": [{"op": "stat", "path": ".env"}, {"op": "read", "path": ".env"},
               {"op": "readdir", "path": ""}]},
    {"name": "a placeholder passes", "tree": {".env.example": "OLD=placeholder\n"},
     "steps": [{"op": "read", "path": ".env.example"}, {"op": "stat", "path": ".env.example"}]},
    *({"name": f"a placeholder is edited through {t}", "tree": {".env.example": "OLD=p\n"},
       "steps": [{"op": "put", "path": t, "data": "NEW=p\n"},
                 {"op": "rename", "path": t, "to": ".env.example"}]}
      for t in (".env.example.tmp.170.e4cc80fbd4d5", ".env.example~")),
    {"name": "the write-sibling carve-out stops at secret names", "tree": {},
     "steps": _puts([".env.tmp.170.abc", ".env.local~"])},
    {"name": "a redacted directory shows one marker", "project": "secrets",
     "tree": {"secrets/inner": "s3cr3t\n", "secrets/sub/x": "s3cr3t\n"},
     "steps": [{"op": "stat", "path": "secrets"}, {"op": "readdir", "path": "secrets"},
               {"op": "read", "path": "secrets/REDACTED.md"},
               {"op": "stat", "path": "secrets/REDACTED.md"},
               {"op": "stat", "path": "secrets/inner"}, {"op": "read", "path": "secrets/inner"},
               {"op": "readdir", "path": "secrets/sub"}, {"op": "put", "path": "secrets/new"},
               {"op": "unlink", "path": "secrets/inner"}]},
    {"name": "inside a redacted FILE path", "project": "blob", "tree": {"blob": "s3cr3t\n"},
     "steps": [{"op": "stat", "path": "blob/x"}, {"op": "read", "path": "blob"}]},
    {"name": "a stub for an unknown shape", "project": "secret.pem",
     "tree": {"secret.pem": "-----BEGIN KEY-----\ns3cr3t\n"},
     "steps": [{"op": "read", "path": "secret.pem"}, {"op": "stat", "path": "secret.pem"}]},
    {"name": "a masked path the host lacks is ENOENT, and stays unwritable", "tree": {},
     "steps": [{"op": "stat", "path": ".env.local"}, {"op": "open-r", "path": ".env.local"},
               {"op": "put", "path": ".env.local"}, {"op": "mkdir", "path": ".env.d"}]},
    {"name": "every write to a redacted file is refused", "tree": {".env": "K=s3cr3t\n"},
     "steps": [{"op": "open-w", "path": ".env"}, {"op": "put", "path": ".env"},
               {"op": "truncate", "path": ".env", "length": 0},
               {"op": "unlink", "path": ".env"}, {"op": "rename", "path": ".env", "to": "x"},
               {"op": "link", "path": "alias", "to": ".env"},
               {"op": "symlink", "path": "sl", "to": ".env"}, {"op": "read", "path": "sl"}]},
    {"name": "git paths are protected at any nesting", "tree": GITDIR,
     "steps": _puts([".git/config", "sub/.git/config", ".git/modules/x/config",
                     ".git/modules/x/modules/y/config", ".git/worktrees/w/config.worktree",
                     ".git/hooks/pre-commit", "sub/.git/hooks/pre-push",
                     ".git/modules/x/hooks/pre-commit"])},
    {"name": "host-executed files are protected", "tree": {},
     "steps": _puts([".githooks/pre-commit", ".gitmodules", ".cursor/mcp.json",
                     ".zed/tasks.json", ".zed/debug.json", ".run/app.run.xml",
                     ".mvn/jvm.config", ".exrc", ".nvim.lua", ".ripgreprc", ".yarnrc.yml",
                     "sub/.githooks/pre-push", ".vscode/tasks.json", ".devcontainer/d.json",
                     ".envrc"])},
    {"name": "lookalikes and mixed-use files are writable", "tree": {},
     "steps": _puts(["src/main.py", "hooks/deploy.sh", "config", "src/config",
                     ".cursor/rules/style.md", ".claude/commands/deploy.md",
                     ".claude/settings.json", ".claude/hooks/notify.sh",
                     "vendor/pkg/.claude/hooks/x.sh", ".claude-plugin/plugin.json", ".mcp.json",
                     "mise.toml", ".idea/workspace.xml"])},
    {"name": "guarded paths cannot be deleted",
     "tree": {**GITDIR, ".vscode/settings.json": "{}\n", "sub/.githooks/pre-push": "x\n",
              ".envrc": ENVRC},
     "steps": [{"op": "unlink", "path": p}
               for p in (".vscode/settings.json", ".git/config", "sub/.githooks/pre-push",
                         ".envrc")] + [{"op": "rmdir", "path": ".vscode"}]},
    {"name": "a project cannot un-protect its git config", "project": "!.git/config",
     "tree": GITDIR, "steps": _puts([".git/config"])},
    {"name": "a refusal is EPERM", "tree": {".env": "A=1\n", ".envrc": ENVRC},
     "steps": [{"op": "open-w", "path": p} for p in (".env", ".envrc", ".githooks/pre-commit")]},
    {"name": "a git dir is known by its layout",
     "tree": {"store/HEAD": "ref: x\n", "store/objects/": "", "store/refs/": ""},
     "steps": _puts(["store/config", "store/hooks/pre-commit", "other/config"])},
    {"name": "a nested copy of a root anchor may be written", "tree": ANCHORED,
     "steps": _puts(["wt/.envrc"], ENVRC)},
    {"name": "a nested copy one byte off is refused", "tree": ANCHORED,
     "steps": _puts(["wt/.envrc"], "export FOO=2\n")},
    {"name": "a nested guarded path with no root copy is refused", "tree": ANCHORED,
     "steps": _puts(["wt/.vscode/tasks.json"])},
    {"name": "the root copy is never its own mirror", "tree": ANCHORED,
     "steps": [*_puts([".envrc"], ENVRC), *_puts([".vscode/settings.json"], '{"a": 1}\n')]},
    {"name": "a short mirror is removed at close", "tree": ANCHORED,
     "steps": _puts(["wt/.envrc"], ENVRC[:6])},
    {"name": "a long mirror is refused", "tree": ANCHORED,
     "steps": _puts(["wt/.envrc"], ENVRC + "x")},
    {"name": "a read-only open of git config leaves it", "tree": GITDIR,
     "steps": [{"op": "open-r", "path": ".git/config"}]},
    {"name": "git paths are never mirrorable", "tree": {**ANCHORED, **GITDIR,
                                                     ".git/hooks/pre-commit": "#!/bin/sh\n"},
     "steps": [*_puts(["wt/.git/config"], SAFE),
               *_puts(["wt/.git/hooks/pre-commit"], "#!/bin/sh\n")]},
    {"name": "a redacted path is never mirrorable", "tree": {".env": "A=1\n"},
     "steps": _puts(["wt/.env"], "A=1\n")},
    {"name": "no mirror by rename, link or symlink",
     "tree": {**ANCHORED, "wt/payload": "export FOO=2\n", "wt/same": ENVRC},
     "steps": [{"op": "rename", "path": "wt/payload", "to": "wt/.envrc"},
               {"op": "rename", "path": "wt/same", "to": "wt/.envrc"},
               {"op": "symlink", "path": "wt/.envrc", "to": "/etc/passwd"},
               {"op": "link", "path": "wt/.envrc", "to": "wt/payload"},
               {"op": "link", "path": "wt/alias", "to": ".envrc"},
               {"op": "rename", "path": ".envrc", "to": "wt/moved"}]},
    {"name": "a mirror cannot be reshaped by truncate", "tree": ANCHORED,
     "steps": [*_puts(["wt/.envrc"], ENVRC),
               {"op": "truncate", "path": "wt/.envrc", "length": 6}]},
    {"name": "a guarded directory is created when the root one exists", "tree": ANCHORED,
     "steps": [{"op": "mkdir", "path": "wt/.vscode"}, {"op": "mkdir", "path": "wt/.devcontainer"}]},
    {"name": "a mirror may be deleted, its anchor not", "tree": ANCHORED,
     "steps": [*_puts(["wt/.envrc"], ENVRC), {"op": "unlink", "path": "wt/.envrc"},
               {"op": "unlink", "path": ".envrc"}]},
    *({"name": f"git config write: {i}", "tree": GITDIR | {".git/config": cur or ""},
       "drop": [] if cur else [".git/config"],
       "steps": [{"op": "put", "path": ".git/config.lock", "data": cand},
                 {"op": "rename", "path": ".git/config.lock", "to": ".git/config"}]}
      for i, (cand, cur) in enumerate(GITWRITE_CASES)),
    {"name": "an undecodable git config write is refused", "tree": GITDIR,
     "steps": [{"op": "put", "path": ".git/config.lock", "hex": "fffe00636f6e666967"},
               {"op": "rename", "path": ".git/config.lock", "to": ".git/config"}]},
    {"name": "ordinary files pass through", "tree": {"a/b.txt": "hello\n"},
     "steps": [{"op": "read", "path": "a/b.txt"}, {"op": "put", "path": "a/c.txt"},
               {"op": "rename", "path": "a/c.txt", "to": "a/d.txt"},
               {"op": "link", "path": "a/e.txt", "to": "a/d.txt"},
               {"op": "symlink", "path": "a/f", "to": "b.txt"}, {"op": "read", "path": "a/f"},
               {"op": "truncate", "path": "a/b.txt", "length": 2},
               {"op": "mkdir", "path": "a/g"}, {"op": "rmdir", "path": "a/g"},
               {"op": "unlink", "path": "a/e.txt"}, {"op": "readdir", "path": "a"}]},
]  # fmt: skip


def _err(e: OSError, phase: str = "") -> str:
    name = errno.errorcode.get(e.errno or 0, str(e.errno))
    return f"{name}@{phase}" if phase else name


def _follow(r: Any, p: str) -> str:
    """What the kernel opens for `p`: each lookup through the view, symlinks resolved by it."""
    for _ in range(8):
        if not stat.S_ISLNK(r.getattr(p)["st_mode"]):  # an ENOENT here is the open's
            return p
        target: str = r.readlink(p)
        if target.startswith("/"):
            return "outside:" + target
        p = os.path.normpath(os.path.join(os.path.dirname(p), target))
    raise OSError(errno.ELOOP, "loop")


def _step(r: Any, src: str, s: dict[str, Any]) -> Any:
    op, p = s["op"], "/" + s["path"]
    parent = os.path.dirname(os.path.join(src, s["path"]))
    if not os.path.lexists(parent):
        os.makedirs(parent)
    if op == "put":  # open(2) with O_CREAT: the kernel creates only a name it cannot look up
        data = bytes.fromhex(s["hex"]) if "hex" in s else s.get("data", "x\n").encode()
        try:
            try:
                r.getattr(p)
            except OSError:
                fh = r.create(p, 0o644)
            else:
                fh = r.open(p, os.O_WRONLY | os.O_TRUNC)
        except OSError as e:
            return _err(e, "open")
        failed = ""
        try:
            if data:
                r.write(p, data, 0, fh)
        except OSError as e:
            failed = _err(e, "write")
        try:
            r.release(p, fh)
        except OSError as e:
            failed = failed or _err(e, "close")
        return failed or "OK"
    try:
        if op in ("open-r", "open-w", "read"):
            p = _follow(r, p)
            if p.startswith("outside:"):
                return p
            fh = r.open(p, os.O_WRONLY if op == "open-w" else os.O_RDONLY)
            data = r.read(p, 1 << 20, 0, fh) if op == "read" else b""
            r.release(p, fh)
            if op == "read":
                return "STUB" if data == render.STUB else data.decode()
        elif op == "stat":
            a = r.getattr(p)
            kind = {stat.S_IFREG: "file", stat.S_IFDIR: "dir", stat.S_IFLNK: "symlink"}
            return {"type": kind[stat.S_IFMT(a["st_mode"])], "perm": oct(a["st_mode"] & 0o777),
                    "size": a["st_size"] if stat.S_ISREG(a["st_mode"]) else None}  # fmt: skip
        elif op == "readdir":
            return sorted(set(r.readdir(p, 0)) - {".", ".."})
        elif op in ("rename", "link", "symlink"):
            to = s["to"] if op == "symlink" else "/" + s["to"]
            if op == "rename":
                r.rename(p, to)
            else:
                getattr(r, op)(p, to)
        elif op == "truncate":
            r.truncate(p, s["length"])
        elif op == "mkdir":
            r.mkdir(p, 0o755)
        else:
            getattr(r, op)(p)
    except OSError as e:
        return _err(e)
    return "OK"


def _snapshot(src: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for d, dirs, files in os.walk(src):
        for name in dirs + files:
            full = os.path.join(d, name)
            rel = os.path.relpath(full, src)
            if os.path.islink(full):
                out[rel] = "-> " + os.readlink(full)
            elif os.path.isdir(full):
                out[rel + "/"] = ""
            else:
                raw = Path(full).read_bytes()
                try:
                    out[rel] = raw.decode()
                except UnicodeDecodeError:
                    out[rel] = "hex:" + raw.hex()
    return dict(sorted(out.items()))


def record_fs() -> list[dict[str, Any]]:
    out = []
    for case in FS_CASES:
        with tempfile.TemporaryDirectory() as src:
            for rel, text in case["tree"].items():
                full = os.path.join(src, rel)
                os.makedirs(full if rel.endswith("/") else os.path.dirname(full), exist_ok=True)
                if not rel.endswith("/"):
                    Path(full).write_text(text)
                    os.chmod(full, 0o644)
            for rel in case.get("drop", []):
                os.unlink(os.path.join(src, rel))
            r = fuse.Redact(src, _guarded(case.get("project", "")))
            steps = [{**s, "want": _step(r, src, s)} for s in case["steps"]]
            tree = {k: v for k, v in case["tree"].items() if k not in case.get("drop", [])}
            out.append({"name": case["name"], "project": case.get("project", ""), "tree": tree,
                        "steps": steps, "after": _snapshot(src)})  # fmt: skip
    return out


def build() -> dict[str, bytes]:
    """Every fixture file, by path relative to this directory."""
    logging.disable(logging.CRITICAL)  # the refusals the cases provoke, each logged

    def dump(obj: Any) -> bytes:
        return (json.dumps(obj, indent=1, ensure_ascii=False) + "\n").encode()

    files = {f"render/{name}": body for name, body in RENDER_CASES.items()}
    files["rules.json"] = dump(record_rules())
    files["render.json"] = dump(record_render())
    files["gitconfig.json"] = dump(record_gitconfig())
    files["fs.json"] = dump(record_fs())
    return files


if __name__ == "__main__":
    files = build()
    for rel, body in files.items():
        (HERE / rel).parent.mkdir(exist_ok=True)
        (HERE / rel).write_bytes(body)
    print(f"wrote {len(files)} fixture files to {HERE.relative_to(ROOT)}")
