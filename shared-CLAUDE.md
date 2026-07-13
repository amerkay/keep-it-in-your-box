# Sandbox rules — apply to every `cc` session

## 🔴 Secrets — hard stop

If a secret, password, API key, token, or credential appears anywhere — a file you read, command
output, `git diff`/`git show`/`git log -p`, a log, an env var — **stop immediately**. Print:

`🔴 SECRET ENCOUNTERED — stopping. <what, and where it came from>`

Then wait for the user. Do not summarise it, echo it, store it, or keep working around it.

- Reading a secret into context **is** sending it to the Anthropic API. There is no safe peek.
- Never commit, stage, or diff a file matching a `.ccignore` rule. Never `git commit --no-verify`.
- Treat `.env*`, `*secret*`, `*key*`, `*credential*`, `*token*`, `*.pem`, `id_rsa*` as suspect:
  check `.ccignore` and ask before opening one.
- If a secret is already committed, stop and tell the user — do not rewrite history yourself.

## .ccignore

Paths matching `.ccignore` are redacted by a FUSE layer: reads return a stub, writes fail with
EACCES. That is deliberate, not a bug. Do not attempt to reach the real contents by any route —
`git`, `tar`, a subprocess, the network, or a path that dodges the mount. If you genuinely need a
redacted file, ask the user for the specific value.

## Sandbox limits

- You are in a Docker container: no `docker` binary, no Docker socket, no host processes.
- `HOME` is `/home/hostuser`. Paths under `/home/kay/...` are bind mounts of real host files —
  writes land on the host.
- Commands that must run on the host (docker, `cc`, systemd, host package installs) are not yours
  to run. Hand them to the user; `! <cmd>` runs a command host-side from their prompt.
- Claude's config is split: `$CLAUDE_CONFIG_DIR` is this project's private state, and
  `~/.claude-shared` is shared across projects. You can only see this project's history.
