# Example provider definitions

Ready-made broker routes for two services with fiddly credential shapes. **Nothing here is
built into the broker** — the broker hardcodes only the LLM Claude Code natively speaks
(`claude`). These are opt-in examples of the generic user-provider path.

To use one, copy it into your host-side providers dir and add the credential:

```bash
mkdir -p ~/.keep-it-in-your-box/providers.d
cp examples/providers/dataforseo.json ~/.keep-it-in-your-box/providers.d/
kib broker login dataforseo        # paste the base64 of 'login:password'
```

`kib broker login` stores the credential host-side (mode 600); the next `cc` launch wires the
route up — the credential never enters the sandbox.

## Files

- **`dataforseo.json`** — a remote MCP (`https://mcp.dataforseo.com/http`) authenticated with a
  static HTTP **Basic** header. The broker injects the header and re-originates TLS; the agent
  only ever sees `http://kib-broker:8100/mcp/dataforseo/http`. Because it sets
  `mcp_server_name`, it is registered in the session's `.claude.json` as an MCP server.
  Credential: paste the base64 of `login:password` (`printf '%s' 'LOGIN:PASSWORD' | base64`).

- **`gsc.json`** — Google Search Console over **OAuth 2.0**, with no MCP server anywhere. See
  the worked example below.

## Worked example: Google Search Console, without a local MCP server

Search Console is the case that used to need a whole server. Google issues no static API key
for it: every request needs an OAuth access token that expires in an hour, and the long-lived
credential (a refresh token or a service-account key) has to be *exchanged* for one — a POST
with the client secret in the **body**, which no fixed injected header can do.

The old answer was to run an MCP server (`uvx mcp-search-console`, or a Node equivalent) in its
own sidecar, purely because that server's client library knew how to do the exchange. That is a
lot of moving parts — a container, a stdio↔HTTP bridge, a third-party server trusted with your
key — to work around one missing capability.

The broker now does the exchange itself, so **there is no MCP server, no sidecar, and nothing to
install**. The route is plain HTTP and you reach it with curl. The service-account key — or the
client secret and refresh token — stays on the host; the box only ever sees
`http://kib-broker:8100/mcp/gsc/…`.

### 1. Host setup — in the browser

Nothing to install, and no `gcloud`. Two tabs: the
[Google Cloud console](https://console.cloud.google.com/) to mint a credential, and
[Search Console](https://search.google.com/search-console/) to let that credential see your
property. Search Console has no credential screen of its own — the credential always belongs to
a Cloud project — which is why half of this happens somewhere that looks unrelated.

**Recommended: a service account.** No consent screen and nothing that expires.

1. **New project**: Cloud console → the project dropdown in the title bar → **New project**. 
   Name it something like `Google Search Console MCP`. Then "Select Project" to switch to it.
2. **Enable the API**: **APIs & Services → Library**, search *Google Search Console API*,
   **Enable**. Skipping this gives a 403 on every call even after step 5.
3. **Create the account**: **APIs & Services → Credentials → Create credentials → Service
   account**. Name it, then **Done**: the optional "grant access to project" roles are Cloud IAM
   and mean nothing here, because Search Console keeps its own access list.
4. **Download the key**: click the new account → **Keys → Add key → Create new key → JSON**.
   It downloads once and *is* the credential; treat the file as a secret.
5. **Grant it the property**: Search Console → **Settings → Users and permissions → Add
   user**, pasting the account's address (`…@….iam.gserviceaccount.com` — the `client_email` in
   that JSON). **Full** covers performance data and sitemaps; **Owner** is required for URL
   Inspection. You must be an owner of the property to add anyone, and a domain property and a
   URL-prefix property are separate grants.

```bash
cp examples/providers/gsc.json ~/.keep-it-in-your-box/providers.d/
kib broker login gsc     # give it the path to the JSON key you downloaded
```

`login` copies it host-side, mode 600, and probes it. Close every kib session and relaunch —
routes are fixed at container creation. A service account is the one shape `kib broker probe`
cannot finish checking: signing needs the image, so the first real mint happens at launch and
its outcome shows up in `kib broker status`.

<details>
<summary><b>Alternative: your own Google login</b> — if service-account keys are blocked for
your organisation, or you would rather the route saw exactly the properties you already do.</summary>

Same project and same enabled API — only the credential differs, and Google's own playground
mints it so that no OAuth flow has to run locally.

1. **Credentials → Create credentials → OAuth client ID**, type **Web application**, with
   `https://developers.google.com/oauthplayground` as an **Authorised redirect URI**. Copy the
   client ID and client secret.
2. **Google Auth Platform → Audience** — where "OAuth consent screen" moved to. While that says
   **Testing**, every refresh token it issues dies after 7 days, so press **Publish app**. The
   "Google hasn't verified this app" interstitial on your own account is expected: **Advanced →
   continue**.
3. [OAuth Playground](https://developers.google.com/oauthplayground/) → the gear icon → **Use
   your own OAuth credentials**, paste the ID and secret, leave **Access type: Offline** and tick
   **Force prompt** — without it Google returns a refresh token only on the very first consent.
   In step 1, type `https://www.googleapis.com/auth/webmasters.readonly` into "Input your own
   scopes" and **Authorize APIs**, sign in as the account that owns the property, then
   **Exchange authorization code for tokens**.

Save the refresh token together with the client ID and secret as a file — this is exactly what
`gcloud` would have written, and what the broker reads:

```json
{
  "type": "authorized_user",
  "client_id": "….apps.googleusercontent.com",
  "client_secret": "…",
  "refresh_token": "1//…"
}
```

Then `kib broker login gsc` with that path. It is copied host-side mode 600, so delete your own
copy afterwards — and drop the playground redirect URI from the OAuth client, which no longer
needs it.

</details>

### 2. Use it from inside the box

One origin covers both of GSC's base paths — `/webmasters/v3/` for performance and sitemaps,
`/v1/urlInspection/` for index status — which is why `upstream_origin` is a bare host and
`allow_paths` carries the two prefixes.

```bash
BASE=http://kib-broker:8100/mcp/gsc

# Which properties can this credential see? Run this first — a domain property and a
# URL-prefix property need different siteUrl spellings in every later call.
curl -s "$BASE/webmasters/v3/sites"

# Performance. siteUrl is a PATH SEGMENT and must be URL-encoded:
#   sc-domain:example.com  ->  sc-domain%3Aexample.com
#   https://example.com/   ->  https%3A%2F%2Fexample.com%2F
SITE=sc-domain%3Aexample.com
curl -s -X POST "$BASE/webmasters/v3/sites/$SITE/searchAnalytics/query" \
  -H 'content-type: application/json' \
  -d '{"startDate":"2026-07-01","endDate":"2026-07-31",
       "dimensions":["query"],"rowLimit":100,"dataState":"final"}'

# Index status for one page.
curl -s -X POST "$BASE/v1/urlInspection/index:inspect" \
  -H 'content-type: application/json' \
  -d '{"inspectionUrl":"https://example.com/a-page","siteUrl":"sc-domain:example.com"}'
```

No `Authorization` header anywhere — adding one would be stripped. The broker attaches a freshly
minted token, and if the upstream rejects it with a 401 the request is re-minted and replayed
once, so a script never has to handle expiry.

### 3. What the endpoints are, and what they are not

These are Google's documented paths
([Search Console API](https://developers.google.com/webmaster-tools/v1/api_reference_index));
the broker only pins the origin and the two prefixes. A few traps worth knowing before you build
anything on top:

- **Query rows never sum to the totals.** Google omits rare and anonymised queries, so summing
  per-query clicks understates the page total, sometimes badly. Re-query at the dimension you
  want a total for.
- **Never average `position` across rows** — each row is already an impression-weighted average.
- **`dataState`** — `final` (the default) excludes the most recent two-to-three days; `all`
  includes fresh data that will still move. Pick one per call and say which.
- **16 months, hard.** Older data does not exist; do not infer a trend across the boundary.

## OAuth credential shapes

`credential_kind: "oauth"` stores a JSON **config**, not a secret to forward. Its `type` field
picks the grant, so there is nothing else to declare:

| `type` | Grant | Where it comes from |
|---|---|---|
| `authorized_user` | `refresh_token` | the OAuth Playground above, or `gcloud` ADC |
| `service_account` | JWT-bearer (RS256) | a Google service-account key, used verbatim |
| `client_credentials` | `client_credentials` | hand-written: `token_uri`, `client_id`/`_secret` |

**What `scopes` does and does not enforce.** For `service_account` and `client_credentials` the
scopes are sent at mint time, so the token genuinely cannot exceed them. For `authorized_user`
they are **documentation only** — Google fixes scopes at *consent* time and ignores a narrowing
`scope` on a refresh grant, so the enforcement points are the consent screen (the scope you
authorise in the playground) and `allow_paths`. Note that `allow_paths` restricts paths, not
methods: a readonly guarantee for a user-consent route rests on the scope you consented to.

**Rotation.** If a provider returns a new `refresh_token` on every exchange, the broker
discards it and says so loudly — it has no write path to any credential, by design. Such a
route works until the provider invalidates the stored token. (This is the failure that once
logged the account out; see `docs/design-notes/credential-broker.md`.)

## Equivalent without copying a file

`kib broker add` writes the same definition and then prompts for the credential, so there is
no second command and no file to hand-author. Bare, it asks the questions:

```bash
kib broker add

# static header, registered as an MCP server
kib broker add dataforseo --url https://mcp.dataforseo.com/http \
   --header "Authorization: Basic" --mcp-name dfs-mcp

# OAuth 2.0, REST only
kib broker add gsc --url https://searchconsole.googleapis.com --oauth \
   --scope https://www.googleapis.com/auth/webmasters.readonly \
   --allow-path /webmasters/v3/ --allow-path /v1/urlInspection/
```

**There is no port to choose.** Every route shares one listener (8100) and is told apart by its
route name: `http://kib-broker:8100/mcp/<id><path>`. `upstream_origin` must be a bare origin —
a def that puts a path there is refused by name, and `kib broker status` says which file.
