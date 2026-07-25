""" "This value is a command the host runs" — the one place that idea is defined.

Two tables, because the two file formats are genuinely different, and one scanner each:

* **git INI** (`.git/config`, `git config --list` output). A sandbox that can set
  `core.fsmonitor` has host code execution at the next bare `git status`, before the user
  reads a single diff.
* **settings.json**. `hooks[].command` and `apiKeyHelper` are the same class one layer up:
  `~/.claude/settings.json` loads in every project's next session *and* in a host `claude`,
  so one poisoned session reaches all of them.

Everything deciding "is this key dangerous" imports from here — the FUSE write validator, the
audit gate, settings validation. Both tables were written down twice before, and drifted.

Matching is on the key's LAST component, so `filter.lfs.clean` matches on `clean`.
Over-matching costs exactly one refused write, which is the right side to err on.
"""

from typing import Any

# Last-component matches. Every entry names a value git will execute or hand to a shell.
GIT_KEYS = frozenset(
    """hookspath fsmonitor sshcommand pager editor askpass gitproxy external textconv
    command driver clean smudge process helper templatedir program cmd variant
    packobjectshook uploadpack receivepack update difffilter defaultkeycommand""".split()
)
# Whole-section matches. include/includeIf point git at *another* config file which may then
# declare any key above — the validator only ever sees the file in front of it, so the
# indirection is the bypass and a newly added include is refused outright.
GIT_SECTIONS = frozenset({"alias", "pager", "include", "includeif"})

# settings.json keys whose value Claude runs as a command.
SETTINGS_COMMAND_KEYS = (
    "apiKeyHelper",
    "awsAuthRefresh",
    "awsCredentialExport",
    "otelHeadersHelper",
)
# settings.json env keys that redirect the agent's auth traffic or hand over its credential.
SETTINGS_ENV_KEYS = ("ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN")


def git_key_is_dangerous(key: str) -> bool:
    """True if a `section.sub.key` path names a command the host would execute."""
    parts = key.strip().lower().split(".")
    return bool(parts[0]) and (parts[0] in GIT_SECTIONS or parts[-1] in GIT_KEYS)


def git_ini_entries(text: str) -> set[tuple[str, str, str]]:
    """The `(section, key, value)` triples in git-INI *text* that name a command.

    Used by the FUSE guard, which sees the candidate file before the rename that installs
    it. Git's parser resumes scanning after `]`, so `[core]hooksPath = x` on a single line
    is a valid setting — keep the remainder of the line instead of dropping it, which is
    the one-line form a header-only parser used to miss.
    """
    found: set[tuple[str, str, str]] = set()
    section = ""
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].split(";", 1)[0].strip()
        if not line:
            continue
        if line.startswith("["):
            # '[filter "lfs"]' → 'filter'; a subsection name is not a key.
            head, _, rest = line[1:].partition("]")
            section = (head.split() or [""])[0].strip('"').lower()
            line = rest.strip()
            if not line:
                continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip().lower()
        if section in GIT_SECTIONS or key.split(".")[-1] in GIT_KEYS:
            found.add((section, key, value.strip()))
    return found


def git_listing_lines(listing: str) -> list[str]:
    """The lines of `git config --list` output whose key is dangerous.

    Used by the audit gate, which asks git to resolve the config rather than parsing a
    file — that is what makes it see through `include.path` indirection.
    """
    return [line for line in listing.splitlines() if git_key_is_dangerous(line.split("=", 1)[0])]


def settings_findings(cfg: dict[str, Any]) -> list[str]:
    """`key = value` lines for every settings.json entry that runs a command.

    Inline `hooks[].command` is the one that matters most: it is exactly how a poisoned
    settings.json bypasses the read-only `hooks/` directory, the same way `core.hooksPath`
    bypassed a read-only `.git/hooks`.
    """
    bad = [f"{k} = {cfg[k]}" for k in SETTINGS_COMMAND_KEYS if cfg.get(k)]

    env = cfg.get("env")
    if isinstance(env, dict):
        bad += [f"env.{k} = {env[k]}" for k in SETTINGS_ENV_KEYS if env.get(k)]

    status_line = cfg.get("statusLine")
    if isinstance(status_line, dict) and status_line.get("command"):
        bad.append(f"statusLine.command = {status_line['command']}")

    # {"PreToolUse": [{"hooks": [{"command": "..."}]}]}
    hooks = cfg.get("hooks")
    if isinstance(hooks, dict):
        for event, matchers in hooks.items():
            for matcher in matchers if isinstance(matchers, list) else []:
                entries = (matcher.get("hooks") or []) if isinstance(matcher, dict) else []
                for hook in entries:
                    if isinstance(hook, dict) and hook.get("command"):
                        bad.append(f"hooks.{event}[].command = {hook['command']}")
    return bad
