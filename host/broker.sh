#!/usr/bin/env bash
# Credential broker: keep the real token OUT of the sandbox.
#
# Mounting ~/.claude/.credentials.json read-write into the agent would let a compromised
# session exfiltrate the account token under open egress (audit H3/H4, the widest hole).
# Instead a host-side sidecar holds it and the agent gets a base-URL env var pointing at the
# broker, a PLACEHOLDER token, and a synthetic .credentials.json shadowing the real one: it
# can *use* the API but never read the credential.
#
# THE BROKERED CREDENTIAL IS STATIC — a long-lived token from `kib broker login` (wrapping
# `claude setup-token`), host-only at ~/.keep-it-in-your-box/claude-token, mounted READ-ONLY.
# Not .credentials.json; brokering that live file logged the account out. Never reintroduce a
# refresh path. The broker sits on its own bridge (the `kib-broker` alias) while the main
# container stays multi-homed, so host dev servers and the LAN stay reachable.
# (docs/design-notes/credential-broker.md)
#
# Reads:  KIB_ROOT KIB_CONFIG KIB_CFG_BROKER KIB_BROKER KIB_BROKER_ENDPOINT_MODE
#         CNAME BROKER_CNAME BROKER_NET BROKER_DIR BROKER_OUT BROKER_HASH IMAGE_NAME
#         SHARED_BASE SHARED_CDIR CLAUDE_HOME CRED_WITNESS
# Writes: KIB_DIR BROKER_TOKEN_FILE PROVIDERS_DIR BROKER_ENABLED HOSTED_MCP_UP ARGS
# shellcheck disable=SC2034  # BROKER_ENABLED / HOSTED_MCP_UP are read across the boundary

# The in-container DNS alias for the broker. Load-bearing mid-session: guest/bin/resolv-sync.sh
# keeps 127.0.0.11 first so this keeps resolving, and brokered base_url values embed it.
BROKER_ALIAS="kib-broker"

# Host-only token store, never bind-mounted into the agent — what governs the agent's
# credentials must live where the agent cannot read it. Derived from KIB_CONFIG, one
# definition of "the kib dir".
KIB_DIR="$(dirname "$KIB_CONFIG")"
BROKER_TOKEN_FILE="$KIB_DIR/claude-token"

# User-defined provider definitions (generic MCP brokering, no code change). Exported so every
# kib.broker invocation folds them onto the built-in presets. Host-only; also mounted :ro into
# the broker sidecar, which reads the same var.
PROVIDERS_DIR="$KIB_DIR/providers.d"
export KIB_PROVIDERS_DIR="$PROVIDERS_DIR"

# ON by default — keeping the real token out of the box is the point of the project, not
# something to have to find a config key for. Disable with `broker = off` or KIB_BROKER=0;
# then (or if there is no token and the login is declined) the real .credentials.json is
# exposed to the box instead — see start_broker's fallback.
broker_wanted() {
    case "${KIB_BROKER:-}" in 1) return 0 ;; 0) return 1 ;; esac
    # Enumerating the off spellings rather than testing `!= on` makes a deliberate
    # `broker = false` work while a typo (`broker = of`) fails closed onto the default.
    case "$KIB_CFG_BROKER" in off | 0 | no | false) return 1 ;; esac
    return 0
}

# -s, not -f: an empty file is not a token. The single "is the broker usable" predicate.
broker_has_token() { [ -s "$BROKER_TOKEN_FILE" ]; }

# `id|delivery|credential_kind|token_basename` per line, from kib/broker/registry.py — the
# single source of truth, so a new provider is a row in Python and nothing here.
_broker_list_providers() {
    have_python || return 1
    kib_py broker.cli list-providers 2>/dev/null
}

# Why the registry refused a providers.d file, one `warn` per reason. Runs HOST-side, before
# anything starts: without it these diagnostics reach only the sidecar's stderr — a different
# container, whose log you have to already suspect to go looking at.
_broker_check_providers() {
    have_python || return 0
    local line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        warn "broker: $line"
    done <<EOF
$(kib_py broker.cli check-providers 2>/dev/null)
EOF
}

# The agent-facing URL for one MCP route, from the registry. Empty for an LLM row (reached by
# env var) and for an unknown id. Never hardcode the port here — registry.py owns it.
_broker_route_url() {
    have_python || return 0
    kib_py broker.cli route-url "$1" 2>/dev/null || true
}

# Active ids (host credential file non-empty) whose delivery is in the space-separated set $1,
# in registry order.
_active_providers() {
    local want="$1" id delivery kind basename ids=""
    while IFS='|' read -r id delivery kind basename; do
        [ -n "$id" ] || continue
        case " $want " in *" $delivery "*) ;; *) continue ;; esac
        [ -s "$KIB_DIR/$basename" ] && ids="${ids:+$ids }$id"
    done <<EOF
$(_broker_list_providers)
EOF
    printf '%s' "$ids"
}

# Routes the BROKER SIDECAR serves, vs providers that get their OWN sidecar. The claude row is
# required for the broker to launch (see start_broker); MCP rows are additive and never block
# a launch.
broker_enabled_providers() { _active_providers "base_url_env reverse_proxy_mcp"; }
hosted_mcp_providers() { _active_providers "hosted_mcp"; }

# Fixed at container creation, like the redaction rules: a second terminal must never attach
# under a broker config that changed since the container started. Covers sidecar routes and
# hosted MCPs, so adding or removing either forces a relaunch.
#
# The fingerprint (id|path|upstream per route) is what makes EDITING a def count too: hashing
# ids alone let a changed upstream leave the running sidecar serving the old one while a
# second terminal attached happily. More attach refusals after an edit — that is the point.
broker_config_hash() {
    local fp=""
    have_python && fp="$(kib_py broker.cli route-fingerprint 2>/dev/null)"
    hash8 "$(broker_enabled_providers)|$(hosted_mcp_providers)|$KIB_BROKER_ENDPOINT_MODE|$fp"
}

# Host-facing facts for one provider, from the registry. Sets KIB_BROKER_* in the CALLER's
# scope; non-zero if python3 is missing or the table cannot be read.
_broker_host_config() {
    have_python || return 1
    local out
    out="$(kib_py broker.cli host-config "${1:-claude}" 2>/dev/null)" || return 1
    [ -n "$out" ] || return 1
    eval "$out"
}

# config.json the broker reads: enabled providers + each token's in-broker path. Host-only,
# never mounted into the AGENT.
_write_broker_config() {
    mkdir -p "$BROKER_OUT" && chmod 700 "$BROKER_DIR" "$BROKER_OUT"
    # Same source as broker_config_hash, so the config and the attach-hash cannot disagree.
    local id enabled_json="" token_json="" sep=""
    for id in $(broker_enabled_providers); do
        enabled_json="${enabled_json}${sep}\"$id\""
        token_json="${token_json}${sep}\"$id\": \"/run/broker/token/$id\""
        sep=", "
    done
    printf '{"enabled": [%s], "out_dir": "/run/broker/out", "token_paths": {%s}}\n' \
        "$enabled_json" "$token_json" >"$BROKER_DIR/config.json"
    chmod 600 "$BROKER_DIR/config.json"
}

# Fail-HARD, before the TUI clears the screen, rather than surface a confusing auth error deep
# in the session — the placeholder is shadowed unconditionally, so a dead broker leaks nothing
# but cannot authenticate either. Tears down anything already started.
_broker_abort() {
    teardown_container # stops main (if up) + all sidecars incl. stop_broker
    die "$1" \
        "" \
        "This is a broker STARTUP failure, not an auth problem. The sandbox will not run" \
        "without brokering the credential — the real token must never enter the container." \
        "Fix the cause above and relaunch, or set KIB_BROKER=0 to launch WITHOUT the broker" \
        "(the pre-broker behaviour: the token is mounted into the container)."
}

# Mid-session broker problems as a desktop alert (startup problems already abort loudly).
# Linux-only raw setsid/notify-send, the sanctioned portability-contract exception.
#
# 200>&- 201>&- is LOAD-BEARING: this follower outlives the kib that starts it, and inheriting
# the project's shared lock would stop the last terminal out from tearing the container down.
#
# The budget backs off to one alert per 15 minutes after 3 — the old refresh loop paged every
# 30s indefinitely, which trains you to dismiss the one that matters.
start_broker_notifier() {
    is_macos && return 0
    command -v notify-send >/dev/null 2>&1 || return 0
    # shellcheck disable=SC2016  # the body is the inner sh's script — its $vars are its own
    setsid sh -c '
        last=0; count=0
        docker logs -f "$1" 2>&1 | while IFS= read -r line; do
            case "$line" in BROKER-FATAL*|BROKER-ERR*) ;; *) continue ;; esac
            gap=30; [ "$count" -ge 3 ] && gap=900
            now=$(date +%s)
            [ $((now - last)) -lt $gap ] && continue
            last=$now; count=$((count + 1))
            notify-send -u critical -i dialog-error "kib · credential broker" "$2" || true
        done' _ "$BROKER_CNAME" \
        "The credential broker could not reach the API or use its token. Check: kib broker status. Project: $(basename "$PWD")" \
        >/dev/null 2>&1 200>&- 201>&- &
    echo $! >"$BROKER_DIR/notify.pid"
}

# Placeholder minted and port bound — or died trying, in which case the caller dumps the log.
_broker_ready_or_dead() { [ -f "$BROKER_OUT/ready" ] || ! broker_running; }

# Bring the sidecar up on its own bridge and wait for it to be ready. CREATE path only, under
# the boot lock, before the main container's docker run. No-op when the broker is not wanted.
start_broker() {
    broker_wanted || return 0
    _broker_check_providers # say what the registry refused, before it matters
    if ! broker_has_token; then
        # A first launch with no token is normal, not an error: run the one-time login here.
        # The subshell isolates provider_login's `exit` on empty input, so a declined login
        # falls through to the fallback instead of killing the launch.
        if [ -t 0 ]; then
            echo "🔐 credential broker is on, but no token is stored yet." >&2
            echo "   Starting a one-time login so the real token never enters the sandbox…" >&2
            echo >&2
            (provider_login claude) || true
            echo >&2
        fi
        if ! broker_has_token; then
            # Headless, or the login was declined: fall back to the pre-broker path. Because
            # BROKER_ENABLED stays 0, stage_credential exposes the real credential to the
            # box. The STATIC broker token still never enters the sandbox.
            warn "credential broker: no token — this session uses the real credential instead." \
                "Mint a broker token any time so the real one stays host-only: kib broker login"
            return 0
        fi
    fi
    _write_broker_config # creates $BROKER_OUT / $BROKER_DIR (chmod 700)
    rm -f "$BROKER_OUT/ready" 2>/dev/null || true

    if ! docker network inspect "$BROKER_NET" >/dev/null 2>&1; then
        docker network create "$BROKER_NET" >/dev/null 2>&1 \
            || _broker_abort "could not create the broker network ($BROKER_NET)."
    fi

    # One read-only token mount per SIDECAR-SERVED route, at /run/broker/token/<id> (the path
    # _write_broker_config puts in token_paths).
    local id delivery kind basename
    local -a tok_mounts=()
    while IFS='|' read -r id delivery kind basename; do
        case "$delivery" in base_url_env | reverse_proxy_mcp) ;; *) continue ;; esac
        [ -s "$KIB_DIR/$basename" ] || continue
        tok_mounts+=(-v "$KIB_DIR/$basename:/run/broker/token/$id:ro")
    done <<EOF
$(_broker_list_providers)
EOF

    # cap-drop=ALL, no devices. Tokens are mounted here only and READ-ONLY, so the broker has
    # no write path to any credential by construction rather than by discipline.
    local -a prov_mount=()
    [ -d "$PROVIDERS_DIR" ] && prov_mount=(
        -v "$PROVIDERS_DIR:/run/broker/providers.d:ro"
        -e KIB_PROVIDERS_DIR=/run/broker/providers.d)

    local -a broker_run=(
        docker run -d --name "$BROKER_CNAME"
        --cap-drop=ALL --security-opt no-new-privileges
        --user "$(id -u):$(id -g)" --userns=host
        --network "$BROKER_NET" --network-alias "$BROKER_ALIAS"
        ${tok_mounts[@]+"${tok_mounts[@]}"}
        ${prov_mount[@]+"${prov_mount[@]}"}
        -v "$BROKER_OUT:/run/broker/out"
        -v "$BROKER_DIR/config.json:/run/broker/config.json:ro"
        -v /etc/passwd:/etc/passwd:ro
        -v /etc/group:/etc/group:ro
        -v "$KIB_ROOT/kib:/usr/local/lib/kib:ro"
        --entrypoint /usr/local/bin/broker
        "$IMAGE_NAME"
        serve /run/broker/config.json
    )
    if ! "${broker_run[@]}" >/dev/null 2>&1; then
        _broker_abort "could not start the credential broker sidecar."
    fi

    wait_until 100 0.05 _broker_ready_or_dead # ≤5s to mint the placeholder + bind
    if [ ! -f "$BROKER_OUT/ready" ]; then
        echo "❌ broker: sidecar never became ready; logs:" >&2
        docker logs "$BROKER_CNAME" 2>&1 | tail -10 | sed 's/^/   /' >&2 || true
        # Only the claude route can get here: a user MCP that cannot come up is skipped by
        # name (see the `broken` file below), never fatal.
        _broker_abort "the credential broker could not serve the Claude route."
    fi

    # Routes that were skipped. The sidecar writes this BEFORE `ready`, so by now it is
    # complete — warn per route and carry on, which is the whole fail-soft split.
    if [ -s "$BROKER_OUT/broken" ]; then
        local bid breason
        while read -r bid breason; do
            [ -n "$bid" ] || continue
            warn "broker route '$bid' did not come up: $breason." \
                "The session continues without it; every other route is up."
        done <"$BROKER_OUT/broken"
    fi

    broker_config_hash >"$BROKER_HASH"
    start_broker_notifier
    BROKER_ENABLED=1
    echo "🔐 credential broker: active — the real token is NOT in the sandbox (sidecar: $BROKER_CNAME)." >&2

    # Both fail-SOFT — a broken MCP must never block the session the way a broker startup
    # failure does.
    start_hosted_mcp
    inject_brokered_mcps
}

# ── Hosted MCP sidecars ──────────────────────────────────────────
# For a LOCAL/client-signed MCP that cannot be header-brokered: the server runs in its own
# cap-drop=ALL sidecar on the broker network holding its credential :ro, and the agent reaches
# it at http://<id>:<port><mcp_path>, so the secret never enters the agent container.
# supergateway bridges stdio to streamable-HTTP. FAIL-SOFT — warn and skip, never abort.
HOSTED_MCP_UP="" # space-separated ids whose sidecar came up (read by inject_brokered_mcps)
start_hosted_mcp() {
    local ids id
    ids="$(hosted_mcp_providers)"
    [ -n "$ids" ] || return 0
    for id in $ids; do
        local KIB_BROKER_TOKEN_BASENAME="" KIB_BROKER_CREDENTIAL_ENV="" KIB_BROKER_MCP_PORT="" \
            KIB_BROKER_HOST_RUN="" KIB_BROKER_EXTRA_ENV=""
        if ! _broker_host_config "$id"; then
            warn "hosted MCP '$id': could not read its host-config — skipping."
            continue
        fi
        if [ -z "$KIB_BROKER_HOST_RUN" ] || [ -z "$KIB_BROKER_MCP_PORT" ] \
            || [ -z "$KIB_BROKER_TOKEN_BASENAME" ]; then
            warn "hosted MCP '$id': incomplete registry entry — skipping."
            continue
        fi

        local hmcp_cname="${CNAME}-hmcp-${id}"
        docker rm -f "$hmcp_cname" >/dev/null 2>&1 || true # clear a crashed leftover
        # extra_env (KEY=VAL, constants) → -e flags; word-split is safe (no metacharacters).
        local -a env_args=() kv
        for kv in $KIB_BROKER_EXTRA_ENV; do env_args+=(-e "$kv"); done
        local -a run=(
            docker run -d --name "$hmcp_cname"
            --cap-drop=ALL --security-opt no-new-privileges
            --user "$(id -u):$(id -g)" --userns=host
            --network "$BROKER_NET" --network-alias "$id"
            -v "$KIB_DIR/$KIB_BROKER_TOKEN_BASENAME:/run/cred/$KIB_BROKER_TOKEN_BASENAME:ro"
            -e "$KIB_BROKER_CREDENTIAL_ENV=/run/cred/$KIB_BROKER_TOKEN_BASENAME"
            -e "HOME=/tmp" -e "UV_CACHE_DIR=/tmp/.uv" -e "npm_config_cache=/tmp/.npm"
            ${env_args[@]+"${env_args[@]}"}
            -v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro
            --entrypoint sh "$IMAGE_NAME"
            -c "exec npx -y supergateway --stdio \"$KIB_BROKER_HOST_RUN\" --outputTransport streamableHttp --port $KIB_BROKER_MCP_PORT --host 0.0.0.0"
        )
        if "${run[@]}" >/dev/null 2>&1; then
            HOSTED_MCP_UP="${HOSTED_MCP_UP:+$HOSTED_MCP_UP }$id"
            echo "🔐 hosted MCP '$id': sidecar up (cred stays host-side: $hmcp_cname)." >&2
        else
            warn "hosted MCP '$id': sidecar failed to start — the agent will launch without it."
        fi
    done
}

# The registry walk, the URL construction and the marker-aware rewrite all live in
# kib.host.mcp; this is only the "which sidecars came up" fact bash owns.
inject_brokered_mcps() {
    [ "$BROKER_ENABLED" = 1 ] || return 0
    have_python || return 0
    kib_py host.mcp inject \
        --config "$SESSION_BASE/.claude.json" \
        --kib-dir "$KIB_DIR" \
        --broker-host "$BROKER_ALIAS" \
        --hosted-up "$HOSTED_MCP_UP" \
        || warn "could not inject brokered MCP entries into .claude.json"
}

# Agent-facing wiring appended to the main container's ARGS. All three parts are needed:
#   1. the base URL, so the SDK talks to the broker instead of api.anthropic.com;
#   2. a PLACEHOLDER token, which takes precedence over the credentials file;
#   3. a synthetic .credentials.json shadowing the real one — (2) alone would leave a real file
#      readable in the shared-assembly dir, which is the whole exposure. Delivered as a flat
#      :ro bind via bind_via_link — see _stage_placeholder_credential for why the mount, and
#      not a mode bit, is what makes it read-only.
add_broker_env_args() {
    [ "$BROKER_ENABLED" = 1 ] || return 0
    # reverse_proxy_mcp rows need nothing here — the agent reaches them via the .claude.json
    # URL, not an env var.
    local id
    for id in $(broker_enabled_providers); do
        local KIB_BROKER_BASE_URL_ENV="" KIB_BROKER_TOKEN_ENV="" KIB_BROKER_PLACEHOLDER_TOKEN="" \
            KIB_BROKER_LISTEN_PORT="" KIB_BROKER_PLACEHOLDER_CONTAINER_PATH="" KIB_BROKER_DELIVERY=""
        _broker_host_config "$id" \
            || _broker_abort "could not read the broker's host-config for '$id'."
        [ "$KIB_BROKER_DELIVERY" = base_url_env ] || continue
        if [ -z "$KIB_BROKER_BASE_URL_ENV" ] || [ -z "$KIB_BROKER_TOKEN_ENV" ] \
            || [ -z "$KIB_BROKER_PLACEHOLDER_TOKEN" ] || [ -z "$KIB_BROKER_LISTEN_PORT" ]; then
            _broker_abort "the broker's host-config for '$id' is incomplete."
        fi
        ARGS+=(
            -e "$KIB_BROKER_BASE_URL_ENV=http://$BROKER_ALIAS:$KIB_BROKER_LISTEN_PORT"
            -e "$KIB_BROKER_TOKEN_ENV=$KIB_BROKER_PLACEHOLDER_TOKEN"
        )
        # Only claude shadows a real credential file; codex/gemini have none to overlay.
        if [ -n "$KIB_BROKER_PLACEHOLDER_CONTAINER_PATH" ]; then
            _stage_placeholder_credential "$id" "$KIB_BROKER_PLACEHOLDER_CONTAINER_PATH"
        fi
    done
}

# The registry names where the placeholder lands in the container; the only such path kib can
# write to from here is the shared-assembly dir, which the container sees at $SHARED_CDIR.
#
# Read-only is a :ro MOUNT, not a mode bit. Docker Desktop backs every bind with `fakeowner`,
# which stores the mode faithfully but ignores it in access(2) — a 0400 file there is still
# writable, so the copy+chmod this used to do was a no-op on macOS and the placeholder shipped
# writable. Nothing refreshes it under the broker, so a single-file bind carries none of the
# rename risk the real rotating credential does. bind_via_link because the destination would
# otherwise nest inside the shared-dir bind, which aborts the whole `docker run`.
_stage_placeholder_credential() { # <provider id> <container path>
    case "$2" in
        "$SHARED_CDIR"/*) ;;
        *) _broker_abort "the broker's placeholder path for '$1' is not in the shared dir: $2" ;;
    esac
    local rel="${2#"$SHARED_CDIR"/}"
    local link="$SHARED_BASE/$rel" src="$BROKER_OUT/$1.cred.json"
    [ -f "$src" ] || _broker_abort "the broker staged no placeholder credential for '$1'."
    chmod 0400 "$src" 2>/dev/null || true # belt and braces on hosts where the mode does count
    bind_via_link "$src" "$PLACEHOLDER_CRED_CPATH-$1" "$link" :ro
}

# ── Fallback credential (broker off, or on-but-no-token) ─────────
# Without a synthetic file to shadow, in-sandbox Claude needs the real .credentials.json — the
# pre-broker behaviour. COPY it into the shared-assembly DIRECTORY, never a single-file bind:
# rename(2) onto one fails EBUSY, and a torn in-place write to a rotating OAuth credential logs
# the account out. The copy folds back to canonical on exit only if it changed; $CRED_WITNESS
# records that it was staged, so ANY terminal can fold back, not just the one that staged.
stage_credential() {
    if [ "$BROKER_ENABLED" = 1 ]; then
        # Drop any real credential a previous broker-off session left in this scratch dir.
        rm -f "$SHARED_BASE/.credentials.json" "$CRED_WITNESS" 2>/dev/null || true
        return 0
    fi
    # Mark BEFORE the copy: with nothing to copy (never logged in), an in-box login still
    # writes a credential here that has to be folded back out on exit.
    : >"$CRED_WITNESS" 2>/dev/null || true
    [ -f "$CLAUDE_HOME/.credentials.json" ] || return 0 # never logged in — nothing to copy
    # Unlink first: the broker-on path leaves a 0400 synthetic file here (and an older kib left
    # a root-owned Docker mountpoint), so switching the broker off would hit a cp that cannot
    # overwrite — the symptom is an unexplained login prompt.
    rm -f "$SHARED_BASE/.credentials.json" 2>/dev/null || true
    (
        umask 077
        cp "$CLAUDE_HOME/.credentials.json" "$SHARED_BASE/.credentials.json"
    ) \
        || warn "could not stage the real credential into the session (login may be needed in-box)."
}

# Fold a fallback-staged credential back to canonical on exit, if an in-box OAuth refresh
# rewrote it. Under the caller's flock on ~/.claude.json.lock. No-op unless staged/changed.
merge_out_credential() {
    [ -f "${CRED_WITNESS:-}" ] || return 0
    local src="$SHARED_BASE/.credentials.json" dst="$CLAUDE_HOME/.credentials.json"
    [ -f "$src" ] || return 0
    cmp -s "$src" "$dst" 2>/dev/null && return 0 # unchanged — do not touch canonical
    if ! (
        umask 077
        cp "$src" "$dst.kib.tmp"
    ) || ! mv -f "$dst.kib.tmp" "$dst"; then
        rm -f "$dst.kib.tmp" 2>/dev/null || true
        warn "could not fold the refreshed credential back to ~/.claude/.credentials.json."
    fi
}

# ── Container-level broker wiring ────────────────────────────────
# Dual-home the main container onto the broker net AFTER its docker run: a single --network at
# run time would REPLACE the default bridge, whereas connecting a second net keeps both and
# adds Docker's embedded resolver so `kib-broker` resolves. Fail-hard — no route means no auth.
connect_broker_network() {
    [ "$BROKER_ENABLED" = 1 ] || return 0
    docker network connect "$BROKER_NET" "$CNAME" >/dev/null 2>&1 \
        || _broker_abort "could not attach the container to the broker network ($BROKER_NET)."
}

# Attach-path refusal: a second terminal must not attach to a container running WITHOUT the
# broker (its real token would be mounted) or under a since-changed broker config.
verify_broker_attach() {
    broker_wanted || return 0
    broker_has_token || return 0
    if ! broker_running; then
        die "the credential broker is requested, but this project's container is running" \
            "WITHOUT it — so the real token is mounted, defeating the broker. Refusing to" \
            "attach. Close all kib sessions for this project and relaunch. (A container" \
            "created before the broker existed, or with KIB_BROKER=0, always lands here.)"
    fi
    if [ "$(cat "$BROKER_HASH" 2>/dev/null || true)" != "$(broker_config_hash)" ]; then
        die "the credential-broker configuration changed since this project's container" \
            "started. Refusing to attach under stale broker settings — close all kib" \
            "sessions for this project and relaunch."
    fi
}

stop_broker() {
    kill_pgrp "$BROKER_DIR/notify.pid" # whole group: the notifier is a setsid'd pipeline
    docker rm -f "$BROKER_CNAME" >/dev/null 2>&1 || true
    # Hosted-MCP sidecars share the broker net and must go before `network rm`. Match by the
    # ${CNAME}-hmcp-* name prefix so we get every one without tracking their ids here.
    local hm
    for hm in $(docker ps -aq -f "name=^${BROKER_CNAME%-broker}-hmcp-" 2>/dev/null); do
        docker rm -f "$hm" >/dev/null 2>&1 || true
    done
    # The main container must be gone first (teardown_container stops it before calling this),
    # or the network still has an endpoint and rm fails — harmless, it is retried next time.
    docker network rm "$BROKER_NET" >/dev/null 2>&1 || true
    rm -rf "$BROKER_DIR" 2>/dev/null || true
}

# ── Credential lifecycle: kib broker login|logout|status|probe ───
# All run HOST-SIDE and exit before any container work, so they work while the sandbox is
# broken or unbuilt. None ever prints a credential. Registry-driven: a new provider row in
# Python makes `kib broker login <that-id>` work with no change here.

# Resolve one provider from the registry. Sets _P_DELIVERY/_P_KIND/_P_BASENAME/_P_FILE in the
# caller's scope; returns 1 for an unknown id.
_provider_lookup() {
    local id delivery kind basename
    _P_DELIVERY=""
    _P_KIND=""
    _P_BASENAME=""
    _P_FILE=""
    while IFS='|' read -r id delivery kind basename; do
        [ "$id" = "$1" ] || continue
        _P_DELIVERY="$delivery"
        _P_KIND="$kind"
        _P_BASENAME="$basename"
        _P_FILE="$KIB_DIR/$basename"
        return 0
    done <<EOF
$(_broker_list_providers)
EOF
    return 1
}

_provider_ids_csv() {
    local id rest out=""
    while IFS='|' read -r id rest; do out="${out:+$out, }$id"; done <<EOF
$(_broker_list_providers)
EOF
    printf '%s' "$out"
}

# Atomic mode-600 write of a secret (never briefly world-readable). The bash copy exists for
# secrets that are shell variables; kib.broker.helpers.store_secret covers the Python paths.
_store_secret_file() {
    local tmp="$1.tmp.$$"
    (
        umask 077
        printf '%s\n' "$2" >"$tmp"
    ) || die "could not write $1"
    if ! chmod 600 "$tmp" || ! mv -f "$tmp" "$1"; then
        rm -f "$tmp"
        die "could not install $1"
    fi
}

# Per-provider "how to obtain it" guidance (human hints, not machine facts — kept here rather
# than in the registry so the table stays word-splittable).
_provider_login_hint() {
    case "$1" in
        claude)
            if command -v claude >/dev/null 2>&1; then
                echo "   Running \`claude setup-token\`; complete the browser flow, then copy the"
                echo "   token it prints (starts sk-ant-oat01-)."
                echo
                claude setup-token || echo "   ⚠️  claude setup-token exited non-zero — paste a token anyway, or Ctrl-C." >&2
            else
                echo "   \`claude\` is not on PATH — run this on the host and copy the token:"
                echo "     claude setup-token"
            fi
            ;;
        codex) echo "   Create an OpenAI API key (starts sk-…): https://platform.openai.com/api-keys" ;;
        gemini) echo "   Create a Gemini API key: https://aistudio.google.com/apikey" ;;
        # Everything else is a user-defined MCP (providers.d/); service-specific guidance
        # lives with its provider def (e.g. examples/providers/*.json), not in this table.
        *) if [ "$_P_KIND" = file_path ]; then
            echo "   Provide the path to the credential file for '$1'."
        else
            echo "   Paste the credential for '$1'."
        fi ;;
    esac
    echo
}

# Add (or replace) a provider credential, stored HOST-ONLY. paste_token → hidden paste;
# file_path → copy a file the user names. Then probe (advisory).
provider_login() {
    local id="${1:-claude}"
    need_python
    _provider_lookup "$id" || die "unknown provider: $id" "known: $(_provider_ids_csv)"
    [ -t 0 ] || die "kib broker login needs an interactive terminal."
    mkdir -p "$KIB_DIR" && chmod 700 "$KIB_DIR"

    echo "🔐 kib broker login $id — add a credential the broker injects for you."
    echo "   Stored HOST-ONLY at: $_P_FILE"
    echo "   (mounted read-only into the broker; it never enters the sandbox)."
    echo
    _provider_login_hint "$id"

    if [ "$_P_KIND" = file_path ]; then
        local path=""
        printf '   Path to the credential file: '
        read -r path || true
        # shellcheck disable=SC2088  # expanding a tilde the USER typed, on purpose
        case "$path" in "~/"*) path="$HOME/${path#\~/}" ;; esac
        [ -n "$path" ] || die "no path entered — nothing was written."
        [ -f "$path" ] || die "no such file: $path"
        (
            umask 077
            cp "$path" "$_P_FILE.tmp.$$"
        ) || die "could not read $path"
        if ! chmod 600 "$_P_FILE.tmp.$$" || ! mv -f "$_P_FILE.tmp.$$" "$_P_FILE"; then
            rm -f "$_P_FILE.tmp.$$"
            die "could not install $_P_FILE"
        fi
        echo "   ✅ copied to $_P_FILE (mode 600)."
    else
        local secret=""
        printf '   Paste the credential (input hidden), then Enter: '
        read -rs secret || true
        echo
        case "$secret" in
            "") die "nothing entered — nothing was written." ;;
            *[!\ -~]*) die "that contains control characters — not stored." ;;
        esac
        # Claude token shape is advisory only; the probe decides. Others accept anything.
        if [ "$id" = claude ]; then
            case "$secret" in
                sk-ant-oat01-* | sk-ant-api*) ;;
                *) echo "   ⚠️  that doesn't start with sk-ant-oat01-/sk-ant-api — storing anyway; the probe decides." >&2 ;;
            esac
        fi
        _store_secret_file "$_P_FILE" "$secret"
        unset secret
        echo "   ✅ stored (mode 600)."
    fi
    echo
    provider_probe "$id" || _login_ok_after_probe "$?"
}

# Map a probe exit status to login's: a successful store is a successful login UNLESS the
# probe definitively rejected the credential (1). 0 (accepted) and 2 (inconclusive) both keep
# login successful. Factored out so the check suite can assert the truth table directly.
_login_ok_after_probe() { [ "$1" != 1 ]; }

# Remove a provider credential. The sandbox's own credential is untouched.
provider_logout() {
    local id="${1:-claude}"
    _provider_lookup "$id" || die "unknown provider: $id" "known: $(_provider_ids_csv)"
    if [ ! -e "$_P_FILE" ]; then
        echo "🔐 no stored credential for '$id' at $_P_FILE — nothing to remove."
        return 0
    fi
    rm -f "$_P_FILE" || die "could not remove $_P_FILE"
    echo "🔐 removed $_P_FILE"
    [ "$id" = claude ] && echo "   Revoke it at https://console.anthropic.com/settings/keys if it may have leaked."
    echo "   Re-add with: kib broker login $id"
    if [ "$id" = claude ] && broker_wanted; then
        echo "   The broker is ENABLED: until you do, the next launch offers the login and,"
        echo "   if you decline it, falls back to mounting the real credential."
    fi
}

# Ask the upstream whether a stored credential is accepted. Exit status mirrors
# `kib broker probe`: 0 accepted, 1 rejected, 2 inconclusive (incl. no probe defined).
provider_probe() {
    local id="${1:-claude}"
    need_python
    _provider_lookup "$id" || return 1
    [ -s "$_P_FILE" ] || {
        echo "🔐 no credential stored for '$id' ($_P_FILE)"
        return 1
    }
    echo "   checking the stored credential for '$id'…"
    kib_py broker.cli probe "$_P_FILE" "$id"
}

# Status of EVERY registry provider (never prints contents — size/mode only), plus the defs
# the registry REFUSED — which otherwise have no row anywhere and are invisible until a launch.
provider_status() {
    echo "🔐 credential broker"
    echo "   enabled:  $(broker_wanted && echo yes || echo "no  (turned off by 'broker = off' in $KIB_CONFIG, or KIB_BROKER=0)")"
    local id delivery kind basename file mode size url
    while IFS='|' read -r id delivery kind basename; do
        file="$KIB_DIR/$basename"
        if [ -s "$file" ]; then
            # shellcheck disable=SC2012  # `stat` spells the mode differently on GNU vs BSD;
            # `ls -l` is the portable read, and $file is ours (no odd names).
            mode="$(ls -l "$file" 2>/dev/null | cut -c1-10)"
            size="$(wc -c <"$file" 2>/dev/null | tr -d ' ')"
            printf '   %-11s stored  (%s bytes, %s) [%s]\n' "$id" "$size" "$mode" "$delivery"
        else
            printf '   %-11s —       add: kib broker login %s   [%s]\n' "$id" "$id" "$delivery"
        fi
        # MCP rows only: an LLM row is reached by env var, and asking would be three python
        # spawns per status to be told "no URL".
        case "$delivery" in
            base_url_env) ;;
            *)
                url="$(_broker_route_url "$id")"
                [ -n "$url" ] && printf '   %-11s   → %s\n' "" "$url"
                ;;
        esac
    done <<EOF
$(_broker_list_providers)
EOF
    echo
    _broker_check_providers
    if broker_has_token; then
        echo
        provider_probe claude # propagate its tri-state: 0 accepted / 1 rejected / 2 unknown
        return $?             # so `kib broker status` distinguishes a revoked token
    fi
    return 1 # no claude token stored → the required credential is absent
}

# ── kib broker add: one command from "I want this MCP" to a live route ──
# `kib mcp add` stays the non-interactive machinery (adopt and intercept share it); this closes
# its one real gap — it wrote a def and then told you to run a SECOND command. Bash only ever
# detects "no args and a tty → ask the questions"; every flag goes to argparse, because a
# hand-rolled flag parser is a bug this repo has already paid for once (kib/shared/cli.py).

_ADD_ARGV=() # set by the wizard, consumed by provider_add

# Ask the four or five things a route needs. Never touches a credential: provider_login does
# that, with a hidden read, once the def is proven loadable.
_broker_add_wizard() {
    local kind="" name="" why="" url="" header="" runcmd="" cred_env="" cred_kind=""
    echo "🔐 kib broker add — put a service's MCP behind the credential broker."
    echo "   The credential is stored HOST-ONLY; the sandbox gets a header-free URL and"
    echo "   never sees the secret. No port to pick — every route shares one, by name."
    echo
    echo "   1) remote — the service hosts the MCP; one static header authenticates you"
    echo "   2) local  — a server you run (npx/uvx) that reads a key file or env var"
    printf '   Which? [1] '
    read -r kind || true

    while :; do
        printf '   Short name for the route (lowercase, e.g. directus): '
        read -r name || true
        [ -n "$name" ] || die "nothing entered — nothing was written."
        # One validator for bash and python: the name is a filename stem, a URL path segment
        # and a word-split field all at once.
        why="$(kib_py broker.cli check-name "$name" 2>/dev/null)" && break
        echo "   ⚠️  $why" >&2
    done

    if [ "$kind" = 2 ]; then
        printf '   Command that runs the server (e.g. uvx mcp-search-console): '
        read -r runcmd || true
        [ -n "$runcmd" ] || die "no command entered — nothing was written."
        printf '   Env var the server reads its credential from (e.g. GSC_CREDENTIALS_PATH): '
        read -r cred_env || true
        [ -n "$cred_env" ] || die "no env var entered — nothing was written."
        printf '   Is that credential a pasted token or a file path? [token/file] '
        read -r cred_kind || true
        case "$cred_kind" in f | file) cred_kind="file" ;; *) cred_kind="token" ;; esac
        _ADD_ARGV=("$name" --run "$runcmd" --cred-env "$cred_env" --cred-kind "$cred_kind")
    else
        printf '   The MCP endpoint URL (https://…): '
        read -r url || true
        [ -n "$url" ] || die "no URL entered — nothing was written."
        printf '   Auth header the service wants [Authorization: Bearer]: '
        read -r header || true
        [ -n "$header" ] || header="Authorization: Bearer"
        _ADD_ARGV=("$name" --url "$url" --header "$header")
    fi
    echo
}

# Prove the def we just wrote is a ROUTE, then chain the credential and say where it lands.
_broker_add_finish() {
    local id="$1" url=""
    # The end-to-end guarantee, and the reason `add` is not just `mcp add`: re-read the
    # registry. If the id is absent, the file was written but refused, and the user hears it
    # now rather than at a launch three days later.
    if ! _provider_lookup "$id"; then
        echo "❌ the definition was written, but the broker will not load it:" >&2
        _broker_check_providers
        die "'$id' is not a usable route — fix or remove $PROVIDERS_DIR/$id.json"
    fi
    if [ -t 0 ]; then
        echo "   Now its credential — stored host-only, mode 600, never in the sandbox."
        echo
        # A subshell: provider_login exits on empty input, which must not read as "add failed"
        # after the def landed successfully.
        (provider_login "$id") \
            || warn "no credential stored yet — add it with: kib broker login $id"
    fi # non-interactive: `mcp add` already printed the `kib broker login` line
    url="$(_broker_route_url "$id")"
    echo
    echo "🔐 route '$id' is defined."
    [ -n "$url" ] && echo "   The agent will reach it at $url — no header, no token in the box."
    if broker_wanted; then
        echo "   It appears in the NEXT container: close every kib session for the project,"
        echo "   then relaunch."
    else
        echo "   ⚠️  The broker is off, so this route is not active yet. Enable it:"
        echo "        echo 'broker = on' >> $KIB_CONFIG"
    fi
}

# `kib broker add [<name> --url … | <name> --run … --cred-env …]`. Bare + a tty asks instead.
provider_add() {
    need_python
    mkdir -p "$PROVIDERS_DIR" && chmod 700 "$PROVIDERS_DIR"
    local -a argv=("$@")
    if [ $# -eq 0 ]; then
        [ -t 0 ] || die "kib broker add needs a terminal, or the flags:" \
            "kib broker add <name> --url <https-url> [--header \"Name: Scheme\"]" \
            "kib broker add <name> --run \"<cmd>\" --cred-env <ENV> [--cred-kind file]"
        _broker_add_wizard
        argv=(${_ADD_ARGV[@]+"${_ADD_ARGV[@]}"})
    fi
    # :- because an empty array under `set -u` aborts the launch silently, which is a failure
    # mode this repo has already been bitten by.
    case "${argv[0]:-}" in
        "" | -*) die "kib broker add: the route name comes first" \
            "e.g. kib broker add linear --url https://mcp.linear.app/sse" ;;
    esac
    kib_py host.mcp add --providers-dir "$PROVIDERS_DIR" "${argv[@]}" || return $?
    _broker_add_finish "${argv[0]}"
}

_broker_usage() {
    cat <<'USAGE'
kib broker — the credential broker's host-only credentials and routes.

  kib broker add [name …]      define a brokered MCP  (bare = ask the questions)
  kib broker login [name]      store a credential, host-only, mode 600
  kib broker logout [name]     remove one
  kib broker status            every route: credential, URL, and any refused definition
  kib broker probe [name]      does the stored credential still work upstream?

  kib broker add linear --url https://mcp.linear.app/sse --header "Authorization: Bearer"
  kib broker add gsc --run "uvx mcp-search-console" --cred-env GSC_CREDENTIALS_PATH \
      --cred-kind file --env GSC_SKIP_OAUTH=true

Routes need no port: they share one listener and are told apart by name. Every verb runs
host-side and never starts a container, so they work while the sandbox is broken or unbuilt.
USAGE
}

# `kib broker <verb> [provider]`. Every verb is registry-driven and defaults to claude.
broker_cli() {
    local verb="${1:-status}"
    shift 2>/dev/null || true
    case "$verb" in
        add) provider_add "$@" ;;
        login) provider_login "${1:-claude}" ;;
        logout) provider_logout "${1:-claude}" ;;
        probe) provider_probe "${1:-claude}" ;;
        status) provider_status ;;
        help | -h | --help) _broker_usage ;;
        *)
            printf '❌ kib: unknown broker verb %s\n\n' "$verb" >&2
            _broker_usage >&2
            exit 2
            ;;
    esac
}
