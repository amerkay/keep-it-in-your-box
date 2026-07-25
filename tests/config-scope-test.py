#!/usr/bin/env python3
"""Unit tests for claude-config-scope.py — the per-project ~/.claude assembly seam.

Runs entirely against a throwaway temp dir; the real ~/.claude is never touched.
Invoked by tests/check.sh and standalone: python3 tests/config-scope-test.py
"""

import importlib.util
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCOPE_PY = os.path.join(os.path.dirname(HERE), "claude-config-scope.py")

_spec = importlib.util.spec_from_file_location("ccscope", SCOPE_PY)
cs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cs)

PA = "/home/kay/proj-a"
PB = "/home/kay/proj-b"

_fails = []


def check(name, cond):
    print(("  ✓ " if cond else "  ✗ ") + name)
    if not cond:
        _fails.append(name)


def read_json(p):
    with open(p) as fh:
        return json.load(fh)


def test_scope_in_json(tmp):
    src = os.path.join(tmp, "canonical.json")
    dst = os.path.join(tmp, "session.json")
    with open(src, "w") as fh:
        json.dump({
            "oauthAccount": {"email": "u@example.com"},
            "onboardingComplete": True,
            "projects": {
                PA: {"mcpServers": {"a-mcp": {}}, "allowedTools": ["A"]},
                PB: {"mcpServers": {"b-mcp": {}}, "allowedTools": ["B-SENTINEL"]},
            },
            "githubRepoPaths": {"repo": [PA, PB]},
        }, fh)

    cs.scope_in_json(src, PA, dst)
    out = read_json(dst)
    check("scope-in keeps global keys", out.get("onboardingComplete") is True)
    check("scope-in keeps oauthAccount", out.get("oauthAccount", {}).get("email") == "u@example.com")
    check("scope-in keeps only this project", list(out["projects"].keys()) == [PA])
    check("scope-in drops other project entirely",
          "B-SENTINEL" not in json.dumps(out))
    check("scope-in filters githubRepoPaths to this project",
          out.get("githubRepoPaths") == {"repo": [PA]})


def test_scope_in_absent_and_bad(tmp):
    dst = os.path.join(tmp, "s2.json")
    cs.scope_in_json(os.path.join(tmp, "nope.json"), PA, dst)
    check("scope-in on absent canonical → empty projects", read_json(dst)["projects"] == {})

    bad = os.path.join(tmp, "bad.json")
    with open(bad, "w") as fh:
        fh.write("{not json")
    dst3 = os.path.join(tmp, "s3.json")
    cs.scope_in_json(bad, PA, dst3)
    check("scope-in on corrupt canonical → empty projects (no crash)",
          read_json(dst3)["projects"] == {})


def test_merge_out_json(tmp):
    canonical = os.path.join(tmp, "canon.json")
    with open(canonical, "w") as fh:
        json.dump({
            "onboardingComplete": True,
            "projects": {
                PA: {"allowedTools": ["OLD"]},
                PB: {"allowedTools": ["B-SENTINEL"]},
            },
        }, fh)
    scratch = os.path.join(tmp, "scr.json")
    with open(scratch, "w") as fh:
        json.dump({
            "onboardingComplete": True,
            "extraGlobalWrittenInBox": "ignored",
            "projects": {PA: {"allowedTools": ["NEW"], "mcpServers": {"added": {}}}},
        }, fh)

    rc = cs.merge_out_json(scratch, PA, canonical)
    out = read_json(canonical)
    check("merge-out returns 0", rc == 0)
    check("merge-out updates this project's subtree", out["projects"][PA]["allowedTools"] == ["NEW"])
    check("merge-out lands new mcpServers", "added" in out["projects"][PA]["mcpServers"])
    check("merge-out leaves OTHER project byte-identical",
          out["projects"][PB] == {"allowedTools": ["B-SENTINEL"]})
    check("merge-out does not import session-only global keys",
          "extraGlobalWrittenInBox" not in out)


def test_merge_out_failclosed(tmp):
    canonical = os.path.join(tmp, "c2.json")
    orig = {"projects": {PA: {"allowedTools": ["KEEP"]}}}
    with open(canonical, "w") as fh:
        json.dump(orig, fh)
    bad = os.path.join(tmp, "scr-bad.json")
    with open(bad, "w") as fh:
        fh.write("{broken")
    rc = cs.merge_out_json(bad, PA, canonical)
    check("merge-out fail-closed on bad scratch (rc!=0)", rc != 0)
    check("merge-out fail-closed leaves canonical untouched", read_json(canonical) == orig)

    # Corrupt canonical must not be clobbered either.
    corrupt = os.path.join(tmp, "c3.json")
    with open(corrupt, "w") as fh:
        fh.write("{was corrupt")
    good = os.path.join(tmp, "scr-good.json")
    with open(good, "w") as fh:
        json.dump({"projects": {PA: {"x": 1}}}, fh)
    rc = cs.merge_out_json(good, PA, corrupt)
    check("merge-out refuses to overwrite corrupt canonical (rc!=0)", rc != 0)


def test_merge_out_absent_canonical(tmp):
    canonical = os.path.join(tmp, "fresh.json")  # does not exist
    scratch = os.path.join(tmp, "scr3.json")
    with open(scratch, "w") as fh:
        json.dump({"onboardingComplete": True, "projects": {PA: {"y": 2}}}, fh)
    rc = cs.merge_out_json(scratch, PA, canonical)
    out = read_json(canonical)
    check("merge-out creates canonical from skeleton", rc == 0 and out["projects"][PA] == {"y": 2})
    check("merge-out carries session globals into fresh canonical",
          out.get("onboardingComplete") is True)


def test_merge_out_never_deletes(tmp):
    """A session config with no entry for this project must not wipe canonical's."""
    canonical = os.path.join(tmp, "c4.json")
    with open(canonical, "w") as fh:
        json.dump({"projects": {PA: {"allowedTools": ["KEEP"]}}}, fh)
    scratch = os.path.join(tmp, "scr4.json")
    with open(scratch, "w") as fh:
        json.dump({"projects": {}}, fh)     # e.g. Claude re-created a reset config in-box
    rc = cs.merge_out_json(scratch, PA, canonical)
    out = read_json(canonical)
    check("merge-out never deletes a canonical entry the session lacks",
          rc == 0 and out["projects"].get(PA, {}).get("allowedTools") == ["KEEP"])


def test_merge_out_drops_cc_pins(tmp):
    """cc's forced sandbox pins are not the user's choice — never export them."""
    canonical = os.path.join(tmp, "fresh2.json")   # absent
    scratch = os.path.join(tmp, "scr5.json")
    with open(scratch, "w") as fh:
        json.dump({"leftArrowOpensAgents": False, "onboardingComplete": True,
                   "projects": {PA: {"z": 3}}}, fh)
    cs.merge_out_json(scratch, PA, canonical)
    out = read_json(canonical)
    check("merge-out never exports cc's sandbox pins into a fresh canonical",
          "leftArrowOpensAgents" not in out)
    check("merge-out still carries real globals into a fresh canonical",
          out.get("onboardingComplete") is True)


def _hline(project, text):
    return json.dumps({"display": text, "project": project})


def test_seed_history(tmp):
    src = os.path.join(tmp, "history.jsonl")
    with open(src, "w") as fh:
        fh.write(_hline(PA, "a-one") + "\n")
        fh.write(_hline(PB, "b-SENTINEL") + "\n")
        fh.write("garbage-not-json\n")
        fh.write(_hline(PA, "a-two") + "\n")
    dst = os.path.join(tmp, "sess-history.jsonl")
    cs.seed_history(src, PA, dst)
    got = open(dst).read()
    check("seed-history keeps this project's lines", "a-one" in got and "a-two" in got)
    check("seed-history excludes other project (no B-SENTINEL)", "b-SENTINEL" not in got)
    check("seed-history drops non-json lines", "garbage-not-json" not in got)


def test_merge_history(tmp):
    canonical = os.path.join(tmp, "canon-history.jsonl")
    with open(canonical, "w") as fh:
        fh.write(_hline(PA, "a-one") + "\n")
        fh.write(_hline(PB, "b-SENTINEL") + "\n")
    scratch = os.path.join(tmp, "sess-history2.jsonl")
    with open(scratch, "w") as fh:
        fh.write(_hline(PA, "a-one") + "\n")     # already present
        fh.write(_hline(PA, "a-three") + "\n")   # new
    cs.merge_history(scratch, PA, canonical)
    got = open(canonical).read().splitlines()
    check("merge-history appends the new line", any("a-three" in l for l in got))
    check("merge-history does not duplicate existing", sum("a-one" in l for l in got) == 1)
    check("merge-history leaves other project's line intact", any("b-SENTINEL" in l for l in got))
    check("merge-history never rewrote other project's line count",
          sum("b-SENTINEL" in l for l in got) == 1)

    # Canonical cut short mid-append (no trailing newline) must not have our first line
    # glued onto its last one.
    torn = os.path.join(tmp, "torn-history.jsonl")
    with open(torn, "w") as fh:
        fh.write(_hline(PB, "b-TORN"))      # deliberately no "\n"
    cs.merge_history(scratch, PA, torn)
    lines = [l for l in open(torn).read().splitlines() if l]
    check("merge-history repairs a missing trailing newline before appending",
          all(json.loads(l) for l in lines) and len(lines) == 3)


def test_classify(tmp):
    home = os.path.join(tmp, "dotclaude")
    os.makedirs(home)
    for name in ("settings.json", "projects", "daemon.lock", "brand-new-store", "mystery.db"):
        p = os.path.join(home, name)
        if "." in name and name != "brand-new-store":
            open(p, "w").close()
        else:
            os.makedirs(p, exist_ok=True)
    import io
    import contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        cs.classify(home)
    unknown = set(buf.getvalue().split())
    check("classify flags unrecognised entries", {"brand-new-store", "mystery.db"} <= unknown)
    check("classify does not flag known entries",
          not ({"settings.json", "projects", "daemon.lock"} & unknown))


def main():
    with tempfile.TemporaryDirectory() as tmp:
        for fn in (test_scope_in_json, test_scope_in_absent_and_bad, test_merge_out_json,
                   test_merge_out_failclosed, test_merge_out_absent_canonical,
                   test_merge_out_never_deletes, test_merge_out_drops_cc_pins,
                   test_seed_history, test_merge_history, test_classify):
            print(fn.__name__)
            fn(tmp)
    if _fails:
        print("\n%d check(s) FAILED: %s" % (len(_fails), ", ".join(_fails)))
        return 1
    print("\nAll config-scope checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
