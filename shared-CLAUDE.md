# Sandbox rules — every `cc` session

## 🔴 Secrets and PII — hard stop

The moment a credential or personal data enters context — a file, command output, a diff, a log, an env var — stop, print one of these, and wait for the user:

`🔴 SECRET ENCOUNTERED — stopping. <what, where from>`
`🔴 PII ENCOUNTERED — stopping. <what, where from>`

- **Secrets:** passwords, API keys, tokens, credentials. Treat `.env*`, `*secret*`, `*key*`, `*token*`, `*credential*`, `*.pem`, `id_rsa*` as suspect — ask before opening one.
- **PII:** real names, emails, phone numbers, addresses, dates of birth, government or payment IDs, IPs tied to a person. **Exempt — the user's own identifiers:** any `*@wildamer.com` address and anything containing `amerk86`. Those are expected; carry on.
- Reading it into context **is** sending it to the Anthropic API. There is no safe peek.
- Never summarise, echo, store, or keep working around it. If it is already committed, say so — do not rewrite history yourself.

## 🔴 Commit only when asked

Never commit on your own initiative. Finishing a task is not permission to commit it: "fix X" is not "commit X", and approval once is not approval next time. Ask every time. Never `git commit --no-verify`, never `--amend`, never rewrite history, never `push` unless told to. The user reads the diff before it lands — that review is a real control.

## 🔴 Redacted and protected paths

Enforced by a FUSE layer over the project. Deliberate policy, not bugs — **not yours to bypass.**

- **Redacted** (`.ccignore`, `.env` and `.env.*`) — reads return a stub, writes fail EACCES. Need a
  value? Ask. Placeholders (`.env.example`, `.env.sample`, `.env.template`, `.env.defaults`,
  `.env.dist`) are exempt and work normally — they hold no secrets.
- **Protected** (`.git/config`, `.git/hooks`, `.vscode/`, `.devcontainer/`, `.idea/`, `.envrc`, and submodule/worktree equivalents) — reads work, writes fail EACCES. The **host** executes these later, so writing one is host code execution from inside the sandbox. `git config` is content-checked: ordinary keys are fine; `core.hooksPath`, `core.fsmonitor`, `core.sshCommand`, `core.pager`, `alias.*`, `filter.*.clean` are refused.

On EACCES, or on a commit blocked by the host's pre-commit hook: stop and report it verbatim, including what you were attempting. Do not retry via another path, another tool, a different config scope (`--global`, `--system`), or by asking the user to disable the guard. A legitimate need is a conversation, not a workaround.

## Sandbox limits

- Docker container: no `docker` binary, no socket, no host processes. `HOME` is `/home/hostuser`; paths under `/home/kay/...` are host bind mounts — writes land on the host.
- Host-side commands (docker, `cc`, systemd, package installs) are the user's to run in a **host terminal**. `!` does not reach the host — it runs in this container. Hand them a fenced block they can paste whole: no `!`, no `$` prompts, real paths filled in. Keep each command on its own line, or joined with `&&` or trailing `\` for multiline; keeping each line short.
- `$CLAUDE_CONFIG_DIR` is this project's private state. `~/.claude-shared` is shared with **every** project — change it only for explicitly global requests, and say so when you do.

## How to write/update CLAUDE.md

Write CLAUDE.md files that include only what the agent can't discover on its own—exact build/test/lint commands, repo-specific tooling, and hard constraints—while omitting codebase overviews, directory listings, and generic best practices the model already knows. Focus on project-unique patterns, written as step-by-step procedures with one working code example each, rather than comprehensive descriptions of what exists. Keep the whole file short (aim for ~1,500 tokens); every line should pass the test "would the agent fail without this?" and get cut if not. Never auto-generate the file wholesale, and remove any instruction that isn't actively preventing a mistake, since unnecessary guidance measurably lowers success rates and raises cost. Keep instructions short, concise and authoritative.

## Commit message
Must always use conventional commit style.

## Code writing standard
Write great, DRY, maintainable, briefly commented and documented code, easy to maintain and read, testable, modular code.