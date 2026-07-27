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

## The credential broker

- **The credentials you can see here are placeholders, deliberately.** `CLAUDE_CODE_OAUTH_TOKEN`
  is a `fake_value_…` sentinel, `.credentials.json` is synthetic and read-only, and
  `ANTHROPIC_BASE_URL` points at `kib-broker`. A host-side sidecar holds the real token and
  injects it on the way out. Nothing here is broken and nothing needs repairing — never try to
  re-authenticate, refresh a token, or "fix" a base URL.
- **A brokered MCP is a header-free URL** — `http://kib-broker:8100/mcp/<name>…`, or its own
  sidecar alias for a locally-run one. Entries marked `_kibBroker` are kib's and are rewritten
  every launch; never add a header or token to one, and never point one at a real upstream.
- **`~/.keep-it-in-your-box/` is not mounted here.** It holds those credentials and the route
  definitions that govern them, so a session cannot rewrite its own brokering. There is no
  provider file for you to edit and no port for you to choose.
- **To add a service's MCP, hand the user one command — never author a definition, never ask
  for a secret value.** In a **host terminal**: `kib broker add` asks the questions, or
  `kib broker add <name> --url <https-url> --header "Authorization: Bearer"` for a remote one
  (`--run "<cmd>" --cred-env <ENV>` for a local one). It prompts for the credential itself,
  hidden, and prints the URL the next session will get. `kib broker status` lists every route.

## 🔴 Guarded paths — deliberate policy, not bugs. Not yours to bypass.

- **Redacted** — `.env`, `.env.*`, anything in `.kibignore`: writes are refused, and a read gives
  you the **key names with every value replaced** (`KEY=<redacted>`) for JSON and `.env*` files, a
  flat stub for anything else. So you can see which settings exist — you can add a key, or tell
  the user which one is missing — but never a value. Need one? Ask. Exactly three placeholder
  spellings are exempt and work normally: `.env.example`, `.env.sample`, `.env.template`. Any
  other `.env.*` is redacted, including `.env.defaults` and `.env.dist` — they hold real values
  often enough that the exemption was withdrawn.
- **Protected** — `.git/config`, `.git/hooks` (+ submodule/worktree equivalents), `.githooks/`,
  `.gitmodules`, `.vscode/`, `.devcontainer/`, `.idea/`, `.envrc`, `.claude/hooks/`,
  `.cursor/mcp.json`, `.zed/tasks.json`, `.zed/debug.json`, `.run/`, `.mvn/jvm.config`, `.exrc`,
  `.nvim.lua`, `.ripgreprc`, `.yarnrc.yml`: reads work, writes are refused. The **host** executes
  these later, so writing one is host code execution from in here. `git config` is content-checked:
  ordinary keys pass; `core.hooksPath`, `core.fsmonitor`, `core.sshCommand`, `core.pager`,
  `alias.*`, `filter.*.clean` are refused.
- **Editable, but watched** — `.claude/settings*.json`, `.mcp.json`, `.zed/settings.json`,
  `.cargo/config.toml`, `mise.toml`, `.pre-commit-config.yaml`. These carry ordinary settings too,
  so you may write them. If you add a key naming a **command** (a hook, an MCP `command`, a
  `rustc-wrapper`, a mise `[hooks]` entry), say so plainly in your reply — the host's audit gate
  reports it at teardown, and the user should hear it from you first, not from a warning.
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

**On any refusal above, or a launch refused by the host's audit gate: stop and report it
verbatim, including what you were attempting.** Do not retry via another path, another tool,
another config scope (`--global`, `--system`), or by asking the user to disable the guard. A
legitimate need is a conversation, not a workaround.

**`EPERM` inside the project is kib refusing, and the path is the whole message** — the reason is
logged where you cannot see it (the FUSE sidecar's stderr, a different container), so do not
speculate about the cause beyond the rules above. `EACCES` is an ordinary permission problem:
check the mode and owner, and treat it as a normal error. `EROFS` is a read-only mount, which
under `~/.claude-shared/` means the locked tier.

## What persists

`$CLAUDE_CONFIG_DIR` is this project's private state and carries across launches. These rules are
not part of it and are not the user's memory — they mount read-only from outside the box. The
user's own `~/.claude/CLAUDE.md` is copied in fresh each launch, so `#` memory written to it in
here is transient; durable user memory has to be written from a host terminal. Project memory and
a repo's own `CLAUDE.md` persist normally.
