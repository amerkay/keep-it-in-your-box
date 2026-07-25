#!/usr/bin/env bash
# MCP brokering, host-side: the inline-secret detector, `kib mcp adopt`, `kib mcp add`, and
# the front-line interceptor for a pasted `claude mcp add … --header <secret>`.
#
# All four are thin — parsing, classification and file surgery live in kib.host.mcp. This file
# owns the bash-visible contract: where the files are, and how an outcome maps to an exit code.
#
# Reads:  KIB_DIR PROVIDERS_DIR CLAUDE_JSON KIB_CONFIG PWD KIB_ALLOW_INLINE_MCP_SECRET
# Writes: nothing global

# Warn (never block) if an MCP config carries an inline credential the agent can read. Runs
# on every launch — create and attach — since a user may add one between sessions.
warn_inline_mcp_secrets() {
    have_python || return 0
    kib_py host.mcp warn --claude-json "$CLAUDE_JSON" --mcp-json "$PWD/.mcp.json" || true
}

# Migrate an inline-credential MCP into the broker. Touches the project (.mcp.json), so it
# runs after identity is resolved and never starts a container.
mcp_adopt() {
    local name="${1:-}"
    [ -n "$name" ] || die "usage: kib mcp adopt <server-name>"
    need_python
    kib_py host.mcp adopt "$name" \
        --kib-dir "$KIB_DIR" --providers-dir "$PROVIDERS_DIR" \
        --claude-json "$CLAUDE_JSON" --mcp-json "$PWD/.mcp.json" || return $?
    if broker_wanted; then
        echo "   Relaunch kib to use '$name' through the broker (no header in the sandbox)."
    else
        echo "   The broker is off for this project — re-enable it to use '$name' without" \
            "a header in the sandbox: remove 'broker = off' from $KIB_CONFIG, then relaunch."
    fi
}

# Declare a brokered MCP directly, without first adding it inline. Host-global and
# identity-free, so it works from anywhere.
mcp_add() {
    need_python
    mkdir -p "$PROVIDERS_DIR" && chmod 700 "$PROVIDERS_DIR"
    kib_py host.mcp add --providers-dir "$PROVIDERS_DIR" "$@"
}

# Front-line preventer for the pasted vendor command. Users don't learn kib's flags; they take
# a service's `claude mcp add … --header "Authorization: …"` line and swap `claude` → `kib`.
# Verbatim, that puts the raw secret in the container's argv and then in `.claude.json`. Nothing
# INSIDE the box can fix it — the argv is already there — so it is caught HERE, before exec.
#
# Tri-state exit; the default matters most, since a real session must never be swallowed:
#   1 = NOT an intercept, pass through to a normal launch
#   0 = handled (auto-brokered), kib exits 0
#   2 = blocked, kib exits 2
intercept_mcp_add() {
    # Cheap bash gate: engage only for `[claude] mcp add|add-json`; everything else passes
    # through without spawning python. The leading `claude` token(s) are stripped in a loop
    # (bash-3.2 slice) so the `kib claude` habit cannot slip a secret past the gate.
    local -a a=("$@")
    while [ "${a[0]:-}" = claude ]; do a=("${a[@]:1}"); done
    [ "${a[0]:-}" = mcp ] || return 1
    case "${a[1]:-}" in add | add-json) ;; *) return 1 ;; esac
    # No python → we cannot classify or broker; pass through (rare: python3 is a broker
    # prerequisite anyway).
    have_python || return 1

    mkdir -p "$PROVIDERS_DIR" && chmod 700 "$PROVIDERS_DIR"
    local -a flags=()
    if broker_wanted; then flags+=(--broker-on); fi
    if [ "${KIB_ALLOW_INLINE_MCP_SECRET:-0}" = 1 ]; then flags+=(--allow); fi

    # stdout carries exactly one token; the explanation goes to stderr and is left alone.
    local action
    action="$(kib_py host.mcp intercept \
        --kib-dir "$KIB_DIR" --providers-dir "$PROVIDERS_DIR" \
        ${flags[@]+"${flags[@]}"} -- "${a[@]}")" || return 1
    case "$action" in
        brokered) return 0 ;;
        blocked) return 2 ;;
        *) return 1 ;;
    esac
}
