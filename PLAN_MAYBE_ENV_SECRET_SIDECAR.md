# Plan (SHELVED) — Broker a local `--env` (multi-value) MCP via an isolated sidecar (#4 via #2)

> Status: **shelved, not implemented.** Captures the agreed design for handling a local-stdio
> MCP whose credential is delivered as multiple plain `--env` values (e.g. DataForSEO
> `DATAFORSEO_USERNAME` + `DATAFORSEO_PASSWORD`). Revisit when a real multi-value-env MCP needs
> brokering. The remote `--header` path already works and is the recommended install route.

## Context

A vendor's local-stdio install line — e.g. DataForSEO Method 2:

```
claude mcp add dfs-mcp --env DATAFORSEO_USERNAME=<u> --env DATAFORSEO_PASSWORD=<p> -- npx -y dataforseo-mcp-server
```

leaks its credentials two ways today: the `--env` values are written to `.claude.json` (in
`$CLAUDE_CONFIG_DIR`, **not** under the FUSE-redacted project view), and once Claude spawns the
stdio server as a same-uid child, the agent can read its `/proc/<pid>/environ`. The interceptor
therefore **blocks** this form (`intercept_mcp_add`, `cc-lib.sh`).

The secure fix is delivery mode **`hosted_mcp`**: run the server in its own `cap-drop=ALL`
sidecar holding the creds, agent talks HTTP and never sees them (`start_hosted_mcp`,
`cc-lib.sh`). It already works for a **single file-path** credential (GSC's service-account
JSON). Two gaps: (a) it can't take **multiple plain-value** env secrets (USERNAME+PASSWORD); (b)
there's no path from the `--env … -- cmd` syntax to it.

Decision (confirmed): keep the block on the silent/auto path (auto-running arbitrary pasted code
is a footgun), but make the `--env … -- cmd` line reachable via an **explicit opt-in**
`CC_MCP_HOSTED=1`, and add a `--secret-env` declare form. Secret **values never enter** the
broker host-config or any argv — they live in per-secret mode-600 host files, mounted `:ro` and
read into the server's env at sidecar launch.

## Design — new capability: hosted_mcp with N secret env *values*

A hosted provider def gains `secret_env: ["DATAFORSEO_USERNAME","DATAFORSEO_PASSWORD"]`. Each maps
to a host file `$KIB_DIR/<id>-<ENVNAME>` (mode 600), distinct from the single-file
`token_basename` (`<id>-token`). File-path/paste single creds (GSC) and multi-secret_env
coexist. `credential_kind: "secret_env"` marks the multi form.

### 1. `cc-broker.py` — schema + host-config (values never emitted)
- `_finalize_provider` hosted branch: `p.setdefault("secret_env", [])` (keep `extra_env`).
- `_broker_host_config`: emit `CCB_SECRET_ENV` = space-joined `secret_env` **names**
  (all `[A-Za-z0-9_]`, eval-safe). The secret **values are never read here** — only names + the
  file basenames the sidecar mounts.
- `list_providers` stays 4-field; secret_env providers report `credential_kind=secret_env`.
- `serve()` still skips `hosted_mcp` — unchanged; nothing in the broker touches these creds.

### 2. `cc-lib.sh` — active detection (reuse, don't duplicate)
- `hosted_mcp_providers`: a secret_env provider is ACTIVE iff **every**
  `$KIB_DIR/<id>-<ENV>` is non-empty; else fall back to the current `-s <token_basename>`. Get the
  env list by reusing `_broker_host_config "$id"` (locals incl. `CCB_SECRET_ENV`) — no new CLI
  flag, no 5th list field. `broker_config_hash` already keys off this.

### 3. `cc-lib.sh` — `start_hosted_mcp` mounts + exports each secret (out of argv)
- Add `CCB_SECRET_ENV` to the `local` decls. For each `<ENV>` (validate
  `^[A-Za-z_][A-Za-z0-9_]*$`): add `-v "$KIB_DIR/<id>-<ENV>:/run/cred/<id>-<ENV>:ro"` and a
  prelude `export <ENV>="$(cat /run/cred/<id>-<ENV>)";` before `exec … supergateway …`. Values are
  read from files at runtime → never in the container argv / `docker inspect`. The existing single
  `credential_env` file mount stays for the GSC case (both may be present). Fail-soft: if any
  secret file is missing, `warn` + skip that MCP. Factor the prelude build into a tiny pure helper
  (`_hosted_run_prelude`) so `tests/check.sh` can assert its shape without Docker.

### 4. `cc-lib.sh` — `intercept_mcp_add`: `CC_MCP_HOSTED=1` opt-in → synthesize hosted def
- Capture the post-`--` tokens as the server command (currently skipped).
- Thread `CC_IC_HOSTED="${CC_MCP_HOSTED:-0}"` into the embedded-python env.
- In the `if secret_env:` block, **before** the block message, add: if opt-in AND a `name` AND a
  post-`--` command → **synthesize** `providers.d/<name>.json` (`hosted_mcp`,
  `credential_kind:"secret_env"`, `host_run:<cmd>`, `secret_env:[secret names]`,
  `extra_env:{non-secret --env}`, `mcp_port` from `--next-port`, `mcp_path:"/mcp"`), store each
  secret value at `$KIB_DIR/<name>-<KEY>` (`umask 077` + `os.replace`, mode 600), print a
  names-only summary, `sys.exit(0)`. Reuses the remote path's atomic-store idiom.
  Broker-off → stage + enable hint, same as the remote branch.
- Precedence: **HOSTED (secure) is checked before ALLOW (in-box)**. Update the block message to
  advertise `CC_MCP_HOSTED=1`.

### 5. `cc-lib.sh` — declare form + credential lifecycle
- `mcp_add`: add repeatable `--secret-env <ENV>`. In the hosted branch, if any `--secret-env`,
  set `secret_env:[…]` + `credential_kind:"secret_env"` and make `--cred-env` optional. `--env
  KEY=VAL` still → `extra_env`.
- `provider_login`: for `_P_KIND == secret_env`, loop the env list (from `_broker_host_config`),
  hidden-paste each, store `$KIB_DIR/<id>-<ENV>` via the existing `_store_secret_file`; no probe.
  Factor the store loop (`_store_secret_envs`) so `check.sh` can drive it without a TTY.
- `provider_logout` removes every `$KIB_DIR/<id>-<ENV>`; `provider_status` lists each ENV
  present/—; `_provider_login_hint` gains a `secret_env` line.
- `inject_brokered_mcps` needs no change — already writes a header/env-free hosted entry.

### 6. Docs
- CLAUDE.md delivery-modes + interception bullets; README `CC_MCP_HOSTED=1` path + `--secret-env`
  declare form; docs/FUTURE_TASKS.md mark the `--env` multi-secret gap closed.

## Reused (not rebuilt)
`start_hosted_mcp` sidecar + supergateway bridge; `_store_secret_file` atomic 600 write;
`_broker_host_config` CCB_* plumbing; `env_is_secret` classifier; `--next-port`; the interceptor's
atomic-store idiom; `inject_brokered_mcps` hosted branch.

## Out of scope
- Auto (no-opt-in) brokering of a pasted `-- cmd` — deliberately behind `CC_MCP_HOSTED=1`.
- The `hosted_mcp` end-to-end runtime remains verify-on-first-real-use.
- Trust of the MCP server's own code (runs in the sidecar) — documented `hosted_mcp` trade; pin it.
