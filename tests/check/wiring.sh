#!/usr/bin/env bash
# Sourced by tests/check.sh — the SHELL glue around the broker.
#
# The Python side is covered by pytest; these guard the bash that only ever ran manually:
# the host-config contract the launch path evals, the login exit-status truth table, and the
# sensitive-directory guard's exemption for host-global verbs.

section "Broker bash wiring (bin/kib, host/broker.sh)"

# host-config is the single source of truth add_broker_env_args reads. If any key it needs
# disappears (a rename, a dropped line), the launch aborts — so assert all five are present.
hc="$(PYTHONPATH="$KIB_ROOT" python3 -m kib.broker.cli host-config claude 2>/dev/null)"
missing=""
for k in KIB_BROKER_BASE_URL_ENV KIB_BROKER_TOKEN_ENV KIB_BROKER_PLACEHOLDER_TOKEN \
    KIB_BROKER_LISTEN_PORT KIB_BROKER_PLACEHOLDER_CONTAINER_PATH; do
    printf '%s\n' "$hc" | grep -q "^$k=." || missing="$missing $k"
done
if [ -z "$missing" ]; then
    pass "host-config claude emits every key add_broker_env_args needs"
else
    fail "host-config claude is missing keys:$missing" "add_broker_env_args would abort the launch"
fi

# host-config is EVAL'd by _broker_host_config, so exercise that for real rather than
# eyeballing the quoting: run the eval in a subshell and assert the variables actually land.
# (The shell-quoting of a multiword value is asserted directly in tests/broker/test_broker.py.)
if (
    KIB_BROKER_LISTEN_PORT=""
    KIB_BROKER_BASE_URL_ENV=""
    eval "$hc"
    [ "$KIB_BROKER_LISTEN_PORT" = 8080 ] && [ "$KIB_BROKER_BASE_URL_ENV" = ANTHROPIC_BASE_URL ]
) 2>/dev/null; then
    pass "host-config output evals cleanly into the caller's scope"
else
    fail "host-config output does not eval into the expected variables" \
        "add_broker_env_args reads these; the launch would abort"
fi

# The injected placeholder token must be a fake_value_ sentinel — never a real credential
# shape leaking through host-config into the agent's auth env var.
case "$(printf '%s\n' "$hc" | sed -n "s/^KIB_BROKER_PLACEHOLDER_TOKEN=//p")" in
    *fake_value_*) pass "host-config placeholder token is a fake_value_ sentinel" ;;
    *) fail "host-config placeholder token is not a sentinel" "may inject a real token shape" ;;
esac

# The DEFAULT, guarded because it is what drifted: the docs claimed the broker was on while
# `KIB_CFG_BROKER=off` said otherwise, and the two disagreed across several passes over both.
# Assert the whole truth table against the real units, sourced the way bin/kib sources them.
_brk_tmp="$(mktemp -d)"
_broker_wanted_says() { # $1 = config body ("" = no config file), $2 = KIB_BROKER ("" = unset)
    local cfg="$_brk_tmp/config"
    if [ -n "$1" ]; then printf '%s\n' "$1" >"$cfg"; else rm -f "$cfg"; fi
    (
        set +u
        export KIB_CONFIG="$cfg"
        if [ -n "$2" ]; then export KIB_BROKER="$2"; else unset KIB_BROKER; fi
        # shellcheck source=SCRIPTDIR/../../host/core.sh
        . "$KIB_ROOT/host/core.sh"
        # shellcheck source=SCRIPTDIR/../../host/portable.sh
        . "$KIB_ROOT/host/portable.sh"
        # shellcheck source=SCRIPTDIR/../../host/broker.sh
        . "$KIB_ROOT/host/broker.sh"
        broker_wanted && echo yes || echo no
    ) 2>/dev/null
}
# no config → ON. 'off'/'false' → off. A TYPO must fail CLOSED (brokered), not silently mount
# the real credential. KIB_BROKER=0/1 overrides the file either way.
_brk_got="$(_broker_wanted_says '' '')/$(_broker_wanted_says 'broker = off' '')"
_brk_got="$_brk_got/$(_broker_wanted_says 'broker = false' '')/$(_broker_wanted_says 'broker = of' '')"
_brk_got="$_brk_got/$(_broker_wanted_says '' 0)/$(_broker_wanted_says 'broker = off' 1)"
if [ "$_brk_got" = "yes/no/no/yes/no/yes" ]; then
    pass "broker_wanted: ON by default, off only on a recognised spelling, typo fails closed"
else
    fail "broker_wanted truth table wrong" \
        "default/off/false/typo/env0/env1 = $_brk_got (want yes/no/no/yes/no/yes)"
fi
rm -rf "$_brk_tmp"

# The login exit-status contract (regression: an inconclusive probe must NOT fail a
# successful store). Eval the real one-line helper out of host/broker.sh and assert its
# truth table directly.
eval "$(sed -n '/^_login_ok_after_probe()/p' "$KIB_ROOT/host/broker.sh")"
if declare -f _login_ok_after_probe >/dev/null; then
    _login_ok_after_probe 0 && a=0 || a=1 # accepted     → login ok
    _login_ok_after_probe 2 && b=0 || b=1 # inconclusive → login ok
    _login_ok_after_probe 1 && c=0 || c=1 # rejected     → login FAILS
    if [ "$a" = 0 ] && [ "$b" = 0 ] && [ "$c" = 1 ]; then
        pass "broker login: store succeeds unless the probe definitively rejects (0/2 ok, 1 fails)"
    else
        fail "broker login exit-status contract wrong" "accepted=$a inconclusive=$b rejected=$c (want 0 0 1)"
    fi
else
    fail "_login_ok_after_probe not found in host/broker.sh" "the helper was removed or renamed"
fi

# The sensitive-dir guard must NOT reject the host-global verbs, so they work from $HOME (the
# natural place to manage a host-global credential). Run one from a blocked dir with a
# throwaway KIB_CONFIG (no token → prints status, exits 1, touches no docker) and assert it
# reached broker status rather than the launch refusal.
guard_out="$(cd "$HOME" 2>/dev/null && KIB_CONFIG="$(mktemp -u)" bash "$KIB_ROOT/bin/kib" broker status 2>&1)"
case "$guard_out" in
    *"refuses to launch"*) fail "kib broker status blocked from \$HOME by the dir guard" ;;
    *"credential broker"*) pass "host-global verbs bypass the sensitive-dir guard (run from \$HOME)" ;;
    *) fail "kib broker status from \$HOME produced unexpected output" "$(printf '%s' "$guard_out" | head -1)" ;;
esac

# The collision rule: an unknown first token must NEVER launch anything. `kib bash` used to
# exec bash; it is now an error that names the replacement.
verb_out="$(cd "$KIB_ROOT" && bash "$KIB_ROOT/bin/kib" bash 2>&1)" && verb_rc=0 || verb_rc=$?
if [ "$verb_rc" = 2 ] && printf '%s' "$verb_out" | grep -q 'kib exec bash'; then
    pass "unknown verb is refused (exit 2) and points at 'kib exec'"
else
    fail "unknown verb handling wrong" "rc=$verb_rc: $(printf '%s' "$verb_out" | head -2 | tr '\n' ' ')"
fi
