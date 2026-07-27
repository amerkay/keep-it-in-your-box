# You are in a kib sandbox — rules for every session

## The box

- Docker container, non-root, **no `sudo`**, no `docker` binary or socket, no host processes.
  Nothing installed outside the project tree or `$CLAUDE_CONFIG_DIR` survives — the container is
  recreated once the last session for this project exits.
- `HOME` is `/home/hostuser`, but the project is bind-mounted at its **host** path, outside
  `$HOME`. Writes there land on the host for real.
- Host-side work (docker, `kib`, systemd, package installs) is the user's to run in a **host
  terminal**. `!` runs in *this container* and never reaches the host. Hand them a fenced block
  they can paste whole: no `!`, no `$` prompts, real paths, each command short and on its own
  line (or joined with `&&` / a trailing `\`).
- The clipboard is mediated, not free. Reads pass; a write reaches the host only as **plain text
  with control characters stripped** — verbatim, it would be host code execution at the user's
  next terminal paste. `wl-copy` works for text on both platforms; a non-text flavour fails by
  design and raises a desktop alert. Print anything a paste would mangle.
- **`←` does nothing** — the launcher pins `leftArrowOpensAgents: false` every launch. Never
  re-enable it, never tell the user to press it. From a foreground session it means "background
  this session", which aborts the in-flight Workflow and every subagent before forking — that
  work is structurally non-carryable — and mints a duplicate `--resume` entry. The agent view is
  still reachable: `claude agents`, `/background`, `--bg`.

## 🔴 Guarded paths — deliberate policy, not bugs. Not yours to bypass.

- **Redacted** — `.env`, `.env.*`, anything in `.kibignore`: reads return a stub, writes fail
  EACCES. Need a value? Ask. Placeholders (`.env.example`, `.sample`, `.template`, `.defaults`,
  `.dist`) are exempt and work normally — they hold no secrets.
- **Protected** — `.git/config`, `.git/hooks`, `.vscode/`, `.devcontainer/`, `.idea/`, `.envrc`,
  and submodule/worktree equivalents: reads work, writes fail EACCES. The **host** executes these
  later, so writing one is host code execution from in here. `git config` is content-checked:
  ordinary keys pass; `core.hooksPath`, `core.fsmonitor`, `core.sshCommand`, `core.pager`,
  `alias.*`, `filter.*.clean` are refused.
- **`~/.claude-shared/` — two tiers.** Everything under it auto-loads in every project's next
  session *and* in a host `claude`, so a write from one repo pivots into all of them.
  - **Locked — `plugins/`, `hooks/`** (read-only): these carry a `command` the **host** runs, so
    writing one is host code execution from in here. Installing still works — it lands
    per-project in `$CLAUDE_CONFIG_DIR`, the intended path, not a fallback. On EROFS, say that,
    and that sharing it needs every session for this project closed and, in a **host terminal**:
    `kib unlock-shared`.
  - **Open — `skills/`, `agents/`, `commands/`** (writable): prompt text, nothing auto-runs.
    Writes land in canonical `~/.claude` and load in **every** project from now on — **say so,
    naming the file, whenever you write one.** A bundled helper script is fine: it runs only if
    someone chooses to. A `hooks` or `mcpServers` **`command`** is not — parking one there
    demotes the whole tree to read-only from the next launch.

**On any EACCES/EROFS above, or a launch refused by the host's audit gate: stop and report it
verbatim, including what you were attempting.** Do not retry via another path, another tool,
another config scope (`--global`, `--system`), or by asking the user to disable the guard. A
legitimate need is a conversation, not a workaround.

## What persists

`$CLAUDE_CONFIG_DIR` is this project's private state and carries across launches. These rules are
not part of it and are not the user's memory — they mount read-only from outside the box. The
user's own `~/.claude/CLAUDE.md` is copied in fresh each launch, so `#` memory written to it in
here is transient; durable user memory has to be written from a host terminal. Project memory and
a repo's own `CLAUDE.md` persist normally.
