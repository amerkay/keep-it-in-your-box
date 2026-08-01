""" "This value is a command the host runs" — the one place that idea is defined.

Two key tables, because the two file formats are genuinely different, one scanner each, plus a
generic JSON walk (`json_commands`) for the schemas that have no table — `.mcp.json`,
`.zed/settings.json`, and a skill's own bundled config:

* **git INI** (`.git/config`, `git config --list` output). A sandbox that can set
  `core.fsmonitor` has host code execution at the next bare `git status`, before the user
  reads a single diff.
* **settings.json**. `hooks[].command` and `apiKeyHelper` are the same class one layer up:
  `~/.claude/settings.json` loads in every project's next session *and* in a host `claude`,
  so one poisoned session reaches all of them.

Everything deciding "is this key dangerous" imports from here — the FUSE write validator, the
audit gate, settings validation. Never write a second copy of either table — they drift.

Matching is on the key's LAST component, so `filter.lfs.clean` matches on `clean`.
Over-matching costs exactly one refused write, which is the right side to err on.
"""

from __future__ import annotations

from collections.abc import Sequence
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

# Characters on which Python's line splitting and git's disagree, checked AFTER git's own
# normalisation (leading BOM dropped, CRLF folded). Each one lets a header break for
# `str.splitlines()` while git reads a single line — or the reverse — which hides a live key
# from the validator. No real config needs any of them, so their presence is itself the verdict.
_AMBIGUOUS = frozenset("\ufeff\r\v\f\x1c\x1d\x1e\x85\u2028\u2029")
#: Stands in for "this file cannot be parsed unambiguously". Callers refuse any non-empty
#: result, so falling closed needs no second verdict — only a triple they can name in a log.
AMBIGUOUS_ENTRY = ("<file>", "<ambiguous line separator>", "")

# settings.json keys whose value Claude runs as a command. The auth helpers are one per
# backend and four of them are the injection sinks of CVE-2026-35022, so a denylist missing
# any single one is a live path on a host configured for that backend (gcpAuthRefresh ↔
# Vertex AI). Add them as a family, never one spelling at a time.
SETTINGS_COMMAND_KEYS = (
    "apiKeyHelper",
    "awsAuthRefresh",
    "awsCredentialExport",
    "gcpAuthRefresh",
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
    # The whole DYLD family, not just the two obvious ones: framework/fallback/versioned are
    # the same dylib hijack against any non-hardened host binary (a brew/nvm `node`), and dyld
    # only strips them for SIP-protected ones.
    "DYLD_INSERT_LIBRARIES",
    "DYLD_LIBRARY_PATH",
    "DYLD_FRAMEWORK_PATH",
    "DYLD_FALLBACK_LIBRARY_PATH",
    "DYLD_FALLBACK_FRAMEWORK_PATH",
    "DYLD_VERSIONED_LIBRARY_PATH",
    "DYLD_VERSIONED_FRAMEWORK_PATH",
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


def _entries_in(lines: list[str]) -> set[tuple[str, str, str]]:
    """The dangerous triples in an already-split, already-normalised line list."""
    found: set[tuple[str, str, str]] = set()
    section = ""
    for raw in lines:
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


def git_ini_entries(text: str) -> set[tuple[str, str, str]]:
    """The `(section, key, value)` triples in git-INI *text* that name a command.

    Used by the FUSE guard, which sees the candidate file before the rename that installs it,
    so it must read the file the way GIT will — not a naive approximation. Three points a
    naive parser misses, each a live bypass until fixed:

    * git resumes scanning after `]`, so `[core]hooksPath = x` on one line is a real setting;
    * a subsection name is double-quoted and may itself contain `]`, `#` or `;`, which do NOT
      end the header or start a comment (`[filter "e]v"]clean = payload` sets a clean driver);
    * git NORMALISES its input first — it drops a leading UTF-8 BOM and ends a line at `\\n`
      only. `str.strip()` leaves a BOM in place (it is not whitespace) and `str.splitlines()`
      also breaks on `U+2028/2029/0085`, VT, FF and FS/GS/RS. Either divergence hides a key
      from this parser that git still resolves — a BOM before `[core]fsmonitor=x`, or a
      separator inside a quoted subsection name.

    Normalisation matches git; anything still ambiguous after it is parsed BOTH ways and
    refused outright, so the *class* is closed rather than the two known spellings.
    """
    if text.startswith("\ufeff"):
        text = text[1:]  # git drops exactly one leading BOM, and only at the start of the file
    text = text.replace("\r\n", "\n")  # git folds CRLF; a LONE \r stays ambiguous below
    found = _entries_in(text.split("\n"))  # how git reads it
    if _AMBIGUOUS.intersection(text):
        found |= _entries_in(text.splitlines())  # ...and how a Unicode reader would
        found.add(AMBIGUOUS_ENTRY)  # either way, refuse: no legitimate config needs these
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


#: JSON keys whose string value is a command the host will run. Walked generically rather than
#: per-schema, so one function covers `.mcp.json`'s `mcpServers.*.command`, zed's
#: `formatter.external.command` and `terminal.shell.program`, and whatever key either adds next.
JSON_EXEC_KEYS = ("command", "program")

#: Keys below which a `command` is AUTO-run — nobody decides to run it, it fires when `claude`
#: starts. This is the arming set for the shared-asset scanner (`armed=False`), and the line it
#: draws is auto-execution, not executability: a bundled helper script runs only if the agent
#: reads the skill and chooses to. `experimental` is included because `experimental.monitors` is
#: where monitors are declared today and the wrapper is the part that will outlive the spelling.
AUTO_RUN_KEYS = ("hooks", "mcpServers", "lspServers", "monitors", "experimental")


def json_commands(
    node: object, *, arm: Sequence[str] = (), trail: str = "", armed: bool = True
) -> list[str]:
    """Every nested command-valued string in a JSON tree, as `where = value` lines.

    Two callers, one walk — this used to be written twice (the asset scanner and the audit
    gate), in a module whose whole contract is that "is this a command" is defined once.

    `arm` is what separates them. Empty (the audit gate) reports every `command`/`program` it
    finds. Non-empty (the asset scanner, `arm=("hooks", "mcpServers")`) starts DISARMED and
    reports only below one of those keys: a skill's own prose may well mention a `command`, and
    flagging that trains the user to ignore the warning that matters.
    """
    found: list[str] = []
    if isinstance(node, dict):
        for key, value in node.items():
            where = f"{trail}.{key}" if trail else str(key)
            if armed and key in JSON_EXEC_KEYS and isinstance(value, str) and value.strip():
                found.append(f"{where} = {value.strip()}")
            else:
                found += json_commands(value, arm=arm, trail=where, armed=armed or key in arm)
    elif isinstance(node, list):
        for i, value in enumerate(node):
            found += json_commands(value, arm=arm, trail=f"{trail}[{i}]", armed=armed)
    return found
