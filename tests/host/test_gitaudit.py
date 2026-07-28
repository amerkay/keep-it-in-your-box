"""The audit gate that replaced the auto-installed pre-commit hook.

Two severities and the split between them is the design: refuse on a host-executed git config
key or a nested executable hook, warn on a tracked path that matches `.kibignore`. Every case
below runs against a real git repository, because the thing being tested is partly git's own
resolution (`--includes`, gitfile redirects, bare layouts).
"""

import subprocess
from collections.abc import Callable
from pathlib import Path

import pytest

from kib.host import gitaudit
from kib.shared import cli


def git(repo: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True)


def nested_hooks(path: Path) -> Path:
    """Init a nested repo and return its hooks dir, created.

    The container sets `GIT_TEMPLATE_DIR=` (so a `git clone` in the box does not have to create
    a `.git/hooks` the guard refuses), which means git makes no hooks dir at all — and these
    tests are about what the audit finds in one.
    """
    subprocess.run(["git", "init", "-q", str(path)], check=True, capture_output=True)
    hooks = path / ".git" / "hooks"
    hooks.mkdir(parents=True, exist_ok=True)
    return hooks


def test_a_clean_repo_has_no_findings(git_repo: Callable[..., Path]) -> None:
    repo = git_repo("clean")
    assert not gitaudit.audit(str(repo)).any


@pytest.mark.parametrize(
    ("key", "value"),
    [
        ("core.hooksPath", "/tmp/evilhooks"),
        ("core.fsmonitor", "/tmp/fsm.sh"),
        ("core.sshCommand", "/tmp/x.sh"),
        ("core.pager", "/tmp/x.sh"),
        ("alias.pwn", "!/tmp/x.sh"),
        ("filter.pwn.clean", "echo pwn"),
        ("include.path", "evil.inc"),
    ],
)
def test_a_host_executed_config_key_is_refuse_class(
    git_repo: Callable[..., Path], key: str, value: str
) -> None:
    repo = git_repo("poisoned")
    git(repo, "config", "--local", key, value)
    findings = gitaudit.audit(str(repo))
    assert findings.refuse
    assert any(key.split(".")[-1].lower() in line.lower() for line in findings.config)


def test_the_users_own_global_config_is_not_flagged(git_repo: Callable[..., Path]) -> None:
    """`--local` is deliberate: the unscoped form would pull in ~/.gitconfig's core.pager
    and flag every repo on the machine."""
    repo = git_repo("plain")
    assert gitaudit.audit_git_config(str(repo)) == []


def test_a_bare_repo_nested_in_the_project_is_found(
    git_repo: Callable[..., Path], tmp_path: Path
) -> None:
    """A bare repo is an ordinary directory to `git config --local`, but the host still runs
    what it configures."""
    top = git_repo("top")
    bare = top / "vendor" / "store.git"
    bare.parent.mkdir(parents=True)
    subprocess.run(["git", "init", "-q", "--bare", str(bare)], check=True, capture_output=True)
    subprocess.run(
        ["git", "config", "--file", str(bare / "config"), "core.hooksPath", "/tmp/e"],
        check=True,
        capture_output=True,
    )
    findings = gitaudit.audit(str(top))
    assert findings.refuse
    assert any("hookspath" in line.lower() for line in findings.config)


def test_an_executable_hook_in_a_nested_git_dir_is_refuse_class(
    git_repo: Callable[..., Path],
) -> None:
    top = git_repo("outer")
    hook = nested_hooks(top / "sub") / "pre-commit"
    hook.write_text("#!/bin/sh\necho hi\n")
    hook.chmod(0o755)
    findings = gitaudit.audit(str(top))
    assert findings.refuse
    assert any("pre-commit" in p for p in findings.hooks)


def test_the_top_level_hooks_dir_is_left_alone(git_repo: Callable[..., Path]) -> None:
    """It is the user's own, and kib bind-mounts it read-only. Only nested ones are the gap."""
    repo = git_repo("mine")
    hooks = repo / ".git" / "hooks"
    hooks.mkdir(exist_ok=True)  # GIT_TEMPLATE_DIR= means git creates none
    hook = hooks / "pre-commit"
    hook.write_text("#!/bin/sh\n")
    hook.chmod(0o755)
    assert gitaudit.audit_nested_hooks(str(repo)) == []


def test_sample_hooks_are_ignored(git_repo: Callable[..., Path]) -> None:
    top = git_repo("outer2")
    sample = nested_hooks(top / "sub") / "pre-commit.sample"
    sample.write_text("#!/bin/sh\n")
    sample.chmod(0o755)
    assert gitaudit.audit_nested_hooks(str(top)) == []


def test_a_tracked_hidden_path_is_warn_class_not_refuse(git_repo: Callable[..., Path]) -> None:
    """Your own hygiene — naming it is right, blocking a session over it would be hostile."""
    repo = git_repo("tracked")
    (repo / ".kibignore").write_text("secrets.txt\n")
    (repo / "secrets.txt").write_text("value\n")
    git(repo, "add", "-A")
    findings = gitaudit.audit(str(repo))
    assert findings.tracked == ["secrets.txt"]
    assert not findings.refuse


def test_no_rule_file_means_no_tracked_findings(git_repo: Callable[..., Path]) -> None:
    repo = git_repo("norules")
    (repo / "secrets.txt").write_text("value\n")
    git(repo, "add", "-A")
    assert gitaudit.audit_tracked(str(repo)) == []


# ── mixed-use project config: warn on change, never refuse ───────
def write(repo: Path, rel: str, body: str) -> None:
    (repo / rel).parent.mkdir(parents=True, exist_ok=True)
    (repo / rel).write_text(body)


@pytest.mark.parametrize(
    ("rel", "body", "needle"),
    [
        (".claude/settings.json", '{"apiKeyHelper": "/tmp/x.sh"}', "apiKeyHelper"),
        (
            ".claude/settings.local.json",
            '{"hooks":{"PreToolUse":[{"hooks":[{"command":"/tmp/x.sh"}]}]}}',
            "command",
        ),
        (".mcp.json", '{"mcpServers":{"e":{"command":"/tmp/x.sh"}}}', "mcpServers.e.command"),
        (".zed/settings.json", '{"terminal":{"shell":{"program":"/tmp/x.sh"}}}', "program"),
        (".cargo/config.toml", "[build]\nrustc-wrapper = /tmp/x.sh\n", "rustc-wrapper"),
        ("mise.toml", "[hooks]\nenter = /tmp/x.sh\n", "hooks"),
        (".pre-commit-config.yaml", "repos:\n- repo: local\n  hooks:\n  - entry: x\n", "entry"),
        ("sub/.claude/settings.json", '{"apiKeyHelper": "/tmp/x.sh"}', "apiKeyHelper"),
    ],
)
def test_uncommitted_project_config_is_warn_class(
    git_repo: Callable[..., Path], rel: str, body: str, needle: str
) -> None:
    """These files are mixed-use — the FUSE guard leaves them writable on purpose, so this
    is the only place they are seen at all. Warn, because refusing would fire on repos that
    legitimately ship one."""
    repo = git_repo("proj")
    write(repo, rel, body)
    findings = gitaudit.audit(str(repo))
    assert not findings.refuse
    assert any(rel in line and needle in line for line in findings.project)


def test_a_committed_project_config_is_not_reported(git_repo: Callable[..., Path]) -> None:
    """The audit sees state, not change. Dirty-or-untracked is the proxy for "this session
    touched it" — a committed config is the user's own and warning about it every launch
    would train them to ignore the warning."""
    repo = git_repo("committed")
    write(repo, ".mcp.json", '{"mcpServers":{"e":{"command":"/tmp/x.sh"}}}')
    git(repo, "add", "-A")
    git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "add mcp")
    assert gitaudit.audit_project_configs(str(repo)) == []


def test_a_benign_project_config_is_not_reported(git_repo: Callable[..., Path]) -> None:
    repo = git_repo("benign")
    write(repo, ".claude/settings.json", '{"model": "opus", "theme": "dark"}')
    write(repo, "mise.toml", '[tools]\nnode = "22"\n')
    assert gitaudit.audit_project_configs(str(repo)) == []


def test_a_mise_task_is_not_reported(git_repo: Callable[..., Path]) -> None:
    """A task runs when the user invokes it by name — the same "someone chose to" line the
    shared-assets tier draws. [hooks] fires on a bare `cd`, with no such decision."""
    repo = git_repo("tasks")
    write(repo, "mise.toml", '[tasks.build]\nrun = "cargo build"\n')
    assert gitaudit.audit_project_configs(str(repo)) == []


def test_project_findings_exit_fail_not_refused(git_repo: Callable[..., Path]) -> None:
    repo = git_repo("projexit")
    write(repo, ".mcp.json", '{"mcpServers":{"e":{"command":"/tmp/x.sh"}}}')
    assert gitaudit.main(["--top", str(repo), "--mode", "launch"]) == cli.FAIL


def test_a_malformed_project_config_is_silent(git_repo: Callable[..., Path]) -> None:
    """Claude ignores an unparseable settings file anyway; this tier warns about what it can
    prove, and a parse error proves nothing."""
    repo = git_repo("malformed")
    write(repo, ".claude/settings.json", "{not json")
    assert gitaudit.audit_project_configs(str(repo)) == []


def test_deeply_nested_json_does_not_crash_the_audit(git_repo: Callable[..., Path]) -> None:
    """`[`×30000 is 60 KB of VALID json that overflows the decoder. Uncaught, a repo could
    deny its own launch by committing one file — in the check meant to survive repo content."""
    repo = git_repo("deep")
    write(repo, ".mcp.json", "[" * 30_000 + "]" * 30_000)
    assert gitaudit.audit_project_configs(str(repo)) == []
    assert gitaudit.main(["--top", str(repo), "--mode", "launch"]) == cli.OK


def test_a_renamed_path_does_not_shift_the_rest(git_repo: Callable[..., Path]) -> None:
    """A rename entry carries a second NUL-separated path; unconsumed, the origin reads as
    the next entry's status field and every later path loses three characters."""
    repo = git_repo("renamed")
    write(repo, "a.txt", "x\n")
    git(repo, "add", "-A")
    git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "a")
    git(repo, "mv", "a.txt", "b.txt")
    write(repo, ".mcp.json", '{"mcpServers":{"e":{"command":"/tmp/x.sh"}}}')
    git(repo, "add", "-A")
    assert any(".mcp.json" in line for line in gitaudit.audit_project_configs(str(repo)))


def test_prune_dirs_are_not_walked(git_repo: Callable[..., Path]) -> None:
    """node_modules is thousands of directories and can hold nothing we care about."""
    top = git_repo("pruned")
    hook = nested_hooks(top / "node_modules" / "pkg") / "pre-commit"
    hook.write_text("#!/bin/sh\n")
    hook.chmod(0o755)
    assert gitaudit.audit_nested_hooks(str(top)) == []


# ── exit codes: what bash branches on ────────────────────────────
def test_launch_mode_exits_refused(git_repo: Callable[..., Path]) -> None:
    repo = git_repo("refuse")
    git(repo, "config", "--local", "core.fsmonitor", "/tmp/fsm.sh")
    assert gitaudit.main(["--top", str(repo), "--mode", "launch"]) == cli.REFUSED


def test_report_mode_also_returns_refused_but_the_caller_does_not_die(
    git_repo: Callable[..., Path],
) -> None:
    repo = git_repo("report")
    git(repo, "config", "--local", "core.fsmonitor", "/tmp/fsm.sh")
    assert gitaudit.main(["--top", str(repo), "--mode", "report"]) == cli.REFUSED


def test_warn_only_findings_exit_fail_not_refused(git_repo: Callable[..., Path]) -> None:
    repo = git_repo("warnonly")
    (repo / ".kibignore").write_text("secrets.txt\n")
    (repo / "secrets.txt").write_text("v\n")
    git(repo, "add", "-A")
    assert gitaudit.main(["--top", str(repo), "--mode", "launch"]) == cli.FAIL


def test_clean_repo_exits_ok(git_repo: Callable[..., Path]) -> None:
    assert gitaudit.main(["--top", str(git_repo("ok")), "--mode", "launch"]) == cli.OK


def test_a_non_repo_is_a_silent_no_op(tmp_path: Path) -> None:
    plain = tmp_path / "notarepo"
    plain.mkdir()
    assert gitaudit.main(["--top", str(plain), "--mode", "launch"]) == cli.OK


def test_report_names_the_remedy(
    git_repo: Callable[..., Path], capsys: pytest.CaptureFixture[str]
) -> None:
    repo = git_repo("remedy")
    git(repo, "config", "--local", "core.hooksPath", "/tmp/e")
    gitaudit.main(["--top", str(repo), "--mode", "launch"])
    err = capsys.readouterr().err
    assert "git config --local --unset" in err


def test_git_helper_survives_a_missing_binary(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """An OSError from subprocess must read as "no findings", never as a traceback: a host
    without git still has to be able to launch."""

    def boom(*args: object, **kwargs: object) -> None:
        raise OSError("no git here")

    monkeypatch.setattr(subprocess, "run", boom)
    assert gitaudit._git(["config", "--list"], str(tmp_path)) == ""
