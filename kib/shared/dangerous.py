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
# env keys a *child process* turns into code execution: interpreter/loader hooks and command
# overrides. Shared settings.json loads in a HOST `claude` too, and its `env` is applied to
# every subprocess claude spawns — so BASH_ENV / NODE_OPTIONS / LD_PRELOAD here is host RCE at
# the next tool or git call, the same propagation path as apiKeyHelper. A denylist leaks by
# nature; this is the known-dangerous set, kept apart from benign prefs (EDITOR, PAGER) which a
# user legitimately sets. Names are case-sensitive — the OS only honours the exact spelling.
SETTINGS_ENV_EXEC_KEYS = (
    "BASH_ENV",
    "ENV",
    "PATH",
    "NODE_OPTIONS",
    "PYTHONSTARTUP",
    "PYTHONPATH",
    "PERL5OPT",
    "PERL5LIB",
    "RUBYOPT",
    "LD_PRELOAD",
    "LD_AUDIT",
    "LD_LIBRARY_PATH",
    "DYLD_INSERT_LIBRARIES",
    "DYLD_LIBRARY_PATH",
    "GIT_SSH",
    "GIT_SSH_COMMAND",
    "GIT_EXTERNAL_DIFF",
    "GIT_PROXY_COMMAND",
    "GIT_PAGER",
    "PROMPT_COMMAND",
)


def git_key_is_dangerous(key: str) -> bool:
    """True if a `section.sub.key` path names a command the host would execute."""
    parts = key.strip().lower().split(".")
    return bool(parts[0]) and (parts[0] in GIT_SECTIONS or parts[-1] in GIT_KEYS)


def _strip_inline_comment(s: str) -> str:
    """Drop a `#`/`;` comment, but honour double-quoted spans — git treats a comment char
    inside a quoted subsection or value as literal. A backslash escapes the next char in a
    quote. A naive `split('#')` truncates `[filter "a#b"]clean = x` into nothing; git keeps it.
    """
    out: list[str] = []
    in_q = False
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == "\\" and in_q and i + 1 < n:
            out.append(c + s[i + 1])
            i += 2
            continue
        if c == '"':
            in_q = not in_q
        elif c in "#;" and not in_q:
            break
        out.append(c)
        i += 1
    return "".join(out)


def _split_header(line: str) -> tuple[str, str]:
    """`line` starts with `[`. Return `(section_lower, rest_after_the_closing_bracket)`.

    The closing `]` is the first one OUTSIDE the quoted subsection — git's real grammar. A
    `partition(']')` splits at the first `]`, so a subsection name containing `]`
    (`[filter "e]v"]clean = x`) hides the key past the bracket; this walks quotes to find the
    true close, matching what git resolves.
    """
    in_q = False
    i, n = 1, len(line)
    while i < n:
        c = line[i]
        if c == "\\" and in_q and i + 1 < n:
            i += 2
            continue
        if c == '"':
            in_q = not in_q
        elif c == "]" and not in_q:
            head = line[1:i]
            return (head.split() or [""])[0].strip('"').lower(), line[i + 1 :].strip()
        i += 1
    return (line[1:].split() or [""])[0].strip('"').lower(), ""


def git_ini_entries(text: str) -> set[tuple[str, str, str]]:
    """The `(section, key, value)` triples in git-INI *text* that name a command.

    Used by the FUSE guard, which sees the candidate file before the rename that installs it,
    so it must read the file the way GIT will — not a naive approximation. Two grammar points
    a header-only parser misses, each a live bypass until fixed:

    * git resumes scanning after `]`, so `[core]hooksPath = x` on one line is a real setting;
    * a subsection name is double-quoted and may itself contain `]`, `#` or `;`, which do NOT
      end the header or start a comment (`[filter "e]v"]clean = payload` sets a clean driver).

    Quote-aware header and comment handling covers both.
    """
    found: set[tuple[str, str, str]] = set()
    section = ""
    for raw in text.splitlines():
        line = _strip_inline_comment(raw).strip()
        if not line:
            continue
        if line.startswith("["):
            section, line = _split_header(line)
            if not line:
                continue
        # A valueless key is git-legal (boolean true); keep it so a dangerous *section*
        # (include/alias/…) is caught even when its key carries no `=`.
        key, _, value = line.partition("=")
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
        bad += [f"env.{k} = {env[k]}" for k in SETTINGS_ENV_EXEC_KEYS if env.get(k)]

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
