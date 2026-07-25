# Example provider definitions

Ready-made broker routes for two services with fiddly credential shapes. **Nothing here is
built into the broker** — the broker hardcodes only the LLMs Claude Code natively speaks
(`claude`, `codex`, `gemini`). These are opt-in examples of the generic user-provider path.

To use one, copy it into your host-side providers dir and add the credential:

```bash
mkdir -p ~/.keep-it-in-your-box/providers.d
cp examples/providers/dataforseo.json ~/.keep-it-in-your-box/providers.d/
kib broker login dataforseo        # paste the base64 of 'login:password'
```

`kib broker login` stores the secret host-side (mode 600); the next `cc` launch injects a
header-free brokered entry into the session — the credential never enters the sandbox.

## Files

- **`dataforseo.json`** — `reverse_proxy_mcp`: a remote MCP (`https://mcp.dataforseo.com/http`)
  authenticated with a static HTTP **Basic** header. The broker injects the header and
  re-originates TLS; the agent only ever sees `http://kib-broker:<port>/http`.
  Credential: paste the base64 of `login:password` (`printf '%s' 'LOGIN:PASSWORD' | base64`).

- **`gsc.json`** — `hosted_mcp`: [mcp-gsc](https://github.com/AminForou/mcp-gsc) reads a Google
  service-account **JSON key** and signs requests client-side, so it can't be header-brokered.
  The MCP server runs in its own `cap-drop=ALL` sidecar holding the key `:ro`; the agent
  reaches it over the broker network. Credential: `kib broker login gsc` and give the path to your
  service-account JSON.

## Equivalent without copying a file

`kib mcp add` writes the same definition from flags:

```bash
# reverse_proxy_mcp (remote, static header)
kib mcp add dataforseo --url https://mcp.dataforseo.com/http --header "Authorization: Basic"

# hosted_mcp (local server + extra env)
kib mcp add gsc --run "uvx mcp-search-console" --cred-env GSC_CREDENTIALS_PATH \
   --cred-kind file --env GSC_SKIP_OAUTH=true
```

Ports at/above 8100 are the user band; `kib mcp add` auto-assigns the next free one. The
copies above pin 8100/8101 — change them if they collide with another route you've added.
