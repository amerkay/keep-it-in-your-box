"""The single `.kibignore` implementation — matcher AND gitignore emitter.

This suite carries the weight for three consumers at once: the FUSE guard, the launch-time
audit gate, and the `.gitignore` sync. One ruleset, so a case that passes in one context
can't silently diverge in another.
"""

from collections.abc import Callable
from pathlib import Path

import pytest

from kib.shared import rules

GUARD = Path(__file__).resolve().parent.parent.parent / "guest" / "policy" / "global.kibignore"


def guarded(project: str = "") -> list[rules.Rule]:
    """The shipped guard file plus a project rule set, in the order the FUSE server loads."""
    return rules.load(str(GUARD), guard=True) + rules.parse(project.splitlines())


# ── parsing ──────────────────────────────────────────────────────
def test_comments_and_blanks_are_dropped() -> None:
    assert rules.parse(["# a comment", "", "   ", "real"]) == [
        rules.Rule(False, "real", rules.BARE, rules.REDACT, False)
    ]


@pytest.mark.parametrize("unsafe", ["/etc/passwd", "../outside", "a/../b"])
def test_unsafe_rules_are_skipped(unsafe: str) -> None:
    """A leading '/' or a '..' component could escape the project root — never honour one."""
    assert rules.parse([unsafe]) == []


def test_anchor_follows_the_presence_of_a_slash() -> None:
    parsed = rules.parse(["bare", "dir/leaf"])
    assert [r.anchor for r in parsed] == [rules.BARE, rules.EXACT]


def test_negation_is_detached_before_anchoring() -> None:
    (rule,) = rules.parse(["!dir/keep"])
    assert rule.negated and rule.pattern == "dir/keep"


def test_load_of_a_missing_file_is_an_empty_rule_set() -> None:
    assert rules.load("/nonexistent/.kibignore") == []


# ── matching ─────────────────────────────────────────────────────
@pytest.mark.parametrize(
    "path",
    [
        ".env.example",
        ".env.sample",
        ".env.template",
        "newd/.env.example",
        "a/b/c/.env.sample",
        # The sibling an atomic writer actually creates. Without these the carve-out is
        # unusable: Edit/Write open `<target>.tmp.<pid>.<rand>` and rename, vim's writebackup
        # opens `<target>~`, and both fell back through into `.env.*` as EPERM.
        ".env.example.tmp.170.e4cc80fbd4d5",
        ".env.example.tmp.170.1753142400.1",
        ".env.example~",
        ".env.sample.tmp.4.beef",
        "a/b/.env.template~",
    ],
)
def test_env_placeholders_are_readable(path: str) -> None:
    """Committed by convention and holding no secrets — redacting them just breaks work."""
    assert rules.verdict(guarded(), path) is None


@pytest.mark.parametrize(
    "path",
    [
        ".env",
        ".env.local",
        ".env.production",
        "newd/.env",
        ".env.example.local",
        # The write-sibling carve-out is the temp SHAPE, never a prefix: `.env.example*` would
        # have re-admitted `.env.example.local` above, and the same shape on a secret-bearing
        # name stays redacted — a rename onto the real target is refused at the target anyway.
        ".env.tmp.170.abc",
        ".env.local.tmp.170.abc",
        ".env.local~",
        ".env.examples",
        ".env.example.bak",
        # Carried as placeholders and withdrawn (2026-07-27). Both spellings also hold real
        # per-environment values in the wild, and the exemption is a full-content read: a
        # wrong guess leaks a secret, where the other way costs one "ask the user".
        ".env.defaults",
        ".env.dist",
        ".env.default",
    ],
)
def test_secret_bearing_env_files_are_redacted(path: str) -> None:
    assert rules.verdict(guarded(), path) == rules.REDACT


@pytest.mark.parametrize(
    ("project_rule", "path"),
    [
        ("!.vscode", ".vscode/tasks.json"),
        ("!.vscode/tasks.json", ".vscode/tasks.json"),
        ("!.envrc", ".envrc"),
        ("!.gitmodules", ".gitmodules"),
    ],
)
def test_a_project_cannot_un_protect_itself(project_rule: str, path: str) -> None:
    """[protect] is immune to a project's '!' — it guards what the HOST later runs."""
    assert rules.verdict(guarded(project_rule), path) == rules.PROTECT


# ── the [redact] opt-out ─────────────────────────────────────────
# Unlike [protect], this tier withholds the user's own secrets from their own session, so the
# user may waive it per file. Every opt-out is printed at launch (report_kibignore_optouts).
@pytest.mark.parametrize(
    ("project_rule", "path"),
    [
        ("!.env", ".env"),
        ("!.env.local", ".env.local"),
        ("!.env.*", ".env.production"),
        ("!config/.env", "config/.env"),
    ],
)
def test_a_project_may_opt_out_of_redaction(project_rule: str, path: str) -> None:
    assert rules.verdict(guarded(project_rule), path) is None


@pytest.mark.parametrize(
    ("project_rule", "path"),
    [
        # The opt-out is per component, not a blanket switch: naming one .env file must not
        # hand over the rest of the family.
        ("!.env", ".env.local"),
        ("!.env.local", ".env"),
        # A '!' on an ancestor is about that directory, not about a guarded file inside it —
        # otherwise `!secrets` (or a bare `!*`) would un-redact every .env in the tree.
        ("!secrets", "secrets/.env"),
        ("!config", "config/.env"),
    ],
)
def test_an_opt_out_does_not_spill_past_the_rule(project_rule: str, path: str) -> None:
    assert rules.verdict(guarded(project_rule), path) == rules.REDACT


def test_redact_optouts_names_the_rules_the_launch_prints() -> None:
    guard = rules.load(str(GUARD), guard=True)
    project = rules.parse(["!.env", "!.vscode", "!build", "secrets"])
    # [protect] and unguarded names are inert, so reporting them would teach the user that
    # every negation un-guards something.
    assert rules.redact_optouts(guard, project) == [".env"]


def test_a_project_may_still_add_redaction_over_a_placeholder() -> None:
    assert rules.verdict(guarded(".env.example"), ".env.example") == rules.REDACT


@pytest.mark.parametrize(
    "path",
    [
        ".vscode/tasks.json",
        "deep/.vscode/settings.json",
        ".envrc",
        "a/b/.devcontainer/devcontainer.json",
    ],
)
def test_guard_patterns_are_tail_matched_at_any_depth(path: str) -> None:
    assert rules.verdict(guarded(), path) == rules.PROTECT


@pytest.mark.parametrize("path", [".claude/hooks/pre.sh", "sub/.claude/hooks/deep/x.sh"])
def test_claude_hooks_is_no_longer_protected(path: str) -> None:
    """Withdrawn 2026-08-01, and unlike .idea this is a correction rather than a hole.

    Nothing under .claude/hooks/ loads until a pointer names it and someone launches `claude` —
    a deliberate act a teardown report reaches in time — while every remaining [protect] entry
    fires on an ordinary commit, `cd` or editor-open. It is detected tree-wide instead, by
    kib.host.gitaudit (PROJECT_TREES + _since_stamp).
    """
    assert rules.verdict(guarded(), path) is None


@pytest.mark.parametrize("path", [".idea/workspace.xml", "sub/.idea/watcherTasks.xml"])
def test_idea_is_no_longer_guarded(path: str) -> None:
    """Withdrawn 2026-07-30: a [protect] EPERM under .idea/ broke `pnpm install` outright.

    The residual risk (run configurations, File Watchers) is stated in the guard file.
    """
    assert rules.verdict(guarded(), path) is None


@pytest.mark.parametrize("path", ["src/main.py", "README.md", ".github/workflows/ci.yml", "envrc"])
def test_unrelated_paths_pass_through(path: str) -> None:
    assert rules.verdict(guarded(), path) is None


def test_last_match_wins_and_negation_re_includes() -> None:
    parsed = rules.parse(["dir/*", "!dir/keep"])
    assert rules.verdict(parsed, "dir/secret") == rules.REDACT
    assert rules.verdict(parsed, "dir/keep") is None


def test_a_masked_parent_seals_everything_beneath_it() -> None:
    """git's parent-exclusion rule: no '!' can reach inside an already-masked directory."""
    assert rules.verdict(rules.parse(["secrets"]), "secrets/a/b") == rules.REDACT


def test_a_bare_rule_never_matches_inside_dot_git() -> None:
    assert rules.verdict(rules.parse(["build"]), ".git/build") is None


def test_glob_wildcards_never_cross_a_slash() -> None:
    assert rules.verdict(rules.parse(["*.pem"]), "certs/server.pem") == rules.REDACT
    assert rules.verdict(rules.parse(["a/*"]), "a/b/c") == rules.REDACT
    assert rules.verdict(rules.parse(["a/*.txt"]), "a/b/c.txt") is None


def test_matches_is_the_boolean_face_of_verdict() -> None:
    parsed = rules.parse(["secrets", "!secrets/ok"])
    assert rules.matches(parsed, "secrets") is True
    assert rules.matches(parsed, "other") is False


# ── the gitignore emitter (the third consumer) ───────────────────
@pytest.mark.parametrize(
    ("rule", "expected"),
    [
        ("secret.txt", "secret.txt"),  # bare name matches anywhere, as in gitignore
        ("dir/secret", "/dir/secret"),  # a '/'-containing rule anchors at the repo root
        ("!keep", "!keep"),
        ("!dir/keep", "!/dir/keep"),  # the anchoring '/' lands AFTER the '!'
        ("trailing/", "trailing"),  # the trailing slash is stripped BEFORE anchoring
    ],
)
def test_to_gitignore_translation(rule: str, expected: str) -> None:
    assert rules.to_gitignore(rules.parse([rule])) == [expected]


def test_to_gitignore_drops_the_unsafe_rules_the_matcher_drops() -> None:
    """The emitter and the matcher must agree on which rules exist at all."""
    assert rules.to_gitignore(rules.parse(["/abs", "../up", "ok"])) == ["ok"]


def test_to_gitignore_never_mirrors_a_redact_opt_out() -> None:
    """`!.env` in the managed block would re-include it past the repo's own `.env` line —
    opting the sandbox in to a .env must not opt git in to committing it."""
    guard = rules.load(str(GUARD), guard=True)
    project = rules.parse(["!.env", "dir/*", "!dir/keep"])
    assert rules.to_gitignore(project, guard) == ["/dir/*", "!/dir/keep"]


def test_to_gitignore_cli(
    tmp_path: Path, write_file: Callable[[str, str], Path], capsys: pytest.CaptureFixture[str]
) -> None:
    path = write_file(".kibignore", "secret\n!dir/keep\n!.env\n# note\n")
    assert rules.main(["to-gitignore", str(GUARD), str(path)]) == 0
    assert capsys.readouterr().out.splitlines() == ["secret", "!/dir/keep"]
