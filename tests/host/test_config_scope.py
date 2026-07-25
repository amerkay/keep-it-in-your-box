"""The per-project ~/.claude assembly seam.

Canonical ~/.claude holds every project's transcripts, ↑ history and .claude.json entries;
each box gets only this project's slice. Two properties matter and both are asserted here:
nothing from another project may appear in the assembly, and nothing may be lost on the way
back out — every merge is fail-closed, so a bad read writes nothing rather than guessing.

Runs entirely against tmp_path; the real ~/.claude is never touched.
"""

import json
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest

from kib.host import config_scope as cs
from kib.shared import cli

PA = "/home/kay/proj-a"
PB = "/home/kay/proj-b"


def read(path: Path) -> Any:
    """Parsed JSON of arbitrary shape — the point of most of these assertions."""
    return json.loads(path.read_text())


def hline(project: str, text: str) -> str:
    return json.dumps({"display": text, "project": project})


# ── scope-in ─────────────────────────────────────────────────────
def test_scope_in_keeps_globals_and_only_this_project(
    tmp_path: Path, write_json: Callable[[str, object], Path]
) -> None:
    src = write_json(
        "canonical.json",
        {
            "oauthAccount": {"email": "u@example.com"},
            "onboardingComplete": True,
            "projects": {
                PA: {"mcpServers": {"a-mcp": {}}, "allowedTools": ["A"]},
                PB: {"mcpServers": {"b-mcp": {}}, "allowedTools": ["B-SENTINEL"]},
            },
            "githubRepoPaths": {"repo": [PA, PB]},
        },
    )
    dst = tmp_path / "session.json"
    cs.scope_in_json(str(src), PA, str(dst))
    out = read(dst)

    assert out["onboardingComplete"] is True
    assert out["oauthAccount"]["email"] == "u@example.com"
    assert list(out["projects"]) == [PA]
    assert "B-SENTINEL" not in json.dumps(out), "another project leaked into the assembly"
    assert out["githubRepoPaths"] == {"repo": [PA]}


def test_scope_in_on_absent_canonical_yields_empty_projects(tmp_path: Path) -> None:
    dst = tmp_path / "s.json"
    cs.scope_in_json(str(tmp_path / "nope.json"), PA, str(dst))
    assert read(dst)["projects"] == {}


def test_scope_in_on_corrupt_canonical_does_not_abort_the_launch(
    tmp_path: Path, write_file: Callable[[str, str], Path]
) -> None:
    bad = write_file("bad.json", "{not json")
    dst = tmp_path / "s.json"
    cs.scope_in_json(str(bad), PA, str(dst))
    assert read(dst)["projects"] == {}


# ── merge-out ────────────────────────────────────────────────────
def test_merge_out_writes_only_this_projects_subtree(
    tmp_path: Path, write_json: Callable[[str, object], Path]
) -> None:
    canonical = write_json(
        "canon.json",
        {
            "onboardingComplete": True,
            "projects": {PA: {"allowedTools": ["OLD"]}, PB: {"allowedTools": ["B-SENTINEL"]}},
        },
    )
    scratch = write_json(
        "scr.json",
        {
            "onboardingComplete": True,
            "extraGlobalWrittenInBox": "ignored",
            "projects": {PA: {"allowedTools": ["NEW"], "mcpServers": {"added": {}}}},
        },
    )
    assert cs.merge_out_json(str(scratch), PA, str(canonical)) == cli.OK
    out = read(canonical)
    assert out["projects"][PA]["allowedTools"] == ["NEW"]
    assert "added" in out["projects"][PA]["mcpServers"]
    assert out["projects"][PB] == {"allowedTools": ["B-SENTINEL"]}, "another project was rewritten"
    assert "extraGlobalWrittenInBox" not in out, "a session-only global escaped into canonical"


def test_merge_out_is_fail_closed_on_a_bad_scratch(
    tmp_path: Path,
    write_json: Callable[[str, object], Path],
    write_file: Callable[[str, str], Path],
) -> None:
    original = {"projects": {PA: {"allowedTools": ["KEEP"]}}}
    canonical = write_json("c.json", original)
    bad = write_file("scr-bad.json", "{broken")
    assert cs.merge_out_json(str(bad), PA, str(canonical)) != cli.OK
    assert read(canonical) == original


def test_merge_out_refuses_to_overwrite_a_corrupt_canonical(
    write_file: Callable[[str, str], Path], write_json: Callable[[str, object], Path]
) -> None:
    corrupt = write_file("c.json", "{was corrupt")
    good = write_json("scr.json", {"projects": {PA: {"x": 1}}})
    assert cs.merge_out_json(str(good), PA, str(corrupt)) != cli.OK
    assert corrupt.read_text() == "{was corrupt"


def test_merge_out_creates_canonical_from_a_fresh_skeleton(
    tmp_path: Path, write_json: Callable[[str, object], Path]
) -> None:
    canonical = tmp_path / "fresh.json"
    scratch = write_json("scr.json", {"onboardingComplete": True, "projects": {PA: {"y": 2}}})
    assert cs.merge_out_json(str(scratch), PA, str(canonical)) == cli.OK
    out = read(canonical)
    assert out["projects"][PA] == {"y": 2}
    assert out["onboardingComplete"] is True


def test_merge_out_never_deletes_an_entry_the_session_lacks(
    write_json: Callable[[str, object], Path],
) -> None:
    """ "No entry" is indistinguishable from "the session config was reset" — deleting there
    would silently drop the project's approved tools, MCP servers and trust flags."""
    canonical = write_json("c.json", {"projects": {PA: {"allowedTools": ["KEEP"]}}})
    scratch = write_json("scr.json", {"projects": {}})
    assert cs.merge_out_json(str(scratch), PA, str(canonical)) == cli.OK
    assert read(canonical)["projects"][PA]["allowedTools"] == ["KEEP"]


def test_merge_out_never_exports_the_sandbox_pins(
    tmp_path: Path, write_json: Callable[[str, object], Path]
) -> None:
    """The pins are a sandbox behaviour, not the user's choice — canonical must stay stock."""
    canonical = tmp_path / "fresh.json"
    scratch = write_json(
        "scr.json",
        {"leftArrowOpensAgents": False, "onboardingComplete": True, "projects": {PA: {"z": 3}}},
    )
    cs.merge_out_json(str(scratch), PA, str(canonical))
    out = read(canonical)
    assert "leftArrowOpensAgents" not in out
    assert out["onboardingComplete"] is True


# ── history ──────────────────────────────────────────────────────
def test_seed_history_keeps_only_this_projects_lines(
    tmp_path: Path, write_file: Callable[[str, str], Path]
) -> None:
    src = write_file(
        "history.jsonl",
        hline(PA, "a-one")
        + "\n"
        + hline(PB, "b-SENTINEL")
        + "\ngarbage\n"
        + hline(PA, "a-two")
        + "\n",
    )
    dst = tmp_path / "sess-history.jsonl"
    cs.seed_history(str(src), PA, str(dst))
    got = dst.read_text()
    assert "a-one" in got and "a-two" in got
    assert "b-SENTINEL" not in got
    assert "garbage" not in got


def test_merge_history_appends_without_duplicating(write_file: Callable[[str, str], Path]) -> None:
    canonical = write_file(
        "canon.jsonl", hline(PA, "a-one") + "\n" + hline(PB, "b-SENTINEL") + "\n"
    )
    scratch = write_file("sess.jsonl", hline(PA, "a-one") + "\n" + hline(PA, "a-three") + "\n")
    cs.merge_history(str(scratch), PA, str(canonical))
    lines = canonical.read_text().splitlines()
    assert sum("a-three" in ln for ln in lines) == 1
    assert sum("a-one" in ln for ln in lines) == 1
    assert sum("b-SENTINEL" in ln for ln in lines) == 1


def test_merge_history_repairs_a_missing_trailing_newline(
    write_file: Callable[[str, str], Path],
) -> None:
    """A host `claude` killed mid-append leaves no trailing newline; gluing our first line
    onto its last would corrupt both."""
    torn = write_file("torn.jsonl", hline(PB, "b-TORN"))  # deliberately no "\n"
    scratch = write_file("sess.jsonl", hline(PA, "a-one") + "\n" + hline(PA, "a-two") + "\n")
    cs.merge_history(str(scratch), PA, str(torn))
    lines = [ln for ln in torn.read_text().splitlines() if ln]
    assert len(lines) == 3
    assert all(json.loads(ln) for ln in lines)


def test_merge_history_is_a_no_op_with_nothing_new(write_file: Callable[[str, str], Path]) -> None:
    canonical = write_file("canon.jsonl", hline(PA, "a-one") + "\n")
    scratch = write_file("sess.jsonl", hline(PA, "a-one") + "\n")
    cs.merge_history(str(scratch), PA, str(canonical))
    assert canonical.read_text() == hline(PA, "a-one") + "\n"


# ── classify (the drift canary) ──────────────────────────────────
def test_classify_flags_only_unrecognised_entries(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    home = tmp_path / "dotclaude"
    home.mkdir()
    for name in ("settings.json", "daemon.lock", "mystery.db"):
        (home / name).touch()
    for name in ("projects", "brand-new-store"):
        (home / name).mkdir()

    cs.classify(str(home))
    unknown = set(capsys.readouterr().out.split())
    assert {"brand-new-store", "mystery.db"} <= unknown
    assert not ({"settings.json", "projects", "daemon.lock"} & unknown)


def test_classify_on_a_missing_home_is_silent(tmp_path: Path) -> None:
    assert cs.classify(str(tmp_path / "nope")) == cli.OK


def test_cli_rejects_wrong_arity() -> None:
    with pytest.raises(cli.AbortError) as exc:
        cs.main(["scope-in-json", "only-one-arg"])
    assert exc.value.code == cli.USAGE


# ── host key vs box key (single mode) ────────────────────────────
# Single mode has no $PWD bind and $HOST_HOME is a symlink to the container home, so Claude's
# resolved cwd — and therefore every key it writes — is the CONTAINER path, not the host one.
# Canonical must still only ever hold the host key, or the host's --resume and ↑ history stop
# seeing the box's sessions and vice versa.
BOX = "/home/hostuser/proj-a"


def test_scope_in_rekeys_the_project_entry_to_the_box_path(
    tmp_path: Path, write_json: Callable[[str, object], Path]
) -> None:
    src = write_json(
        "canonical.json",
        {"projects": {PA: {"allowedTools": ["A"]}}, "githubRepoPaths": {"repo": [PA, PB]}},
    )
    dst = tmp_path / "session.json"
    cs.scope_in_json(str(src), PA, str(dst), BOX)
    out = read(dst)
    assert list(out["projects"]) == [BOX]
    assert out["projects"][BOX]["allowedTools"] == ["A"]
    assert out["githubRepoPaths"] == {"repo": [BOX]}


def test_merge_out_writes_the_box_entry_back_under_the_host_key(
    tmp_path: Path, write_json: Callable[[str, object], Path]
) -> None:
    scratch = write_json("session.json", {"projects": {BOX: {"allowedTools": ["NEW"]}}})
    canonical = write_json(
        "canonical.json", {"projects": {PA: {"allowedTools": ["OLD"]}, PB: {"keep": True}}}
    )
    assert cs.merge_out_json(str(scratch), PA, str(canonical), BOX) == cli.OK
    out = read(canonical)
    assert out["projects"][PA]["allowedTools"] == ["NEW"]
    assert BOX not in out["projects"], "the container path must never reach canonical"
    assert out["projects"][PB] == {"keep": True}


def test_a_fresh_canonical_is_seeded_without_the_box_key(
    tmp_path: Path, write_json: Callable[[str, object], Path]
) -> None:
    """The no-canonical path rebuilds from the session's globals, which are box-keyed."""
    scratch = write_json(
        "session.json", {"onboardingComplete": True, "projects": {BOX: {"allowedTools": ["A"]}}}
    )
    canonical = tmp_path / "fresh.json"
    assert cs.merge_out_json(str(scratch), PA, str(canonical), BOX) == cli.OK
    out = read(canonical)
    assert list(out["projects"]) == [PA]
    assert out["onboardingComplete"] is True


def test_history_round_trips_through_the_box_key(
    tmp_path: Path, write_file: Callable[[str, str], Path]
) -> None:
    canonical = write_file(
        "history.jsonl", hline(PA, "mine") + "\n" + hline(PB, "OTHER-PROJECT") + "\n"
    )
    seeded = tmp_path / "session-history.jsonl"
    cs.seed_history(str(canonical), PA, str(seeded), BOX)

    lines = [json.loads(ln) for ln in seeded.read_text().splitlines()]
    assert [ln["project"] for ln in lines] == [BOX], "the box sees only its own key"
    assert all(ln["display"] != "OTHER-PROJECT" for ln in lines)

    # The box appends under its own key; the merge must file it under the host's.
    with open(seeded, "a") as fh:
        fh.write(hline(BOX, "typed-in-the-box") + "\n")
    cs.merge_history(str(seeded), PA, str(canonical), BOX)

    back = [json.loads(ln) for ln in canonical.read_text().splitlines()]
    assert {ln["project"] for ln in back} == {PA, PB}, "no container path in canonical"
    assert [ln["display"] for ln in back if ln["project"] == PA] == ["mine", "typed-in-the-box"]


def test_merge_history_does_not_duplicate_a_seeded_line(
    tmp_path: Path, write_file: Callable[[str, str], Path]
) -> None:
    """Seeding re-keys every line, so the merge must re-key back and still match canonical's
    copy — otherwise every launch appends the whole history again."""
    canonical = write_file("history.jsonl", hline(PA, "mine") + "\n")
    seeded = tmp_path / "session-history.jsonl"
    cs.seed_history(str(canonical), PA, str(seeded), BOX)
    cs.merge_history(str(seeded), PA, str(canonical), BOX)
    assert len(canonical.read_text().splitlines()) == 1


def test_dedupe_survives_claudes_own_json_style(
    tmp_path: Path, write_file: Callable[[str, str], Path]
) -> None:
    """Claude writes history with JS `JSON.stringify` — no space after separators. Re-keying a
    line round-trips it through Python's dumps, so a RAW compare matched nothing and every
    launch re-appended the entire seeded history."""
    js_style = f'{{"display":"mine","project":"{PA}"}}'
    canonical = write_file("history.jsonl", js_style + "\n")
    seeded = tmp_path / "session-history.jsonl"
    cs.seed_history(str(canonical), PA, str(seeded), BOX)
    cs.merge_history(str(seeded), PA, str(canonical), BOX)
    assert canonical.read_text() == js_style + "\n", "canonical was appended to, or rewritten"
