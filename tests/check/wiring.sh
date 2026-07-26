#!/usr/bin/env bash
# Sourced by tests/check.sh — the SHELL glue around the broker.
#
# The Python side is covered by pytest; these guard the bash that only ever ran manually:
# the host-config contract the launch path evals, the login exit-status truth table, and the
# sensitive-directory guard's exemption for host-global verbs.

# shellcheck source=SCRIPTDIR/_guard.sh
. "${BASH_SOURCE%/*}/_guard.sh" # sourced by tests/check.sh, never run directly

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

# ── Host key vs box key ──────────────────────────────────────────
# Claude keys projects/, .claude.json and ↑ history by its RESOLVED cwd. There is no $PWD bind
# and $HOST_HOME is a symlink to the container home, so a project under $HOME resolves to
# $CONTAINER_HOME/<rel> in the box. kib_box_pwd is what keeps canonical host-keyed and the
# session box-keyed; getting it wrong splits a project's history in two.
#
# Each case sources config.sh in its OWN subshell and only the RESULT crosses back, so `is`
# runs in the suite's shell — inside a subshell its counter bump is discarded and a regression
# prints ✘ while the run still exits 0.
_box_pwd_for() { # $1 = the host's $HOME, $2 = the host's $PWD → the box's resolved path
    (
        HOME="$1"
        PWD="$2"
        # shellcheck source=SCRIPTDIR/../../host/config.sh
        . "$KIB_ROOT/host/config.sh"
        kib_box_pwd
    )
}

# The same five properties, whatever shape the host's $HOME has: macOS /Users/<name>, Linux
# /home/<name>. The box key is /home/hostuser either way, and this translation runs on BOTH
# platforms, so both shapes are asserted rather than only the one this suite runs on.
for _h in /Users/veronica /home/kay; do
    is "a project under \$HOME ($_h) remaps to the container home" \
        "/home/hostuser/proj" "$(_box_pwd_for "$_h" "$_h/proj")"
    is "the path below \$HOME ($_h) survives the remap intact" \
        "/home/hostuser/code/nested/proj" "$(_box_pwd_for "$_h" "$_h/code/nested/proj")"
    is "\$HOME itself ($_h) maps to the container home" \
        "/home/hostuser" "$(_box_pwd_for "$_h" "$_h")"
    # Outside $HOME the entrypoint mkdirs the real path, so it resolves to itself — remapping
    # there would invent a directory that does not exist in the box.
    is "a project outside \$HOME ($_h) is left alone" \
        "/opt/work/proj" "$(_box_pwd_for "$_h" /opt/work/proj)"
    # The near-miss: a sibling whose name merely starts with $HOME must not be rewritten.
    is "a \$HOME ($_h) prefix that is not a path boundary is not remapped" \
        "$_h-backup/proj" "$(_box_pwd_for "$_h" "$_h-backup/proj")"
done
unset _h

# The container's user is the constant `hostuser` whatever the host user is called, so a Linux
# host whose home already IS /home/hostuser must remap to itself — not double the prefix.
is "a host \$HOME that already is the container home maps to itself" \
    "/home/hostuser/proj" "$(_box_pwd_for /home/hostuser /home/hostuser/proj)"

# $SESSION_BASE outlives the container, so a transcripts link keyed by a name kib no longer uses
# is never reaped — renaming it $SLUG → $BOX_SLUG stranded the old one, and a stray dir in
# projects/ reads to an auditor as ANOTHER project's transcripts (security-test.sh checks
# exactly this). start_container must sweep its own links before relinking. Only links into
# $TRANSCRIPTS_CPATH are ours; a real dir is Claude's and must survive.
tl_tmp="$(mktemp -d)"
mkdir -p "$tl_tmp/projects/-a-real-transcript-dir"
ln -s /run/kib/transcripts "$tl_tmp/projects/-Users-veronica-proj" # stale: the old slug
ln -s /run/kib/transcripts "$tl_tmp/projects/-home-hostuser-proj"  # current
ln -s /somewhere/else "$tl_tmp/projects/-not-ours"                 # not ours: leave it
(
    SESSION_BASE="$tl_tmp" TRANSCRIPTS_CPATH=/run/kib/transcripts
    for _t in "$SESSION_BASE"/projects/*; do
        [ -L "$_t" ] || continue
        [ "$(readlink "$_t" 2>/dev/null)" = "$TRANSCRIPTS_CPATH" ] || continue
        rm -f "$_t" 2>/dev/null || true
    done
)
# LC_ALL=C on every sort below: a UTF-8 collation ignores leading punctuation, so `.b.jsonl`
# sorts after `a.jsonl` on a normal desktop and before it in a C-locale container. The expected
# string cannot be right for both — pin the order rather than pick a side.
is "the transcripts sweep drops every link of ours, whatever its slug" "" \
    "$(find "$tl_tmp/projects" -lname /run/kib/transcripts -exec basename {} \; | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
is "the sweep keeps a real dir and a link that is not ours" "-a-real-transcript-dir -not-ours" \
    "$(find "$tl_tmp/projects" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort | tr '\n' ' ' \
        | sed 's/ $//')"

# The sweep must be the one start_container actually runs, not a copy that drifted from it.
# shellcheck disable=SC2016  # matching lifecycle.sh's own source text: $_t must stay literal
if grep -q 'readlink "\$_t"' "$KIB_ROOT/host/lifecycle.sh"; then
    pass "start_container sweeps its own transcripts links before relinking"
else
    fail "start_container no longer sweeps stale transcripts links" \
        "a slug rename will strand one in \$SESSION_BASE and it reads as a cross-project dir"
fi
rm -rf "$tl_tmp"
unset tl_tmp

# On the first launch after the link moved from $SLUG to $BOX_SLUG, a REAL directory sits at the
# box slug: Claude keys by its resolved cwd, so it had been writing its transcripts
# there all along while the link pointed at $SLUG. bind_via_link `rm -rf`s a non-symlink, so
# relinking without migrating first destroys every prior in-box session — silently, and they were
# never in canonical to begin with. Fold them out, and NEVER relink if the fold did not complete.
tm_tmp="$(mktemp -d)"
mkdir -p "$tm_tmp/session/projects/-box-slug" "$tm_tmp/canonical/projects/-host-slug"
printf 'old\n' >"$tm_tmp/session/projects/-box-slug/a.jsonl"
printf 'hidden\n' >"$tm_tmp/session/projects/-box-slug/.b.jsonl"
(
    EPHEMERAL=0 CLAUDE_HOME="$tm_tmp/canonical" SLUG=-host-slug
    _bt="$tm_tmp/session/projects/-box-slug" _bt_ok=1
    if [ -d "$_bt" ] && [ ! -L "$_bt" ]; then
        _bt_ok=0
        if [ "$EPHEMERAL" != 1 ] && mkdir -p "$CLAUDE_HOME/projects/$SLUG" 2>/dev/null; then
            for _f in "$_bt"/* "$_bt"/.[!.]*; do
                [ -e "$_f" ] || continue
                mv -n "$_f" "$CLAUDE_HOME/projects/$SLUG/" 2>/dev/null || true
            done
            rmdir "$_bt" 2>/dev/null && _bt_ok=1
        fi
    fi
    printf '%s' "$_bt_ok"
) >"$tm_tmp/ok"
is "a pre-existing in-box transcripts dir is folded into canonical, not deleted" ".b.jsonl a.jsonl" \
    "$(find "$tm_tmp/canonical/projects/-host-slug" -mindepth 1 -exec basename {} \; \
        | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
is "the fold reports success, so the relink may proceed" "1" "$(cat "$tm_tmp/ok")"
rm -rf "$tm_tmp"
unset tm_tmp

# The migration must sit BEFORE the relink, or bind_via_link destroys the dir first.
if awk '/_bt_ok=1/{m=NR} /bind_via_link "\$CLAUDE_HOME\/projects\/\$SLUG"/{b=NR} END{exit !(m && b && m < b)}' \
    "$KIB_ROOT/host/lifecycle.sh"; then
    pass "start_container migrates old in-box transcripts before relinking over them"
else
    fail "the transcripts migration is missing or runs after the relink" \
        "bind_via_link rm -rf's a non-symlink — every prior in-box session would be lost"
fi

# A repo script that is EXEC'd (not sourced) must carry the exec bit IN GIT — the worktree bit
# is the developer's, the index mode is what every other checkout gets. clipboard-bridge.sh
# shipped 100644, so `detach_pgrp` (perl `exec` on darwin, setsid on linux) hit EACCES and the
# macOS clipboard bridge died at every launch, silently: image paste never worked, and text
# paste kept working because a terminal pastes over the pty without ever calling a reader.
# Discovered, not listed, so a new exec'd script is covered the day it is added.
xb_bad=""
# shellcheck disable=SC2016  # both are literal patterns matching the source's own "$KIB_ROOT/…"
xb_found="$(grep -rhoE '(detach_pgrp|exec) "\$KIB_ROOT/[a-zA-Z0-9_./-]+\.sh"' \
    "$KIB_ROOT/bin" "$KIB_ROOT/host" | sed 's#.*\$KIB_ROOT/##; s/"$//' | sort -u)"
while IFS= read -r xb_f; do
    if [ -z "$xb_f" ] || [ ! -f "$KIB_ROOT/$xb_f" ]; then continue; fi
    case "$(git -C "$KIB_ROOT" ls-files -s -- "$xb_f" 2>/dev/null | awk '{print $1}')" in
        100755 | '') ;; # 755 is right; empty means untracked, which git mode cannot speak to
        *) xb_bad="$xb_bad $xb_f" ;;
    esac
done <<EOF
$xb_found
EOF
if [ -z "$xb_bad" ]; then
    pass "every exec'd host script is executable in git (not just in this worktree)"
else
    fail "an exec'd host script is not 100755 in git:$xb_bad" \
        "detach_pgrp/exec will hit EACCES and the feature dies silently on a fresh clone"
fi
unset xb_bad xb_f xb_found

# `kib sleep-monitor` is a host-global verb, so it execs BEFORE preflight_platform could refuse
# it — and every source it samples (systemd-inhibit, KDE qdbus, /proc) is Linux-only. Without
# its own guard it ran to completion on macOS and wrote an EMPTY log, which reads as "nothing is
# holding the machine awake" rather than "this tool does not apply here". Proven by stubbing
# uname, which is what portable.sh branches on.
sm_stub="$(mktemp -d)"
# shellcheck disable=SC2016  # the stub's own source text: $1/$@ must reach it unexpanded
printf '#!/bin/sh\n[ "$1" = -s ] && { echo Darwin; exit 0; }\nexec /usr/bin/uname "$@"\n' >"$sm_stub/uname"
chmod +x "$sm_stub/uname"
sm_out="$(PATH="$sm_stub:$PATH" bash "$KIB_ROOT/host/sleep-monitor.sh" 2>&1)" && sm_rc=0 || sm_rc=$?
if [ "$sm_rc" = 2 ] && printf '%s' "$sm_out" | grep -q 'Linux-only'; then
    pass "kib sleep-monitor refuses on macOS instead of writing an empty log"
else
    fail "sleep-monitor has no darwin guard" \
        "rc=$sm_rc: $(printf '%s' "$sm_out" | head -1)"
fi
rm -rf "$sm_stub"
unset sm_stub sm_out sm_rc
