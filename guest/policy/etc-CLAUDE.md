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
- **To add a brokered service, hand the user one command — never author a definition, never ask
  for a secret value.** In a **host terminal**: `kib broker add` asks the questions, or
  `kib broker add <name> --url <https-url> --header "Authorization: Bearer"` for a static
  credential, `--oauth [--scope <scope>]` for a service that only issues expiring OAuth 2.0
  tokens (the broker mints and re-mints them; the client secret never comes in here). Suggest
  `--allow-path <prefix>` for each path set the service needs — without it the route may reach
  every path on that host. Add `--mcp-name <name>` only if the upstream really is an MCP server;
  without it the route is REST and you reach it with curl. It prompts for the credential itself,
  hidden, and prints the URL the next session will get. `kib broker status` lists every route.

## 🔴 Guarded paths — deliberate policy, not bugs. Not yours to bypass.

- **Redacted** — `.env`, `.env.*`, anything in `.kibignore`: writes are refused, and a read gives
  you the **key names with every value replaced** (`KEY=<redacted>`) whenever the file parses as
  dotenv, JSON or YAML — **by shape, never by name**, so `env_vars/env_prod` and
  `sls_config/env-dev.yml` render the same as `.env` does. Anything no parser can vouch for
  keeps the flat stub, and a file that is *partly* one of these shapes is refused rather than
  half-rendered. So you can see which settings exist — you can add a key, or tell
  the user which one is missing — but never a value. Need one? Ask. Exactly three placeholder
  spellings are exempt and work normally — `.env.example`, `.env.sample`, `.env.template` — each
  along with the write siblings an editor makes *of it* (`<name>.tmp.*`, `<name>~`), so Edit and
  vim can save one. Any other `.env.*` is redacted, including `.env.defaults`, `.env.dist` and
  `.env.example.local` — they hold real values often enough that the exemption was withdrawn.
  - **Writing a `.kibignore`: the syntax is gitignore-*shaped*, not gitignore.** A **bare name**
    is the match-anywhere form — `*.pem` covers every depth, `_dev_data` seals that directory
    wherever it appears. A rule containing `/` is anchored at the project **root** and matches
    that **exact** number of components; `*` never crosses a `/`, and a `**` segment is just
    another spelling of one segment — so `**/*.pem` covers `a/k.pem` and nothing else, neither
    `k.pem` nor `a/b/k.pem`. Drop the `**/` and write the bare name. A leading `/` or a `..` is
    dropped as unsafe. `!` re-includes and the last match wins, but a matched **directory seals
    everything below it**: `secrets` + `!secrets/README.md` still redacts the README — write
    `secrets/*` + `!secrets/README.md`. A `[protect]`/`[redact]` heading belongs to kib's own
    guard file — in a project's file it is read as a pattern, not a section.
  - **`!.env` is a real opt-out, and it is the USER's to ask for.** A `!` on the same path
    component cancels the redaction above, so `!.env` in the project's `.kibignore` hands you
    that file in full from the next container on. It is for a `.env` that holds no secrets —
    ports, feature flags, a local URL. **Never write one to get past a redaction you have run
    into**; that is the "ask the user" case, and every opt-out is printed at each launch with
    the user reading it. `!` still cannot touch the Protected tier below: `!.vscode` does
    nothing.
  - **It is read once, when the container is created**, so say this whenever you write one: the
    live layer keeps enforcing the OLD rules for the rest of the session, and the next `kib`
    **refuses to attach** until every session for this project is closed and the container
    recreated. That next launch also names any **already-tracked** file the rules match, since
    hiding a file from the sandbox does nothing about a copy already in git — the user has to
    `git rm --cached` them. Nothing is written to `.gitignore` on their behalf; if untracked
    matches should stay out of git too, say so and let them add the lines.
- **Protected** — `.git/config`, `.git/hooks` (+ submodule/worktree equivalents), `.githooks/`,
  `.gitmodules`, `.vscode/`, `.devcontainer/`, `.envrc`,
  `.cursor/mcp.json`, `.zed/tasks.json`, `.zed/debug.json`, `.run/`, `.mvn/jvm.config`, `.exrc`,
  `.nvim.lua`, `.ripgreprc`, `.yarnrc.yml`: reads work, writes are refused. Every one of these
  fires **ambiently** — the host runs it at the next commit, `cd`, editor-open or ordinary tool
  invocation, with nobody deciding to run anything — so no report could reach the user in
  time. Anything that waits for a deliberate `claude` launch is editable and watched instead
  (below). `git config` is content-checked:
  ordinary keys pass; `core.hooksPath`, `core.fsmonitor`, `core.sshCommand`, `core.pager`,
  `alias.*`, `filter.*.clean` are refused.
  - **You may reproduce one, never author one.** A protected file *below* the project root may be
    written if its bytes are **identical** to the same guarded name at the root — so
    `git worktree add`, `clone`, a branch switch and `stash pop` all work on a repo that tracks
    `.vscode/`. One byte different, or no copy at the root to match, and it is refused. The root
    copy itself can never be written, whatever you do at a nested path. Committing a file first
    does not make it writable: the check is the bytes, not what git thinks is tracked.
- **Editable, but watched** — `.claude/settings*.json`, `.claude/hooks/`, `.claude-plugin/`
  (`plugin.json`, `marketplace.json`), `.mcp.json`, `.zed/settings.json`, `.cargo/config.toml`,
  `mise.toml`, `.pre-commit-config.yaml`. None of these run until someone launches `claude` or the
  tool that reads them, so you may write them — **a repo-local, committed hook is a supported
  thing to build here**, either from `.claude/settings.json` or as a plugin's `hooks/hooks.json`.
  The condition is that you **say so plainly, naming the file and what it runs**, whenever you
  write one. The host's audit gate reports it at teardown and the user should hear it from you
  first. Two things worth knowing before you try to be clever: a `plugin.json`'s `hooks` /
  `mcpServers` / `lspServers` pointer is **followed** by that audit, so aiming it at an
  unremarkable path is not a way to stay quiet; and the detector unions git with an **mtime**
  pass, so committing the file does not hide it either.
- **`~/.claude-shared/` — one open tier.** `skills/`, `agents/`, `commands/`, `plugins/`, `hooks/`
  are all writable, and everything under them auto-loads in **every** project's next session *and*
  in a host `claude` — so a write from one repo pivots into all of them. **Say so, naming the
  file, whenever you write one.** Installing a plugin works normally and lands in canonical.
  kib does not protect this tree: what it auto-runs (a `hooks` / `mcpServers` / `lspServers` /
  `monitors` `command`, or a symlink out of the tree) is reported to the user at teardown, and a
  native host `claude` — if they have one — runs it outside any sandbox.

**On any refusal above, or a launch refused by the host's audit gate: stop and report it
verbatim, including what you were attempting.** Do not retry via another path, another tool,
another config scope (`--global`, `--system`), or by asking the user to disable the guard. A
legitimate need is a conversation, not a workaround.

## Node versions

- **`nvm use 20` works here and sticks** for the rest of this terminal's session, including your
  later tool calls — unlike nvm elsewhere. `nvm ls` lists what is cached, `nvm use system` returns
  to the launch default. The matching `pnpm` comes with each version, so never `npm i -g pnpm`.
- **Not cached? `nvm install` fails `EROFS` by design** — the cache is shared by every project.
  Ask the user to run, in a **host terminal**: `kib --node-version=20` (a comma list for a repo
  needing two, `18,20`). Fetched once per machine, then remembered for this project.

## Reaching a dev server from the host browser

- **The box publishes no ports unless the user asked for it**, and on macOS the host cannot reach
  the container's bridge IP by any route. So a server you start here is invisible to their
  browser until they run, in a **host terminal**: `kib --publish=3000` (a comma list for two,
  `3000,5173`). It binds `127.0.0.1` only, is remembered for this project, and `=none` undoes it.
- **Ports are fixed when the container is created**, so say this when you hand over the command:
  it takes effect only once every session for this project is closed and the container recreated.
  Until then `kib` refuses to attach with the flag rather than start a session that silently has
  no port.
- **Bind the server to `0.0.0.0` in here** — `nuxt dev --host 0.0.0.0`, `vite --host`,
  `next dev -H 0.0.0.0`. On `127.0.0.1` it is unreachable even when the port IS published, and
  the symptom is identical.

**`EPERM` inside the project is kib refusing, and the path is the whole message** — the reason is
logged where you cannot see it (the FUSE sidecar's stderr, a different container), so do not
speculate about the cause beyond the rules above. `EACCES` is an ordinary permission problem:
check the mode and owner, and treat it as a normal error. `EROFS` is a read-only mount — under
`~/.nvm/versions/node/` that is the shared Node cache above. **`EMFILE` naming a project path is
not automatically your code's**: `ulimit -n` in here reports the limit Node raised for itself and
says nothing about the FUSE sidecar's own fd table or about `fs.inotify.max_user_instances` (256,
not raisable without root), and both are container-global. Say so before you refactor around it.

## What persists

`$CLAUDE_CONFIG_DIR` is this project's private state and carries across launches. These rules are
not part of it and are not the user's memory — they mount read-only from outside the box. The
user's own `~/.claude/CLAUDE.md` is copied in fresh each launch, so `#` memory written to it in
here is transient; durable user memory has to be written from a host terminal. Project memory and
a repo's own `CLAUDE.md` persist normally.
