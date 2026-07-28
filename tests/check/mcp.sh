#!/usr/bin/env bash
# Sourced by tests/check.sh — the generic-MCP layer end to end.
#
# The bash glue over the Python registry, exercised against a throwaway $KIB_DIR / session
# dir / project so no real credential is touched. Everything here is host-side and
# docker-free.
#
# shellcheck disable=SC2016  # every _mcp_run argument is a script body for the inner shell,
# so its $vars must survive this shell unexpanded. Single quotes are the point, not a slip.
#
# shellcheck disable=SC2030,SC2031  # every probe here runs in its own subshell and points
# KIB_CONFIG at a throwaway kib dir ON PURPOSE — the containment IS the point, so the real
# ~/.keep-it-in-your-box is never read or written. Only stdout crosses back.

# shellcheck source=SCRIPTDIR/_guard.sh
. "${BASH_SOURCE%/*}/_guard.sh" # sourced by tests/check.sh, never run directly

section "MCP brokering (registry / enabled / inject / adopt / detector / intercept)"

_mcp_tmp="$(mktemp -d)"
mkdir -p "$_mcp_tmp/kib" "$_mcp_tmp/sess" "$_mcp_tmp/proj" "$_mcp_tmp/claude"

# Run a snippet with the host units loaded and a fake KIB_DIR/SESSION_BASE; cwd is the fake
# project. CLAUDE_HOME/CLAUDE_JSON are stand-ins — the adopt and warn paths read CANONICAL
# ~/.claude.json, and must never see the real one.
#
# </dev/null is load-bearing: `provider_add` chains an interactive `provider_login` when
# `[ -t 0 ]`, so run from a terminal (not CI) the suite hung on a hidden credential prompt
# whose text the command substitution had already swallowed. Nothing here may read stdin.
_mcp_run() {
    (
        set +e
        export KIB_ROOT="$KIB_ROOT" KIB_CONFIG="$_mcp_tmp/kib/config"
        # shellcheck source=SCRIPTDIR/../../host/_load.sh
        . "$KIB_ROOT/host/_load.sh"
        export SESSION_BASE="$_mcp_tmp/sess"
        export CLAUDE_HOME="$_mcp_tmp/claude" CLAUDE_JSON="$_mcp_tmp/claude.json"
        cd "$_mcp_tmp/proj" || exit 1
        eval "$1"
    ) </dev/null
}

# No MCP is built in, so enabled/hosted sets come from USER defs in providers.d + a present
# credential file (exactly a real user's setup). An orphan token with no def is ignored.
en="$(_mcp_run '
  mkdir -p "$KIB_DIR/providers.d"
  printf "{\"id\":\"remote\",\"delivery\":\"reverse_proxy_mcp\",\"upstream_origin\":\"https://mcp.remote.example\",\"inject_header\":\"Authorization\",\"inject_template\":\"Bearer {secret}\",\"mcp_path\":\"/http\"}" > "$KIB_DIR/providers.d/remote.json"
  printf "{\"id\":\"local\",\"delivery\":\"hosted_mcp\",\"credential_kind\":\"file_path\",\"host_run\":[\"uvx\",\"some-mcp\"],\"credential_env\":\"L_CRED\",\"token_basename\":\"local.json\"}" > "$KIB_DIR/providers.d/local.json"
  printf x>"$KIB_DIR/claude-token"; printf y>"$KIB_DIR/remote-token"; printf "{}">"$KIB_DIR/local.json"
  printf z>"$KIB_DIR/orphan-token"   # no def → must NOT appear
  echo "E=[$(broker_enabled_providers)] H=[$(hosted_mcp_providers)]"')"
case "$en" in
    *"E=[claude remote]"*"H=[local]"*)
        pass "enabled = LLM + user reverse route; hosted = user local; orphan token ignored"
        ;;
    *) fail "broker_enabled_providers / hosted_mcp_providers wrong" "$en" ;;
esac

# .claude.json injection: broker + hosted URLs written from the user defs' ports, the user's
# own entry kept, and stale entries WE own pruned — including one written under the
# pre-rename `_ccBroker` marker, which must not become immortal.
inj="$(_mcp_run '
  mkdir -p "$KIB_DIR/providers.d"
  printf "{\"id\":\"remote\",\"delivery\":\"reverse_proxy_mcp\",\"upstream_origin\":\"https://mcp.remote.example\",\"inject_header\":\"Authorization\",\"inject_template\":\"Bearer {secret}\",\"mcp_path\":\"/http\",\"mcp_server_name\":\"remote\"}" > "$KIB_DIR/providers.d/remote.json"
  printf "{\"id\":\"local\",\"delivery\":\"hosted_mcp\",\"credential_kind\":\"file_path\",\"host_run\":[\"uvx\",\"some-mcp\"],\"credential_env\":\"L_CRED\",\"mcp_path\":\"/mcp\",\"mcp_server_name\":\"local\",\"token_basename\":\"local.json\"}" > "$KIB_DIR/providers.d/local.json"
  printf y>"$KIB_DIR/remote-token"
  printf "{\"mcpServers\":{\"myown\":{\"type\":\"http\",\"url\":\"http://x\"},\"legacy\":{\"_ccBroker\":true,\"url\":\"STALE_OLD\"},\"remote\":{\"_kibBroker\":true,\"url\":\"STALE_NEW\"}}}" > "$SESSION_BASE/.claude.json"
  BROKER_ENABLED=1 HOSTED_MCP_UP="local" inject_brokered_mcps >/dev/null 2>&1
  cat "$SESSION_BASE/.claude.json"')"
if printf '%s' "$inj" | grep -q "kib-broker:8100/mcp/remote/http" \
    && printf '%s' "$inj" | grep -q "local:8100/mcp" \
    && printf '%s' "$inj" | grep -q '"myown"' \
    && ! printf '%s' "$inj" | grep -q "STALE_OLD" \
    && ! printf '%s' "$inj" | grep -q "STALE_NEW"; then
    pass "inject: writes broker+hosted URLs, keeps the user entry, prunes ours (both markers)"
else
    fail "inject_brokered_mcps wrong" "$(printf '%s' "$inj" | tr -d '\n ' | head -c 220)"
fi

# adopt reuses an EXISTING user route for the same host instead of synthesizing a duplicate:
# the inline blob moves into that route's token (mode 600) and leaves the project.
reuse="$(_mcp_run '
  mkdir -p "$KIB_DIR/providers.d"
  printf "{\"id\":\"svc\",\"delivery\":\"reverse_proxy_mcp\",\"upstream_origin\":\"https://api.svc.example\",\"inject_header\":\"Authorization\",\"inject_template\":\"Bearer {secret}\",\"token_basename\":\"svc-token\",\"mcp_path\":\"/mcp\"}" > "$KIB_DIR/providers.d/svc.json"
  printf "{\"mcpServers\":{\"svc2\":{\"type\":\"http\",\"url\":\"https://api.svc.example/mcp\",\"headers\":{\"Authorization\":\"Bearer TOK123\"}}}}" > ".mcp.json"
  mcp_adopt svc2 >/dev/null 2>&1
  echo "dup=$([ -f "$KIB_DIR/providers.d/svc2.json" ] && echo yes || echo no)"
  echo "blob=$(cat "$KIB_DIR/svc-token" 2>/dev/null)"
  echo "perm=$(ls -l "$KIB_DIR/svc-token" 2>/dev/null | cut -c1-10)"
  grep -q Authorization ".mcp.json" && echo "leak=yes" || echo "leak=no"')"
if printf '%s' "$reuse" | grep -q "dup=no" \
    && printf '%s' "$reuse" | grep -q "blob=TOK123" \
    && printf '%s' "$reuse" | grep -q "perm=-rw-------" \
    && printf '%s' "$reuse" | grep -q "leak=no"; then
    pass "kib mcp adopt: reuses the existing route for that host, stores 600, strips the project"
else
    fail "kib mcp adopt reuse wrong" "$reuse"
fi

# Detector: flags an inline credential by NAME + reason, and NEVER prints the value.
det="$(_mcp_run '
  printf "{\"mcpServers\":{\"dfs\":{\"url\":\"https://x\",\"headers\":{\"Authorization\":\"Basic SECRETBLOB123\"}}}}" > ".mcp.json"
  warn_inline_mcp_secrets 2>&1')"
if printf '%s' "$det" | grep -q "kib mcp adopt dfs" \
    && ! printf '%s' "$det" | grep -q "SECRETBLOB123"; then
    pass "warn_inline_mcp_secrets: names the server + reason, never prints the secret value"
else
    fail "warn_inline_mcp_secrets wrong (or leaked the value!)" "$det"
fi

# GENERIC path: adopting an MCP with NO preset synthesizes a user provider def, which the
# broker then lists — proving "any MCP, no code change". The synthesized route carries NO port
# of its own; bash gets its share of the mux as a URL PATH.
gen="$(_mcp_run '
  printf "{\"mcpServers\":{\"acme\":{\"type\":\"http\",\"url\":\"https://mcp.acme.example/v1/sse\",\"headers\":{\"X-API-Key\":\"AK_LIVE_9\"}}}}" > ".mcp.json"
  mcp_adopt acme >/dev/null 2>&1
  echo "def=$([ -f "$KIB_DIR/providers.d/acme.json" ] && echo yes)"
  echo "listed=$(_broker_list_providers | grep -c "^acme|")"
  grep -q listen_port "$KIB_DIR/providers.d/acme.json" && echo "hasport=yes" || echo "hasport=no"
  echo "url=$(kib_py broker.cli route-url acme kib-broker)"
  echo "blob=$(cat "$KIB_DIR/acme-token" 2>/dev/null)"
  grep -q X-API-Key ".mcp.json" && echo leak=yes || echo leak=no')"
if printf '%s' "$gen" | grep -q "def=yes" \
    && printf '%s' "$gen" | grep -q "listed=1" \
    && printf '%s' "$gen" | grep -q "hasport=no" \
    && printf '%s' "$gen" | grep -q "url=http://kib-broker:8100/mcp/acme/v1/sse" \
    && printf '%s' "$gen" | grep -q "blob=AK_LIVE_9" \
    && printf '%s' "$gen" | grep -q "leak=no"; then
    pass "kib mcp adopt (no preset): synthesizes a portless user def the broker then serves"
else
    fail "generic adopt-synthesis wrong" "$gen"
fi

# The Claude token's upstream cannot be hijacked by a user provider file named after a preset.
ovr="$(_mcp_run '
  mkdir -p "$KIB_DIR/providers.d"
  printf "{\"id\":\"claude\",\"delivery\":\"reverse_proxy_mcp\",\"upstream_origin\":\"https://evil.example\",\"inject_header\":\"a\",\"inject_template\":\"b\"}" > "$KIB_DIR/providers.d/claude.json"
  kib_py broker.cli host-config claude 2>/dev/null | sed -n "s/KIB_BROKER_BASE_URL_ENV=//p" | tr -d "'"'"'"')"
if [ "$ovr" = "ANTHROPIC_BASE_URL" ]; then
    pass "a user provider def cannot override a built-in preset (claude upstream unchanged)"
else
    fail "a user def overrode the claude preset" "base-url env became: $ovr"
fi

# Interception: a pasted `kib claude mcp add … --header/--env <secret>` must be caught
# host-side and NEVER carry the secret into the box.
icA="$(_mcp_run '
  KIB_BROKER=1 intercept_mcp_add claude mcp add --header "Authorization: Basic Zm9vOmJhcg==" --transport http icdfs https://mcp.dataforseo.com/http 2>"$SESSION_BASE/ic.err"; echo "rc=$?"
  echo "perm=$(ls -l "$KIB_DIR/icdfs-token" 2>/dev/null | cut -c1-10)"
  echo "def=$([ -f "$KIB_DIR/providers.d/icdfs.json" ] && echo yes || echo no)"
  grep -q Zm9vOmJhcg== "$SESSION_BASE/ic.err" && echo leak=yes || echo leak=no')"
if printf '%s' "$icA" | grep -q "rc=0" && printf '%s' "$icA" | grep -q "perm=-rw-------" \
    && printf '%s' "$icA" | grep -q "def=yes" && printf '%s' "$icA" | grep -q "leak=no"; then
    pass "intercept: remote --header form auto-brokered host-side (token 600, def written, no leak)"
else
    fail "intercept remote-header wrong" "$icA"
fi

# The auth header need not be first. A decoy Accept header precedes Authorization; the
# interceptor must broker the Authorization value, not Accept's MIME type.
icNF="$(_mcp_run '
  KIB_BROKER=1 intercept_mcp_add claude mcp add --header "Accept: application/json" --header "Authorization: Basic Zm9vOmJhcg==" --transport http icnf https://mcp.dataforseo.com/http 2>/dev/null; echo "rc=$?"
  echo "tok=$(cat "$KIB_DIR/icnf-token" 2>/dev/null)"')"
if printf '%s' "$icNF" | grep -q "rc=0" && printf '%s' "$icNF" | grep -q "tok=Zm9vOmJhcg=="; then
    pass "intercept: brokers the Authorization header even when it is not first"
else
    fail "intercept non-first-header wrong (should broker Authorization, not Accept)" "$icNF"
fi

icB="$(_mcp_run '
  intercept_mcp_add claude mcp add iclocal --env DFS_PASSWORD=secretpw -- npx -y dataforseo-mcp-server 2>"$SESSION_BASE/ic.err"; echo "block_rc=$?"
  grep -q secretpw "$SESSION_BASE/ic.err" && echo leak=yes || echo leak=no
  KIB_ALLOW_INLINE_MCP_SECRET=1 intercept_mcp_add claude mcp add iclocal --env DFS_PASSWORD=secretpw -- npx -y dataforseo-mcp-server 2>/dev/null; echo "optout_rc=$?"')"
if printf '%s' "$icB" | grep -q "block_rc=2" && printf '%s' "$icB" | grep -q "leak=no" \
    && printf '%s' "$icB" | grep -q "optout_rc=1"; then
    pass "intercept: local --env secret blocked (rc2, no leak); KIB_ALLOW_INLINE_MCP_SECRET=1 opts out"
else
    fail "intercept local-env wrong" "$icB"
fi

# An auth header kib could NOT auto-broker (no remote http(s) URL, or a stdio target) must
# still be BLOCKED, not passed through — otherwise the raw secret rides into the container.
icH="$(_mcp_run '
  intercept_mcp_add claude mcp add icnourl --header "Authorization: Bearer sk-noturl" 2>"$SESSION_BASE/ic.err"; echo "nourl_rc=$?"
  grep -q sk-noturl "$SESSION_BASE/ic.err" && echo leak=yes || echo leak=no
  intercept_mcp_add claude mcp add icstdio --header "Authorization: Bearer sk-stdio" -- npx -y some-server 2>/dev/null; echo "stdio_rc=$?"
  KIB_ALLOW_INLINE_MCP_SECRET=1 intercept_mcp_add claude mcp add icnourl --header "Authorization: Bearer sk-noturl" 2>/dev/null; echo "optout_rc=$?"')"
if printf '%s' "$icH" | grep -q "nourl_rc=2" && printf '%s' "$icH" | grep -q "leak=no" \
    && printf '%s' "$icH" | grep -q "stdio_rc=2" && printf '%s' "$icH" | grep -q "optout_rc=1"; then
    pass "intercept: unbrokerable auth header (no URL / stdio) blocked (rc2, no leak); opt-out rc1"
else
    fail "intercept unbrokerable-header wrong (should block, not passthrough)" "$icH"
fi

icC="$(_mcp_run '
  intercept_mcp_add claude mcp add plainmcp https://example.com/mcp --transport http 2>/dev/null; echo "nosecret_rc=$?"
  intercept_mcp_add mcp list 2>/dev/null; echo "list_rc=$?"
  intercept_mcp_add claude 2>/dev/null; echo "session_rc=$?"
  intercept_mcp_add 2>/dev/null; echo "empty_rc=$?"')"
if printf '%s' "$icC" | grep -q "nosecret_rc=1" && printf '%s' "$icC" | grep -q "list_rc=1" \
    && printf '%s' "$icC" | grep -q "session_rc=1" && printf '%s' "$icC" | grep -q "empty_rc=1"; then
    pass "intercept: passthrough for no-secret add, mcp-list, a plain session, and no args"
else
    fail "intercept passthrough wrong" "$icC"
fi

# `kib broker add`, non-interactive: writes the def, proves it LOADS, and reports the URL.
# The load check is the end-to-end guarantee — a def that fails validation used to be written
# happily and only surface as a broken launch days later.
add="$(_mcp_run '
  provider_add linear --url https://mcp.linear.app/sse --header "Authorization: Bearer" 2>&1
  echo "listed=$(_broker_list_providers | grep -c "^linear|")"
  grep -q "listen_port\|mcp_port" "$KIB_DIR/providers.d/linear.json" && echo port=yes || echo port=no')"
if printf '%s' "$add" | grep -q "listed=1" \
    && printf '%s' "$add" | grep -q "port=no" \
    && printf '%s' "$add" | grep -q "http://kib-broker:8100/mcp/linear/sse"; then
    pass "kib broker add: writes a portless def, confirms it loads, prints the agent URL"
else
    fail "kib broker add wrong" "$add"
fi

# A name that is not a safe route (a path segment, a filename stem AND a word-split field) is
# refused BEFORE anything is written — a half-written providers.d is worse than a clean no.
nm="$(_mcp_run '
  before="$(ls "$KIB_DIR/providers.d" 2>/dev/null | wc -l | tr -d " ")"
  provider_add ../evil --url https://x.example >/dev/null 2>&1; echo "esc_rc=$?"
  provider_add claude  --url https://x.example >/dev/null 2>&1; echo "builtin_rc=$?"
  provider_add UPPER   --url https://x.example >/dev/null 2>&1; echo "case_rc=$?"
  after="$(ls "$KIB_DIR/providers.d" 2>/dev/null | wc -l | tr -d " ")"
  echo "unchanged=$([ "$before" = "$after" ] && echo yes || echo no)"
  provider_add dup --url https://a.example >/dev/null 2>&1
  provider_add dup --url https://b.example >/dev/null 2>&1; echo "dup_rc=$?"
  grep -q "a.example" "$KIB_DIR/providers.d/dup.json" && echo kept=yes || echo kept=no
  provider_add dup --url https://b.example --force >/dev/null 2>&1; echo "force_rc=$?"
  grep -q "b.example" "$KIB_DIR/providers.d/dup.json" && echo replaced=yes || echo replaced=no')"
if printf '%s' "$nm" | grep -q "esc_rc=5" && printf '%s' "$nm" | grep -q "builtin_rc=5" \
    && printf '%s' "$nm" | grep -q "case_rc=5" && printf '%s' "$nm" | grep -q "unchanged=yes" \
    && printf '%s' "$nm" | grep -q "dup_rc=5" && printf '%s' "$nm" | grep -q "kept=yes" \
    && printf '%s' "$nm" | grep -q "force_rc=0" && printf '%s' "$nm" | grep -q "replaced=yes"; then
    pass "kib broker add: refuses an unsafe/built-in/duplicate name, --force replaces"
else
    fail "kib broker add name validation wrong" "$nm"
fi

# Every unusable def is NAMED, host-side, with the field at fault. This is the whole fix for
# the incident: the old code said "skipping incomplete provider def" and a non-.json file said
# nothing at all, so a hand-authored route vanished without a word.
chk="$(_mcp_run '
  mkdir -p "$KIB_DIR/providers.d"
  printf "{\"delivery\":\"reverse_proxy_mcp\",\"upstream_origin\":\"https://x.example\",\"listen_port\":8100,\"inject_header\":\"a\",\"inject_template\":\"b\"}" > "$KIB_DIR/providers.d/oldport.json"
  printf "{\"delivery\":\"reverse_proxy_mcp\",\"upstream_origin\":\"https://x.example\"}" > "$KIB_DIR/providers.d/nofields.json"
  printf "{}" > "$KIB_DIR/providers.d/directus"
  _broker_check_providers 2>&1')"
if printf '%s' "$chk" | grep -q "oldport.json.*listen_port.*obsolete" \
    && printf '%s' "$chk" | grep -q "nofields.json.*inject_header.*missing" \
    && printf '%s' "$chk" | grep -q "directus: only \*.json"; then
    pass "check-providers: names every bad def and the field at fault, incl. a non-.json file"
else
    fail "check-providers did not name all three bad defs" "$chk"
fi

# A def the registry refused must never take the LAUNCH down — it is a warning, and the rest
# of the table still resolves. (The bind itself is proved fail-soft in tests/broker/.)
soft="$(_mcp_run '
  mkdir -p "$KIB_DIR/providers.d"
  printf "{\"delivery\":\"reverse_proxy_mcp\",\"upstream_origin\":\"https://x.example\",\"listen_port\":8100}" > "$KIB_DIR/providers.d/bad.json"
  printf "{\"id\":\"good\",\"delivery\":\"reverse_proxy_mcp\",\"upstream_origin\":\"https://ok.example\",\"inject_header\":\"Authorization\",\"inject_template\":\"Bearer {secret}\"}" > "$KIB_DIR/providers.d/good.json"
  printf x>"$KIB_DIR/claude-token"; printf y>"$KIB_DIR/good-token"
  echo "enabled=[$(broker_enabled_providers)]"; echo "rc=$?"')"
# The dir is shared with the sections above, so match on membership, not on the whole set.
if printf '%s' "$soft" | grep -q "rc=0" \
    && printf '%s' "$soft" | grep -qE "enabled=\[.*\bclaude\b" \
    && printf '%s' "$soft" | grep -qE "enabled=\[.*\bgood\b" \
    && ! printf '%s' "$soft" | grep -qE "enabled=\[.*\bbad\b"; then
    pass "a refused def is skipped, not fatal: every other route still resolves"
else
    fail "a bad provider def broke the good ones" "$soft"
fi

# ── the enabled set and the token mounts must be ONE decision ───────────────
# `_write_broker_config` writes `enabled` + `token_paths`; `start_broker` builds the
# `-v …:/run/broker/token/<id>:ro` mounts in a SECOND walk carrying its own copy of the delivery
# filter and the token-present test. One invariant, two spellings: an id in `enabled` whose token
# is not mounted makes the sidecar report "its credential is missing" — and for the `claude` row
# that is a FAIL_HARD route, so the launch aborts naming the credential rather than the bug.
#
# The mount loop is EXTRACTED from host/broker.sh, never retyped, so this compares the two
# implementations that actually ship. Fixture: one LLM row with a token, one reverse route with a
# token, one reverse route WITHOUT (belongs to neither list), one hosted row (its own sidecar, so
# neither list either). A plain subshell, not _mcp_run: the extracted loop carries a heredoc, and
# routing that through another layer of eval quoting is what makes this unreadable.
_tokwalk="$(
    set +e
    # KIB_ROOT is already exported by the runner; only the kib dir is redirected, so the real
    # ~/.keep-it-in-your-box is never read or written.
    export KIB_CONFIG="$_mcp_tmp/tokwalk/config"
    # shellcheck source=SCRIPTDIR/../../host/_load.sh
    . "$KIB_ROOT/host/_load.sh"
    mkdir -p "$KIB_DIR/providers.d" || exit 1
    for _r in withtok notok; do
        printf '{"id":"%s","delivery":"reverse_proxy_mcp","upstream_origin":"https://%s.example","inject_header":"Authorization","inject_template":"Bearer {secret}","mcp_path":"/http"}' \
            "$_r" "$_r" >"$KIB_DIR/providers.d/$_r.json"
    done
    printf '{"id":"hosted","delivery":"hosted_mcp","credential_kind":"file_path","host_run":["uvx","m"],"credential_env":"C","token_basename":"hosted.json"}' \
        >"$KIB_DIR/providers.d/hosted.json"
    printf x >"$KIB_DIR/claude-token"
    printf y >"$KIB_DIR/withtok-token"
    printf '{}' >"$KIB_DIR/hosted.json"
    BROKER_DIR="$KIB_DIR/bk"
    BROKER_OUT="$BROKER_DIR/out"
    mkdir -p "$BROKER_OUT"
    _write_broker_config
    python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
print("enabled=" + ",".join(sorted(d["enabled"])))
print("paths=" + ",".join(sorted(d["token_paths"])))' "$BROKER_DIR/config.json"
    eval "$(awk '/^    local id delivery kind basename$/{f=1} f{print} /^EOF$/{if(f) exit}' \
        "$KIB_ROOT/host/broker.sh" | sed 's/^    //; s/^local -a //; /^local id delivery/d')"
    # shellcheck disable=SC2154  # tok_mounts is assigned by the loop eval'd just above
    printf 'mounted=%s\n' "$(printf '%s\n' ${tok_mounts[@]+"${tok_mounts[@]}"} \
        | sed -n 's#.*/run/broker/token/##p' | sed 's/:ro$//' | sort | paste -sd, -)"
)"
_tw_en="$(printf '%s\n' "$_tokwalk" | sed -n 's/^enabled=//p')"
_tw_pa="$(printf '%s\n' "$_tokwalk" | sed -n 's/^paths=//p')"
_tw_mo="$(printf '%s\n' "$_tokwalk" | sed -n 's/^mounted=//p')"
if [ "$_tw_en" = "claude,withtok" ] && [ "$_tw_pa" = "$_tw_en" ] && [ "$_tw_mo" = "$_tw_en" ]; then
    pass "every enabled broker route gets its token mounted (both walks agree)"
else
    fail "the broker's enabled set and its token mounts disagree" \
        "enabled=[$_tw_en] token_paths=[$_tw_pa] mounted=[$_tw_mo] — all should be claude,withtok"
fi
unset _tokwalk _tw_en _tw_pa _tw_mo _r

rm -rf "$_mcp_tmp" # last, not mid-file: the tokwalk probe above re-creates it under $KIB_DIR
