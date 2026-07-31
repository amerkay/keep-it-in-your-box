#!/usr/bin/env bash
# Sourced by tests/check.sh — the `kib --publish PORT` path, host side.
#
# No docker here, so the three halves are checked where they live: the launcher's pre-verb flag
# parse (bin/kib), the validate/sticky/args logic (host/net.sh, run for real against a throwaway
# table), and the create-vs-attach wiring (host/lifecycle.sh, source-level).

# shellcheck source=SCRIPTDIR/_guard.sh
. "${BASH_SOURCE%/*}/_guard.sh" # sourced by tests/check.sh, never run directly

section "Publish flag (bin/kib, host/net.sh)"

_pb_kib() { KIB_CONFIG="$(mktemp -u)" bash "$KIB_ROOT/bin/kib" "$@" 2>&1; }

# The verb table rejects any unknown first token, so a flag that is not stripped BEFORE it would
# be reported as the bad verb — and the real one would never be seen.
out="$(_pb_kib --publish=3000 badverb)"
case "$out" in
    *"unknown verb badverb"*) pass "--publish is stripped before verb dispatch" ;;
    *) fail "--publish=3000 badverb did not report badverb" "got: $(printf %s "$out" | head -1)" ;;
esac

out="$(_pb_kib --publish=3000,5173 badverb)"
case "$out" in
    *"unknown verb badverb"*) pass "the --publish=N,N list form is stripped too" ;;
    *) fail "the list form was not stripped" "got: $(printf %s "$out" | head -1)" ;;
esac

# The separated form must consume its value, or the port number itself becomes the verb.
out="$(_pb_kib --publish 3000 badverb)"
case "$out" in
    *"unknown verb badverb"*) pass "--publish PORT consumes its value" ;;
    *) fail "--publish 3000 badverb did not report badverb" "got: $(printf %s "$out" | head -1)" ;;
esac

out="$(_pb_kib --publish)"
case "$out" in
    *"needs a value"*) pass "--publish with no value is refused" ;;
    *) fail "bare --publish was not refused" "got: $(printf %s "$out" | head -1)" ;;
esac

case "$(_pb_kib help)" in
    *--publish*) pass "the flag is in the usage table" ;;
    *) fail "kib help does not mention --publish" "an undiscoverable flag" ;;
esac

# ── Validation, stickiness and the docker args, run for real ─────
# Each call is a subshell: `die` exits, and the prefix-assignment form would not survive anyway.
_pb_conf="$(mktemp -d)/published-ports"
_pb() { # <pwd> <flag list>  -> "resolved list|-p args…", or the die message
    (
        # shellcheck source=/dev/null
        . "$KIB_ROOT/host/core.sh"
        # shellcheck disable=SC2034  # read by the sourced host/net.sh
        KIB_PUBLISH_CONF="$_pb_conf"
        # shellcheck source=/dev/null
        . "$KIB_ROOT/host/net.sh"
        PWD="$1"
        PUBLISH_LIST="$2"
        ARGS=()
        publish_ports_resolve
        publish_ports_confirm >/dev/null 2>&1
        add_publish_args
        printf '%s|%s' "$PUBLISH_LIST" "${ARGS[*]+${ARGS[*]}}"
    ) 2>&1
}

is "a port becomes a loopback-only publish" \
    "3000|-p 127.0.0.1:3000:3000" "$(_pb /p/one 3000)"
is "a list publishes every port" \
    "3000 5173|-p 127.0.0.1:3000:3000 -p 127.0.0.1:5173:5173" "$(_pb /p/two "3000 5173")"
# Two -p for one port is a hard "port is already allocated" from docker, so the launch would die
# on a duplicate the user cannot see in their own command.
is "a repeated port is published once" "3000|-p 127.0.0.1:3000:3000" "$(_pb /p/dup "3000 3000")"

# Stickiness: the whole point for a non-technical contributor is typing it once.
is "a later launch with no flag gets the project's remembered ports" \
    "3000|-p 127.0.0.1:3000:3000" "$(_pb /p/one "")"
is "stickiness is per project, not global" \
    "3000 5173|-p 127.0.0.1:3000:3000 -p 127.0.0.1:5173:5173" "$(_pb /p/two "")"
is "a project that never asked publishes nothing" "|" "$(_pb /p/never-seen "")"
is "an explicit flag overrides what was remembered" "8080|-p 127.0.0.1:8080:8080" "$(_pb /p/one 8080)"
is "=none clears the pin" "|" "$(_pb /p/one none)"
is "and the cleared project stays cleared" "|" "$(_pb /p/one "")"

# argv straight into `docker run -p`: anything that is not a port is refused here, with a sentence
# rather than a docker error. `kib --publish claude` is the realistic typo.
case "$(_pb /p/bad claude)" in
    *"takes port numbers"*) pass "a non-numeric port is refused" ;;
    *) fail "--publish accepted a non-numeric value" "it would reach docker run -p as argv" ;;
esac
case "$(_pb /p/bad 99999)" in
    *"not a port"*) pass "an out-of-range port is refused" ;;
    *) fail "--publish accepted 99999" "docker would refuse it at launch instead" ;;
esac
if grep -q '^/p/bad=' "$_pb_conf" 2>/dev/null; then
    fail "a refused port was pinned anyway" "every later launch would retry it and die"
else
    pass "a refused port pins nothing"
fi

rm -rf "${_pb_conf%/*}"

# The bind address is not a choice: 0.0.0.0 would hand the sandbox to the LAN, and the ask was
# explicitly for the host's own browser only. Every `-p` the file builds must carry the literal
# loopback address — a bare `-p N:N` would bind every interface. (Comments are exempt: the banner
# tells the user to bind 0.0.0.0 INSIDE the box, which is the opposite direction.)
_pb_p="$(grep -c 'ARGS+=(-p ' "$KIB_ROOT/host/net.sh")"
# shellcheck disable=SC2016  # a literal source pattern matching net.sh's own $p, not an expansion
if [ "$_pb_p" = 1 ] && grep -q 'ARGS+=(-p "127\.0\.0\.1:\$p:\$p")' "$KIB_ROOT/host/net.sh"; then
    pass "published ports bind 127.0.0.1 only, with no opt-out"
else
    fail "host/net.sh publishes on something other than 127.0.0.1" \
        "a sandboxed dev server would be reachable from the LAN"
fi

# ── Create vs attach ─────────────────────────────────────────────
# Ports are fixed at `docker run`, and one container serves every terminal on the project. A
# second terminal attached without them looks exactly like a dev server that failed to start.
if grep -q 'add_publish_args' "$KIB_ROOT/host/lifecycle.sh" \
    && grep -q 'verify_publish_attach' "$KIB_ROOT/host/lifecycle.sh"; then
    pass "the create path publishes and the attach path verifies"
else
    fail "host/lifecycle.sh is missing add_publish_args or verify_publish_attach" \
        "either no port is published, or a terminal attaches silently without one"
fi

_pb_run="$(sed -n '/^start_container()/,/^}/p' "$KIB_ROOT/host/lifecycle.sh")"
if printf '%s\n' "$_pb_run" | grep -q 'add_publish_args' \
    && [ "$(printf '%s\n' "$_pb_run" | grep -n 'add_publish_args' | cut -d: -f1)" \
        -lt "$(printf '%s\n' "$_pb_run" | grep -n 'docker run' | cut -d: -f1)" ]; then
    pass "the ports are added before docker run, not after"
else
    fail "add_publish_args does not run before docker run" "the -p flags would never be passed"
fi

# The pin must follow the container coming up: a port already bound on the host fails the run, and
# remembering it would make every later launch retry the same failure. (Same lesson as node.)
_pb_up_ln="$(grep -n '^kib_bring_up' "$KIB_ROOT/bin/kib" | head -1 | cut -d: -f1)"
_pb_cf_ln="$(grep -n '^publish_ports_confirm' "$KIB_ROOT/bin/kib" | head -1 | cut -d: -f1)"
if [ -n "$_pb_up_ln" ] && [ -n "$_pb_cf_ln" ] && [ "$_pb_cf_ln" -gt "$_pb_up_ln" ]; then
    pass "the pin is written after the container is up, not before"
else
    fail "publish_ports_confirm does not follow kib_bring_up" \
        "a port docker refused would be pinned and the project would fail every launch"
fi

# HostConfig.PortBindings, not NetworkSettings.Ports: the latter also lists EXPOSEd ports with no
# host binding — exactly the unreachable ones this check exists to catch.
if grep -q 'HostConfig.PortBindings' "$KIB_ROOT/host/net.sh"; then
    pass "the attach check reads the real host bindings"
else
    fail "running_published_ports does not read HostConfig.PortBindings" \
        "an EXPOSEd but unpublished port would pass the check and still be unreachable"
fi

# It must live beside the host config, which is NOT mounted into any container: a box-writable
# file deciding the next session's published ports would let a session open a host port itself.
if grep -q 'KIB_PUBLISH_CONF=.*KIB_CONFIG' "$KIB_ROOT/host/net.sh"; then
    pass "the sticky table is derived from \$KIB_CONFIG (host-only, unmounted)"
else
    fail "the publish table is not anchored to the host config dir" \
        "a session could choose which host port the next one opens"
fi

unset out _pb_conf _pb_run _pb_up_ln _pb_cf_ln _pb_p
