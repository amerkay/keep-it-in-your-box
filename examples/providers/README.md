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
  re-originates TLS; the agent only ever sees `http://kib-broker:8100/mcp/dataforseo/http`.
  Credential: paste the base64 of `login:password` (`printf '%s' 'LOGIN:PASSWORD' | base64`).

- **`gsc.json`** — `hosted_mcp`: [mcp-gsc](https://github.com/AminForou/mcp-gsc) reads a Google
  service-account **JSON key** and signs requests client-side, so it can't be header-brokered.
  The MCP server runs in its own `cap-drop=ALL` sidecar holding the key `:ro`; the agent
  reaches it over the broker network. Credential: `kib broker login gsc` and give the path to your
  service-account JSON.

## Equivalent without copying a file

`kib broker add` writes the same definition and then prompts for the credential, so there is
no second command and no file to hand-author. Bare, it asks the questions:

```bash
kib broker add

# reverse_proxy_mcp (remote, static header)
kib broker add dataforseo --url https://mcp.dataforseo.com/http --header "Authorization: Basic"

# hosted_mcp (local server + extra env)
kib broker add gsc --run "uvx mcp-search-console" --cred-env GSC_CREDENTIALS_PATH \
   --cred-kind file --env GSC_SKIP_OAUTH=true
```

**There is no port to choose.** Every brokered MCP shares one listener (8100) and is told apart
by its route name: `http://kib-broker:8100/mcp/<id><mcp_path>`. A def carrying `listen_port` or
`mcp_port` is refused by name — `kib broker status` says which file and which key.
