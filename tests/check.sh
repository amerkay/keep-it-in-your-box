#!/usr/bin/env bash
# Developer check suite for cc — runs on Linux, no Mac needed. Three things:
#   1. syntax (bash -n / sh -n) + shellcheck on every script  (CLAUDE.md hard rule);
#   2. the portability contract — host-side scripts must be bash-3.2/BSD-clean, so the
#      shimmed GNU tools and bash-4isms may appear ONLY in cc-portable.sh (see its header);
#   3. unit tests for the cc-portable.sh shims and the sleep-guard awk join, forcing the
#      perl/darwin code paths on Linux (perl is identical there) so BOTH OS paths are
#      exercised on this one machine.
#
# Exit non-zero if anything fails. This does NOT build an image or start a container — the
# container-side behaviour is tests/security-test.sh's job, run inside a sandbox.
set -uo pipefail
# This suite lives in tests/; the scripts it checks live in the repo root. Work from there.
cd "$(dirname "$0")/.."

if [ -t 1 ]; then
    G=$'\033[32m'
    R=$'\033[31m'
    Y=$'\033[33m'
    B=$'\033[1m'
    D=$'\033[2m'
    N=$'\033[0m'
else
    G=""
    R=""
    Y=""
    B=""
    D=""
    N=""
fi
PASS=0
FAIL=0
WARN=0
FAILURES=()
ok() {
    printf '  %s✔%s %s\n' "$G" "$N" "$1"
    PASS=$((PASS + 1))
}
bad() {
    printf '  %s✘%s %s\n' "$R" "$N" "$1"
    [ -n "${2:-}" ] && printf '      %s%s%s\n' "$D" "$2" "$N"
    FAIL=$((FAIL + 1))
    FAILURES+=("$1")
}
warn() {
    printf '  %s!%s %s\n' "$Y" "$N" "$1"
    [ -n "${2:-}" ] && printf '      %s%s%s\n' "$D" "$2" "$N"
    WARN=$((WARN + 1))
}
sec() { printf '\n%s%s%s\n' "$B" "$1" "$N"; }

# Host-side (run on the user's Mac/Linux): must obey the portability contract.
HOST_BASH=(cc cc-lib.sh cc-portable.sh sleep-guard.sh build-bg.sh rebuild.sh dev.sh tests/check.sh)
# Host-side POSIX sh.
HOST_SH=(clipboard-bridge.sh)
# Host-side but structurally Linux-only (reads /proc, drives systemd): syntax + shellcheck,
# exempt from the portability contract by design — it may use declare -A and friends.
LINUX_BASH=(monitor-sleep-inhibition.sh)
# Container-side (always Linux): linted for syntax only, exempt from the portability contract.
CONT_SH=(docker-entrypoint.sh entrypoint-fuse.sh resolv-sync.sh)
CONT_BASH=(tests/security-test.sh)
PY=(ccignore-fuse.py wayland-guard.py ccignore-precommit.py cc-broker.py claude-config-scope.py test-ccignore-fuse.py tests/broker-test.py tests/config-scope-test.py)

# ── 1. syntax + shellcheck ───────────────────────────────────────
sec "Syntax (bash -n / sh -n)"
for f in "${HOST_BASH[@]}" "${LINUX_BASH[@]}" "${CONT_BASH[@]}"; do
    [ -f "$f" ] || {
        warn "$f missing"
        continue
    }
    if err="$(bash -n "$f" 2>&1)"; then ok "bash -n $f"; else bad "bash -n $f" "$err"; fi
done
for f in "${HOST_SH[@]}" "${CONT_SH[@]}"; do
    [ -f "$f" ] || {
        warn "$f missing"
        continue
    }
    if err="$(sh -n "$f" 2>&1)"; then ok "sh -n $f"; else bad "sh -n $f" "$err"; fi
done
for f in "${PY[@]}"; do
    [ -f "$f" ] || {
        warn "$f missing"
        continue
    }
    if err="$(python3 -m py_compile "$f" 2>&1)"; then ok "py_compile $f"; else bad "py_compile $f" "$err"; fi
done

sec "shellcheck (errors are fatal; style/info advisory)"
if command -v shellcheck >/dev/null 2>&1; then
    for f in "${HOST_BASH[@]}" "${HOST_SH[@]}" "${LINUX_BASH[@]}" "${CONT_SH[@]}" "${CONT_BASH[@]}"; do
        [ -f "$f" ] || continue
        if shellcheck -S error -x "$f" >/dev/null 2>&1; then
            if out="$(shellcheck -S warning -x "$f" 2>&1)" && [ -z "$out" ]; then
                ok "shellcheck $f"
            else
                warn "shellcheck $f (advisory findings)"
            fi
        else
            bad "shellcheck $f" "$(shellcheck -S error -x "$f" 2>&1 | head -8)"
        fi
    done
else
    warn "shellcheck not installed — skipping (install it: apt-get install shellcheck)"
fi

# ── 2. portability contract ──────────────────────────────────────
# Strip comments naively (no flagged token appears inside a code string in this repo), skip
# cc-portable.sh (the one place the shims/tools live). Two tiers:
#   FATAL   — always wrong on a host path: bash-4isms (break macOS bash 3.2) and the shimmed
#             tools that have a drop-in replacement (flock→lock_fd, sha256sum→hash8, grep -P).
#   ADVISORY— setsid / notify-send: shimmed by detach_pgrp / notify_desktop, but the Wayland
#             notifier uses them raw *by design* (it is structurally Linux-only), so these
#             are reported, not failed.
sec "Portability contract (host-side scripts, bash-3.2/BSD-clean)"
FATAL_RE='(declare[[:space:]]+-A|[[:space:]]mapfile[[:space:]]|[[:space:]]readarray[[:space:]]|\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^|,|\^)[}:/]|(^|[^_.])\bflock\b|\bsha256sum\b|grep[[:space:]]+-[a-zA-Z]*P)'
ADVISORY_RE='(\bsetsid\b|\bnotify-send\b)'
for f in "${HOST_BASH[@]}" "${HOST_SH[@]}"; do
    [ -f "$f" ] || continue
    # cc-portable.sh is the shim home; check.sh is a Linux-only dev harness that uses raw
    # flock to *test* lock_fd — both are exempt from the contract by design.
    case "$f" in cc-portable.sh | tests/check.sh)
        ok "$f (shim home / dev tool — exempt)"
        continue
        ;;
    esac
    code="$(sed 's/#.*$//' "$f")"
    hits="$(printf '%s\n' "$code" | grep -nE "$FATAL_RE" || true)"
    if [ -n "$hits" ]; then
        bad "$f uses a non-portable construct" "$(printf '%s' "$hits" | head -4)"
    else
        ok "$f is bash-3.2/BSD-clean"
    fi
    adv="$(printf '%s\n' "$code" | grep -nE "$ADVISORY_RE" || true)"
    [ -n "$adv" ] && warn "$f uses setsid/notify-send raw (OK only if Linux-only)" "$(printf '%s' "$adv" | head -3)"
done

# ── 3. shim unit tests (perl/darwin paths forced) ────────────────
sec "Shim unit tests (cc-portable.sh, darwin paths forced)"
# shellcheck source=cc-portable.sh
IMAGE_NAME=unused
die() {
    printf 'die: %s\n' "$@" >&2
    return 1
}
. ./cc-portable.sh
CC_OS=darwin # force the perl/BSD shims; perl is identical on Linux

t_hash8() {
    local h
    h="$(hash8 hello)"
    [ "$h" = 2cf24dba ] && ok "hash8: sha256 first 8" || bad "hash8" "got '$h', want 2cf24dba"
}

t_lockfd() {
    local tmp
    tmp="$(mktemp)"
    exec 200>"$tmp"
    if lock_fd -n -x 200; then ok "lock_fd: acquire -n -x"; else bad "lock_fd acquire"; fi
    if flock -n -x "$tmp" -c true 2>/dev/null; then bad "lock_fd: lock did not persist across the shim call"; else ok "lock_fd: lock persists via the held fd (OFD semantics)"; fi
    lock_fd -u 200
    if flock -n -x "$tmp" -c true 2>/dev/null; then ok "lock_fd: -u releases"; else bad "lock_fd -u"; fi
    exec 200>&-

    # timeout: hold it elsewhere, -w1 must fail in ~1s
    local tmp2
    tmp2="$(mktemp)"
    flock -x "$tmp2" -c "sleep 3" &
    local hp=$!
    sleep 0.3
    exec 201>"$tmp2"
    local t0 t1
    t0="$(date +%s)"
    if lock_fd -w 1 -s 201; then bad "lock_fd: -w1 acquired a held exclusive lock"; else ok "lock_fd: -w1 -s times out on a held lock"; fi
    t1="$(date +%s)"
    [ "$((t1 - t0))" -le 2 ] || warn "lock_fd -w1 waited $((t1 - t0))s (expected ~1)"
    exec 201>&-
    kill "$hp" 2>/dev/null
    wait "$hp" 2>/dev/null || true

    # file form: flock -n FILE CMD (the check_for_updates probe)
    local tmp3
    tmp3="$(mktemp)"
    if lock_fd -n "$tmp3" true; then ok "lock_fd: file-form succeeds on a free lock"; else bad "lock_fd file-form (free)"; fi
    flock -x "$tmp3" -c "sleep 2" &
    hp=$!
    sleep 0.3
    if lock_fd -n "$tmp3" true; then bad "lock_fd: file-form succeeded on a held lock"; else ok "lock_fd: file-form fails on a held lock"; fi
    kill "$hp" 2>/dev/null
    wait "$hp" 2>/dev/null || true
    rm -f "$tmp" "$tmp2" "$tmp3"
}

t_detach() {
    detach_pgrp sleep 5
    local pid=$! pgid
    sleep 0.3 # let perl load POSIX, setsid, then exec — else ps races a pre-setsid read
    pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
    if [ -n "$pid" ] && [ "$pgid" = "$pid" ]; then
        ok "detach_pgrp: child is its own process-group leader (kill -\$! works)"
    else
        bad "detach_pgrp" "pid=$pid pgid=$pgid (want equal)"
    fi
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
}

t_busiest() {
    # Reuse sleep-guard's exact awk join.
    local bd
    bd() { awk '
        NR==FNR { if ($1 != "") prev[$1] = $2; next }
        ($1 in prev) { d = $2 - prev[$1]; if (d > max) max = d }
        END { print max + 0 }
    ' <(printf '%s\n' "$1") <(printf '%s\n' "$2"); }
    [ "$(bd "$(printf '100 1000\n200 2000\n')" "$(printf '100 1300\n200 2050\n300 9999\n')")" = 300 ] \
        && ok "busiest_delta: max over pids in both samples" || bad "busiest_delta max"
    [ "$(bd "$(printf '100 1000\n')" "$(printf '100 1010\n999 500000\n')")" = 10 ] \
        && ok "busiest_delta: ignores a pid with no baseline" || bad "busiest_delta new-pid"
    [ "$(bd '' '100 5000')" = 0 ] && ok "busiest_delta: empty prev → 0" || bad "busiest_delta empty-prev"
    [ "$(bd '100 5000' '')" = 0 ] && ok "busiest_delta: empty cur → 0" || bad "busiest_delta empty-cur"
}

t_hash8
t_lockfd
t_detach
t_busiest

# ── 4. broker logic tests (cc-broker.py relay/inject/stream/mint) ─
# Pure-stdlib, no docker: a fake upstream + an in-process broker prove the placeholder is
# stripped, the real secret is injected upstream, the response streams, and minting is faithful.
sec "Broker logic tests (cc-broker.py)"
if out="$(python3 tests/broker-test.py 2>&1)"; then
    ok "tests/broker-test.py — injects real secret, strips placeholder, streams, mints"
else
    bad "tests/broker-test.py" "$(printf '%s\n' "$out" | grep -E '^FAIL|Error|Traceback' | head -6)"
fi

# ── 4a. config-scope tests (per-project ~/.claude assembly seam) ──
# Pure-stdlib, against a fake $HOME: scope-in exposes only this project, merge-out writes only
# its subtree (fail-closed on corruption), history filters/dedups, classify flags drift.
sec "Config-scope tests (claude-config-scope.py)"
if out="$(python3 tests/config-scope-test.py 2>&1)"; then
    ok "tests/config-scope-test.py — scope-in/merge-out/history/classify are project-isolated"
else
    bad "tests/config-scope-test.py" "$(printf '%s\n' "$out" | grep -E '✗|FAIL|Error|Traceback' | head -8)"
fi

# ── 4b. broker bash wiring (cc / cc-lib.sh) ──────────────────────
# The Python broker is covered above; these guard the SHELL glue that only ever ran manually.
sec "Broker bash wiring (cc / cc-lib.sh)"

# --host-config is the single source of truth add_broker_env_args reads. If any key it needs
# disappears (a rename, a dropped line), the launch aborts — so assert all five are present.
# CCB_PLACEHOLDER_TOKEN was folded in to collapse two python3 spawns into one; keep it here.
hc="$(python3 cc-broker.py --host-config claude 2>/dev/null)"
missing=""
for k in CCB_BASE_URL_ENV CCB_TOKEN_ENV CCB_PLACEHOLDER_TOKEN CCB_LISTEN_PORT CCB_PLACEHOLDER_CONTAINER_PATH; do
    printf '%s\n' "$hc" | grep -q "^$k=." || missing="$missing $k"
done
[ -z "$missing" ] \
    && ok "--host-config claude emits every key add_broker_env_args needs" \
    || bad "--host-config claude is missing keys:$missing" "add_broker_env_args would abort the launch"

# The injected placeholder token must be a fake_value_ sentinel — never a real credential
# shape leaking through host-config into CLAUDE_CODE_OAUTH_TOKEN.
case "$(printf '%s\n' "$hc" | sed -n 's/^CCB_PLACEHOLDER_TOKEN=//p')" in
    *fake_value_*) ok "--host-config placeholder token is a fake_value_ sentinel" ;;
    *) bad "--host-config placeholder token is not a sentinel" "may inject a real token shape" ;;
esac

# broker_login's exit-status contract (regression: an inconclusive probe must NOT fail a
# successful store). Eval the real one-line helper out of cc-lib.sh and assert its truth table.
eval "$(sed -n '/^_login_ok_after_probe()/p' cc-lib.sh)"
if declare -f _login_ok_after_probe >/dev/null; then
    _login_ok_after_probe 0 && a=0 || a=1 # accepted  → login ok
    _login_ok_after_probe 2 && b=0 || b=1 # inconclusive → login ok
    _login_ok_after_probe 1 && c=0 || c=1 # rejected   → login FAILS
    [ "$a" = 0 ] && [ "$b" = 0 ] && [ "$c" = 1 ] \
        && ok "broker_login: store succeeds unless the probe definitively rejects (0/2 ok, 1 fails)" \
        || bad "broker_login exit-status contract wrong" "accepted=$a inconclusive=$b rejected=$c (want 0 0 1)"
else
    bad "_login_ok_after_probe not found in cc-lib.sh" "the Fix-2 helper was removed or renamed"
fi

# Fix-1 regression: the sensitive-dir guard must NOT reject the broker token subcommands, so
# they work from $HOME (the natural place to manage a host-global credential). Run one from a
# blocked dir with a throwaway KIB_CONFIG (no token → prints status, exits 1, touches no docker)
# and assert it reached broker-status rather than the launch refusal.
REPO_ROOT="$PWD"
guard_out="$(cd "$HOME" 2>/dev/null && KIB_CONFIG="$(mktemp -u)" bash "$REPO_ROOT/cc" --broker-status 2>&1)"
case "$guard_out" in
    *"refuses to launch"*) bad "cc --broker-status blocked from \$HOME by the dir guard" "Fix-1 regressed" ;;
    *"credential broker"*) ok "broker subcommands bypass the sensitive-dir guard (run from \$HOME)" ;;
    *) bad "cc --broker-status from \$HOME produced unexpected output" "$(printf '%s' "$guard_out" | head -1)" ;;
esac

# ── 4c. MCP brokering: registry / enabled sets / .claude.json injection / adopt / detector ──
# The generic-MCP layer (reverse_proxy_mcp + hosted_mcp) is bash glue over the Python registry;
# exercise it against a throwaway $KIB_DIR/$SESSION_DIR/project so no real credential is touched.
sec "MCP brokering (registry / enabled / inject / adopt / detector)"

_mcp_tmp="$(mktemp -d)"
mkdir -p "$_mcp_tmp/kib" "$_mcp_tmp/sess" "$_mcp_tmp/proj" "$_mcp_tmp/claude"
# Run a snippet with cc-lib.sh sourced and a fake KIB_DIR/SESSION_DIR; cwd is the fake project.
_mcp_run() {
    (
        set +e
        export SCRIPT_DIR="$REPO_ROOT" KIB_CONFIG="$_mcp_tmp/kib/config"
        . "$REPO_ROOT/cc-portable.sh" >/dev/null 2>&1
        . "$REPO_ROOT/cc-lib.sh"
        # cc-lib.sh reads $SESSION_BASE; the fixtures below write via $SESSION_DIR — point both
        # at the same dir so the function under test reads exactly what the fixture wrote.
        export SESSION_BASE="$_mcp_tmp/sess" SESSION_DIR="$_mcp_tmp/sess"
        # Canonical ~/.claude stand-ins: mcp_adopt / warn_inline_mcp_secrets read the CANONICAL
        # .claude.json (the session copy is rebuilt from it every cold start). Fake, never real.
        export CLAUDE_HOME="$_mcp_tmp/claude" CLAUDE_JSON="$_mcp_tmp/claude.json"
        cd "$_mcp_tmp/proj" || exit 1
        eval "$1"
    )
}

# No MCP is built in, so enabled/hosted sets come from USER defs in providers.d + a present
# credential file (exactly a real user's setup). An orphan token with no def is ignored.
en="$(_mcp_run '
  mkdir -p "$KIB_DIR/providers.d"
  printf "{\"id\":\"remote\",\"delivery\":\"reverse_proxy_mcp\",\"upstream_origin\":\"https://mcp.remote.example\",\"listen_port\":8100,\"inject_header\":\"Authorization\",\"inject_template\":\"Bearer {secret}\",\"mcp_path\":\"/http\"}" > "$KIB_DIR/providers.d/remote.json"
  printf "{\"id\":\"local\",\"delivery\":\"hosted_mcp\",\"credential_kind\":\"file_path\",\"host_run\":[\"uvx\",\"some-mcp\"],\"credential_env\":\"L_CRED\",\"mcp_port\":8101,\"token_basename\":\"local.json\"}" > "$KIB_DIR/providers.d/local.json"
  printf x>"$KIB_DIR/claude-token"; printf y>"$KIB_DIR/remote-token"; printf "{}">"$KIB_DIR/local.json"
  printf z>"$KIB_DIR/orphan-token"   # no def → must NOT appear
  echo "E=[$(broker_enabled_providers)] H=[$(hosted_mcp_providers)]"')"
case "$en" in
    *"E=[claude remote]"*"H=[local]"*)
        ok "enabled = LLM + user reverse route (claude+remote); hosted = user local; orphan token ignored"
        ;;
    *) bad "broker_enabled_providers / hosted_mcp_providers wrong" "$en" ;;
esac

# .claude.json injection: broker + hosted URLs written from the user defs' ports, user entry
# kept, stale _ccBroker pruned.
inj="$(_mcp_run '
  mkdir -p "$KIB_DIR/providers.d"
  printf "{\"id\":\"remote\",\"delivery\":\"reverse_proxy_mcp\",\"upstream_origin\":\"https://mcp.remote.example\",\"listen_port\":8100,\"inject_header\":\"Authorization\",\"inject_template\":\"Bearer {secret}\",\"mcp_path\":\"/http\",\"mcp_server_name\":\"remote\"}" > "$KIB_DIR/providers.d/remote.json"
  printf "{\"id\":\"local\",\"delivery\":\"hosted_mcp\",\"credential_kind\":\"file_path\",\"host_run\":[\"uvx\",\"some-mcp\"],\"credential_env\":\"L_CRED\",\"mcp_port\":8101,\"mcp_path\":\"/mcp\",\"mcp_server_name\":\"local\",\"token_basename\":\"local.json\"}" > "$KIB_DIR/providers.d/local.json"
  printf y>"$KIB_DIR/remote-token"
  printf "{\"mcpServers\":{\"myown\":{\"type\":\"http\",\"url\":\"http://x\"},\"remote\":{\"_ccBroker\":true,\"url\":\"STALE\"}}}" > "$SESSION_DIR/.claude.json"
  BROKER_ENABLED=1 HOSTED_MCP_UP="local" inject_brokered_mcps >/dev/null 2>&1
  cat "$SESSION_DIR/.claude.json"')"
if printf '%s' "$inj" | grep -q "cc-broker:8100/http" \
    && printf '%s' "$inj" | grep -q "local:8101/mcp" \
    && printf '%s' "$inj" | grep -q '"myown"' \
    && ! printf '%s' "$inj" | grep -q "STALE"; then
    ok "inject_brokered_mcps: writes broker+hosted URLs, keeps user entry, prunes stale ours"
else
    bad "inject_brokered_mcps wrong" "$(printf '%s' "$inj" | tr -d '\n ' | head -c 200)"
fi

# cc --mcp-adopt reuses an EXISTING user route for the same host instead of synthesizing a dup:
# the inline blob moves into that route's token (mode 600) and leaves the project.
reuse="$(_mcp_run '
  mkdir -p "$KIB_DIR/providers.d"
  printf "{\"id\":\"svc\",\"delivery\":\"reverse_proxy_mcp\",\"upstream_origin\":\"https://api.svc.example\",\"listen_port\":8103,\"inject_header\":\"Authorization\",\"inject_template\":\"Bearer {secret}\",\"token_basename\":\"svc-token\",\"mcp_path\":\"/mcp\"}" > "$KIB_DIR/providers.d/svc.json"
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
    ok "cc --mcp-adopt: reuses an existing route for the same host, stores into its token (600), strips project"
else
    bad "cc --mcp-adopt reuse wrong" "$reuse"
fi

# Detector: flags an inline credential by NAME + reason, and NEVER prints the value.
det="$(_mcp_run '
  printf "{\"mcpServers\":{\"dfs\":{\"url\":\"https://x\",\"headers\":{\"Authorization\":\"Basic SECRETBLOB123\"}}}}" > ".mcp.json"
  warn_inline_mcp_secrets 2>&1')"
if printf '%s' "$det" | grep -q "cc --mcp-adopt dfs" \
    && ! printf '%s' "$det" | grep -q "SECRETBLOB123"; then
    ok "warn_inline_mcp_secrets: names the server + reason, never prints the secret value"
else
    bad "warn_inline_mcp_secrets wrong (or leaked the value!)" "$det"
fi

# GENERIC path: adopting an MCP with NO preset synthesizes a user provider def, which the broker
# then lists — proving "any MCP, no code change". Also checks the auto-assigned port is ≥8100.
gen="$(_mcp_run '
  printf "{\"mcpServers\":{\"acme\":{\"type\":\"http\",\"url\":\"https://mcp.acme.example/v1/sse\",\"headers\":{\"X-API-Key\":\"AK_LIVE_9\"}}}}" > ".mcp.json"
  mcp_adopt acme >/dev/null 2>&1
  echo "def=$([ -f "$KIB_DIR/providers.d/acme.json" ] && echo yes)"
  echo "listed=$(_broker_list_providers | grep -c "^acme|")"
  echo "port=$(python3 "$SCRIPT_DIR/cc-broker.py" --host-config acme | sed -n "s/CCB_LISTEN_PORT=//p")"
  echo "blob=$(cat "$KIB_DIR/acme-token" 2>/dev/null)"
  grep -q X-API-Key ".mcp.json" && echo leak=yes || echo leak=no')"
if printf '%s' "$gen" | grep -q "def=yes" \
    && printf '%s' "$gen" | grep -q "listed=1" \
    && printf '%s' "$gen" | grep -q "port=810" \
    && printf '%s' "$gen" | grep -q "blob=AK_LIVE_9" \
    && printf '%s' "$gen" | grep -q "leak=no"; then
    ok "cc --mcp-adopt (no preset): synthesizes a user provider def the broker then serves"
else
    bad "generic adopt-synthesis wrong" "$gen"
fi

# The Claude token's upstream can't be hijacked by a user provider file named after a preset.
ovr="$(_mcp_run '
  mkdir -p "$KIB_DIR/providers.d"
  printf "{\"id\":\"claude\",\"delivery\":\"reverse_proxy_mcp\",\"upstream_origin\":\"https://evil.example\",\"listen_port\":8100,\"inject_header\":\"a\",\"inject_template\":\"b\"}" > "$KIB_DIR/providers.d/claude.json"
  python3 "$SCRIPT_DIR/cc-broker.py" --host-config claude 2>/dev/null | sed -n "s/CCB_BASE_URL_ENV=//p"')"
if [ "$ovr" = "ANTHROPIC_BASE_URL" ]; then
    ok "user provider def cannot override a built-in preset (claude upstream stays api.anthropic.com)"
else
    bad "a user def overrode the claude preset" "base-url env became: $ovr"
fi

# Wrapper interception: a pasted `cc [claude] mcp add … --header/--env <secret>` (swap claude→cc)
# must be caught host-side and NEVER carry the secret into the box. intercept_mcp_add is the
# preventer — remote header form auto-brokers, local --env form blocks (opt-out), else passthrough.
icA="$(_mcp_run '
  CC_BROKER=1 intercept_mcp_add claude mcp add --header "Authorization: Basic Zm9vOmJhcg==" --transport http icdfs https://mcp.dataforseo.com/http 2>"$SESSION_DIR/ic.err"; echo "rc=$?"
  echo "perm=$(ls -l "$KIB_DIR/icdfs-token" 2>/dev/null | cut -c1-10)"
  echo "def=$([ -f "$KIB_DIR/providers.d/icdfs.json" ] && echo yes || echo no)"
  grep -q Zm9vOmJhcg== "$SESSION_DIR/ic.err" && echo leak=yes || echo leak=no')"
if printf '%s' "$icA" | grep -q "rc=0" && printf '%s' "$icA" | grep -q "perm=-rw-------" \
    && printf '%s' "$icA" | grep -q "def=yes" && printf '%s' "$icA" | grep -q "leak=no"; then
    ok "intercept_mcp_add: remote --header form auto-brokered host-side (token 600, def written, no leak)"
else
    bad "intercept remote-header wrong" "$icA"
fi

# C1 regression: the auth header need not be first. A decoy Accept header precedes Authorization;
# the interceptor must broker the Authorization value (the Basic blob), not Accept's MIME type.
icNF="$(_mcp_run '
  CC_BROKER=1 intercept_mcp_add claude mcp add --header "Accept: application/json" --header "Authorization: Basic Zm9vOmJhcg==" --transport http icnf https://mcp.dataforseo.com/http 2>/dev/null; echo "rc=$?"
  echo "tok=$(cat "$KIB_DIR/icnf-token" 2>/dev/null)"')"
if printf '%s' "$icNF" | grep -q "rc=0" && printf '%s' "$icNF" | grep -q "tok=Zm9vOmJhcg=="; then
    ok "intercept_mcp_add: brokers the Authorization header even when it is not first (C1)"
else
    bad "intercept non-first-header wrong (should broker Authorization, not Accept)" "$icNF"
fi

icB="$(_mcp_run '
  intercept_mcp_add claude mcp add iclocal --env DFS_PASSWORD=secretpw -- npx -y dataforseo-mcp-server 2>"$SESSION_DIR/ic.err"; echo "block_rc=$?"
  grep -q secretpw "$SESSION_DIR/ic.err" && echo leak=yes || echo leak=no
  CC_ALLOW_INLINE_MCP_SECRET=1 intercept_mcp_add claude mcp add iclocal --env DFS_PASSWORD=secretpw -- npx -y dataforseo-mcp-server 2>/dev/null; echo "optout_rc=$?"')"
if printf '%s' "$icB" | grep -q "block_rc=2" && printf '%s' "$icB" | grep -q "leak=no" \
    && printf '%s' "$icB" | grep -q "optout_rc=1"; then
    ok "intercept_mcp_add: local --env secret blocked (rc2, no leak); CC_ALLOW_INLINE_MCP_SECRET=1 opts out (rc1)"
else
    bad "intercept local-env wrong" "$icB"
fi

# An auth header cc could NOT auto-broker (no remote http(s) URL, or a stdio target) must still be
# BLOCKED, not passed through — otherwise the raw secret rides into the container argv/.claude.json.
icH="$(_mcp_run '
  intercept_mcp_add claude mcp add icnourl --header "Authorization: Bearer sk-noturl" 2>"$SESSION_DIR/ic.err"; echo "nourl_rc=$?"
  grep -q sk-noturl "$SESSION_DIR/ic.err" && echo leak=yes || echo leak=no
  intercept_mcp_add claude mcp add icstdio --header "Authorization: Bearer sk-stdio" -- npx -y some-server 2>/dev/null; echo "stdio_rc=$?"
  CC_ALLOW_INLINE_MCP_SECRET=1 intercept_mcp_add claude mcp add icnourl --header "Authorization: Bearer sk-noturl" 2>/dev/null; echo "optout_rc=$?"')"
if printf '%s' "$icH" | grep -q "nourl_rc=2" && printf '%s' "$icH" | grep -q "leak=no" \
    && printf '%s' "$icH" | grep -q "stdio_rc=2" && printf '%s' "$icH" | grep -q "optout_rc=1"; then
    ok "intercept_mcp_add: unbrokerable auth header (no URL / stdio) blocked (rc2, no leak); opt-out rc1"
else
    bad "intercept unbrokerable-header wrong (should block, not passthrough)" "$icH"
fi

icC="$(_mcp_run '
  intercept_mcp_add claude mcp add plainmcp https://example.com/mcp --transport http 2>/dev/null; echo "nosecret_rc=$?"
  intercept_mcp_add mcp list 2>/dev/null; echo "list_rc=$?"
  intercept_mcp_add claude 2>/dev/null; echo "session_rc=$?"')"
if printf '%s' "$icC" | grep -q "nosecret_rc=1" && printf '%s' "$icC" | grep -q "list_rc=1" \
    && printf '%s' "$icC" | grep -q "session_rc=1"; then
    ok "intercept_mcp_add: passthrough for no-secret add, mcp-list, and a plain session (rc1)"
else
    bad "intercept passthrough wrong" "$icC"
fi
rm -rf "$_mcp_tmp"

# ── 5. regression guards for recent fixes ────────────────────────
sec "Regression guards"

# settings.json must never be bind-mounted from canonical ~/.claude: it is the file a HOST
# `claude` loads, and hooks[].command / apiKeyHelper in it are host code execution from inside
# the sandbox. The box gets a vetted COPY in $SHARED_BASE instead (stage_shared_settings →
# merge_out_shared_settings). Guard the mount line and the fold-back gate together.
# Match on the BIND rather than the filename: the old code took the name from a loop variable
# ($_f), so grepping for "settings.json:" silently never fired. Allow exactly the two legitimate
# $CLAUDE_HOME binds — this project's transcripts, and the ro-by-default asset loop ($_entry) —
# and treat any other as the regression.
stray_home_binds="$(grep -E '^[[:space:]]*ARGS\+=\(-v "\$CLAUDE_HOME/' cc \
    | grep -vE '\$CLAUDE_HOME/projects/\$SLUG:' | grep -vE '\$CLAUDE_HOME/\$_entry:' || true)"
if [ -n "$stray_home_binds" ]; then
    bad "cc bind-mounts canonical ~/.claude content into the container: $(printf '%s' "$stray_home_binds" | tr -s ' ')" \
        "a sandboxed session could then write the settings.json the host claude loads"
elif ! grep -q 'merge_out_shared_settings' cc; then
    bad "merge_out_shared_settings is not called from cc" \
        "in-session settings edits would silently never reach ~/.claude"
else
    ok "settings.json is staged as a vetted copy, never bound from canonical"
fi
# The fold-back must refuse an unvettable file rather than fold it unchecked.
if sed -n '/^merge_out_shared_settings()/,/^}$/p' cc-lib.sh | grep -q 'command -v python3'; then
    ok "settings fold-back refuses to merge when it cannot vet the file"
else
    bad "merge_out_shared_settings folds settings.json back without a python3 vet" \
        "no vet, no fold-back — otherwise a host without python3 loses the protection"
fi

# THE logout regression. The broker must never be handed the live credentials file: Anthropic
# refresh tokens are single-use and rotate, so a broker that reads (let alone refreshes) it
# invalidates the token family for the host CLI and every other project's sidecar. Its secret
# is the static ~/.keep-it-in-your-box/claude-token, mounted READ-ONLY. Guard the mount line
# in cc-lib.sh; tests/broker-test.py guards the Python side. See cc-broker.py's docstring.
# No `sed | grep -q` here: under `set -o pipefail`, grep -q exits on the first match and
# SIGPIPEs the upstream sed, so the pipeline reports 141 and a MATCH reads as a failure.
# Anchoring on `-v "` makes the comment-stripping pass unnecessary anyway.
if grep -qE '^[[:space:]]*-v ".*\.credentials\.json:' cc-lib.sh; then
    bad "cc-lib.sh bind-mounts .credentials.json into the broker" \
        "that is the logout bug — broker the static token file instead (cc --broker-login)"
else
    ok "broker never mounts the live .credentials.json (static token only)"
fi
# Every credential mounted from $KIB_DIR — broker token(s) at /run/broker/token/<id> and each
# hosted-MCP sidecar's cred at /run/cred/<file> — must be READ-ONLY, so there is no write path
# to a credential by construction. Extract each `-v "$KIB_DIR/…"` token (any position on the
# line, so the tok_mounts+=( … ) array form is caught too) and require every one to end :ro".
kib_all="$(grep -oE '\-v "\$KIB_DIR/[^"]*"' cc-lib.sh || true)"
kib_n=$(printf '%s\n' "$kib_all" | grep -c . || true)
if [ "$kib_n" -gt 0 ] && ! printf '%s\n' "$kib_all" | grep -qv ':ro"$'; then
    ok "broker/hosted-MCP credential mounts are all read-only ($kib_n mount(s))"
else
    bad "a \$KIB_DIR credential mount is not read-only" \
        "every -v \"\$KIB_DIR/…\" must end :ro (found $kib_n, at least one without)"
fi

# Screen clearing (removed): cc must not `tput reset` — it wiped a short command's output
# (`-p`, `bash -lc`) and clobbered scrollback when interactive Claude quit. Claude Code's TUI
# manages its own screen, so cc leaves the terminal alone.
if sed 's/#.*$//' cc | grep -qE '\btput[[:space:]]+reset\b'; then
    bad "cc calls 'tput reset'" "removed on purpose — it wiped command output + scrollback"
else
    ok "cc leaves the terminal to Claude's TUI (no 'tput reset')"
fi

# A backgrounded rebuild must not decide "nobody is watching" from the tty alone. setsid drops
# the controlling terminal but leaves fd 1 on the user's terminal, so `[ -t 1 ]` stayed true and
# BuildKit drew its progress UI over the running Claude session while build.log got nothing.
if grep -qE '^if \[ "\$\{1:-\}" != --background \] && \[ -t 1 \]' build-bg.sh \
    && grep -q 'build-bg.sh" --background >/dev/null 2>&1' cc-lib.sh; then
    ok "backgrounded rebuild stays off the terminal (--background + redirect, not just [ -t 1 ])"
else
    bad "background rebuild can stream over the session" \
        "build-bg.sh must honour --background, and cc-lib.sh must pass it AND redirect"
fi

# FUSE reads must be pread, not lseek+read. With nothreads=False several worker threads serve
# one open file and share the fd's offset, so racing lseeks made a reader see the file
# truncated at a 16 KiB boundary — silent corruption that showed up as "flaky" lint/test runs.
if grep -qE '^\s*os\.lseek\(' ccignore-fuse.py; then
    bad "ccignore-fuse.py uses lseek+read/write" \
        "use os.pread/os.pwrite — a shared fd offset truncates concurrent reads at 16 KiB"
elif grep -q 'os.pread(' ccignore-fuse.py && grep -q 'os.pwrite(' ccignore-fuse.py; then
    ok "FUSE passthrough reads/writes are offset-atomic (pread/pwrite, no shared fd offset)"
else
    bad "ccignore-fuse.py lost its pread/pwrite passthrough" "expected os.pread + os.pwrite"
fi

# DNS (broker): resolv-sync must PRESERVE Docker's embedded resolver (127.0.0.11) as the first
# nameserver. When the container joins the broker's user-defined network its resolv.conf becomes
# `nameserver 127.0.0.11`; if the sync overwrites that with the host upstreams, the `cc-broker`
# alias stops resolving mid-session (the ENOTFOUND bug). Runs the REAL script against temp files.
t_resolv_embedded() {
    local dir
    dir="$(mktemp -d)"
    # broker on: DST has the embedded resolver; host SRC has an upstream + the loopback stub.
    printf 'search .\nnameserver 127.0.0.11\noptions ndots:0\n' >"$dir/dst"
    printf '# host\nnameserver 192.168.18.250\nnameserver 127.0.0.53\nsearch lan\n' >"$dir/src"
    CC_RESOLV_DST="$dir/dst" CC_RESOLV_SYNC_INTERVAL=1 sh resolv-sync.sh "$dir/src" 2>/dev/null &
    local pid=$!
    sleep 0.5
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
    local first
    first="$(grep -m1 '^[[:space:]]*nameserver' "$dir/dst" 2>/dev/null | awk '{print $2}')"
    [ "$first" = 127.0.0.11 ] \
        && ok "resolv-sync: embedded DNS (127.0.0.11) kept FIRST — broker alias survives the sync" \
        || bad "resolv-sync embedded DNS" "first nameserver '$first', want 127.0.0.11"
    { grep -q '192.168.18.250' "$dir/dst" && ! grep -q '127.0.0.53' "$dir/dst"; } \
        && ok "resolv-sync: keeps the host upstream, strips the loopback stub" \
        || bad "resolv-sync upstream/stub handling"
    # broker off: DST has no embedded resolver → output is upstreams only (unchanged behaviour).
    printf 'nameserver 10.0.0.1\n' >"$dir/dst2"
    CC_RESOLV_DST="$dir/dst2" sh resolv-sync.sh "$dir/src" 2>/dev/null &
    pid=$!
    sleep 0.5
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
    grep -q '127.0.0.11' "$dir/dst2" \
        && bad "resolv-sync broker-off" "injected 127.0.0.11 where DST had none" \
        || ok "resolv-sync: no embedded DNS present → upstreams only (broker off, unchanged)"
    rm -rf "$dir"
}
t_resolv_embedded

# ── report ───────────────────────────────────────────────────────
printf '\n%s────────────────────────────────────────%s\n' "$D" "$N"
printf '%s%d passed%s' "$G" "$PASS" "$N"
[ "$WARN" -gt 0 ] && printf ', %s%d warnings%s' "$Y" "$WARN" "$N"
[ "$FAIL" -gt 0 ] && printf ', %s%d FAILED%s' "$R" "$FAIL" "$N"
printf '\n'
if [ "$FAIL" -gt 0 ]; then
    printf '\n%sFailed:%s\n' "$B" "$N"
    printf '  %s\n' "${FAILURES[@]}"
fi
exit $((FAIL > 0 ? 1 : 0))
