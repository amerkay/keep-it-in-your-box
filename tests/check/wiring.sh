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
# The verb table is what an agent in another workspace is told to hand the user. If `add`
# stops being listed, the discoverable path back to "how do I broker this MCP?" is gone.
help_out="$(KIB_CONFIG="$(mktemp -u)" bash "$KIB_ROOT/bin/kib" broker help 2>&1)"
if printf '%s' "$help_out" | grep -q "kib broker add" \
    && printf '%s' "$help_out" | grep -q "share one listener"; then
    pass "kib broker help lists add, and says routes need no port"
else
    fail "kib broker help does not document add" "$(printf '%s' "$help_out" | head -3)"
fi

# An unknown verb must print the table and exit 2, never silently do nothing.
KIB_CONFIG="$(mktemp -u)" bash "$KIB_ROOT/bin/kib" broker nosuchverb >/dev/null 2>&1
is "an unknown broker verb exits 2 with the table" 2 "$?"

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
# Claude keys projects/, .claude.json and ↑ history by its RESOLVED cwd. The sidecar binds the
# redacted view at the project's HOST path, so the container's $HOME-shaped parent is a real
# directory, $HOST_HOME is never symlinked to the container home, and the box key equals the
# host key. config_scope is therefore called with no `box` argument at all — assert that,
# because passing a differing one would split a project's history in two.
# `cli.dispatch` checks arity EXACTLY, so a call one argument short aborts the whole verb and
# the launch falls back to an empty config — losing this project's MCP servers, approved tools
# and ↑ history for the session, with only a warning. That shipped: dropping the now-redundant
# box key looked safe because the Python parameter defaults, but the dispatcher never gets there.
# Every _scope call is checked against the table rather than eyeballed.
arity_bad="$(
    python3 - "$KIB_ROOT" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
table = dict(
    (m[1], int(m[2]))
    for m in re.finditer(r'"([a-z-]+)": \([a-z_]+, (\d+)\)',
                         (root / "kib/host/config_scope.py").read_text())
)
# Join backslash continuations so a wrapped call counts as one.
src = (root / "host/config.sh").read_text().replace("\\\n", " ")
for line in src.splitlines():
    m = re.search(r'\b_scope\s+([a-z-]+)((?:\s+"[^"]*")+)', line)
    if not m:
        continue
    verb, want = m[1], table.get(m[1])
    got = len(re.findall(r'"[^"]*"', m[2]))
    if want is None:
        print(f"{verb}: not in the dispatch table")
    elif got != want:
        print(f"{verb}: passes {got} argument(s), the table wants {want}")
PY
)" || arity_bad="the arity scan itself failed"
if [ -n "$arity_bad" ]; then
    fail "a host/config.sh _scope call does not match config_scope's dispatch table" \
        "$(printf '%s' "$arity_bad" | head -4)"
else
    pass "every _scope call passes the argument count cli.dispatch demands"
fi

# …and there is exactly ONE project key. The sidecar binds the project at its host path, so
# canonical and the session agree; a second, re-keying argument would be a translation layer
# growing back. Asserted on the dispatch table, which is what actually decides.
# All FOUR verbs, counted: a `grep -q` as well would pass on any one of them.
if [ "$(grep -cE '"(scope-in-json|seed-history|merge-out-json|merge-history)": \([a-z_]+, 3\),' \
    "$KIB_ROOT/kib/host/config_scope.py")" = 4 ]; then
    pass "canonical and the session share one project key (no box-key translation)"
else
    fail "config_scope took back a second project key" \
        "the sidecar binds the project at its host path; the two keys are one"
fi

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

# A REAL directory at $SESSION_BASE/projects/$SLUG is a previous in-box session's transcripts,
# which nothing ever tied to canonical (an ephemeral session never gets the link). bind_via_link
# `rm -rf`s a non-symlink, so relinking without folding first destroys every prior in-box
# session — silently. The relink must NOT proceed if the fold failed.
#
# Extracted from lifecycle.sh rather than retyped: an inline copy drifts, and the whole point of
# the block is that it matches what start_container runs.
tm_tmp="$(mktemp -d)"
mkdir -p "$tm_tmp/session/projects/-host-slug" "$tm_tmp/canonical/projects/-host-slug"
printf 'old\n' >"$tm_tmp/session/projects/-host-slug/a.jsonl"
printf 'hidden\n' >"$tm_tmp/session/projects/-host-slug/.b.jsonl"
awk '/^    _bt_ok=1$/{f=1} f{print} /^    fi$/{if(f) exit}' \
    "$KIB_ROOT/host/lifecycle.sh" >"$tm_tmp/block.sh"
(
    # shellcheck disable=SC2034  # consumed by the extracted block
    EPHEMERAL=0 CLAUDE_HOME="$tm_tmp/canonical" SLUG=-host-slug
    SESSION_BASE="$tm_tmp/session"
    # Both codes: the host's shellcheck and the image's report an indirect call differently.
    # shellcheck disable=SC2317,SC2329  # called by the sourced block
    warn() { :; } # the block warns on a failed fold; the assertions below are the signal
    # shellcheck source=/dev/null
    . "$tm_tmp/block.sh"
    printf '%s' "${_bt_ok:-unset}" # the sourced block sets it; :- keeps shellcheck honest
) >"$tm_tmp/ok"
is "the in-box transcripts dir is folded into canonical, not deleted" ".b.jsonl a.jsonl" \
    "$(find "$tm_tmp/canonical/projects/-host-slug" -mindepth 1 -exec basename {} \; \
        | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
is "the fold reports success, so the relink may proceed" "1" "$(cat "$tm_tmp/ok")"
is "nothing is left behind in the session dir" "" \
    "$(find "$tm_tmp/session/projects" -mindepth 1 -exec basename {} \; | LC_ALL=C sort | tr '\n' ' ' \
        | sed 's/ $//')"
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

# The clipboard notifier is a grep contract across the trust boundary: the guard writes
# WLGUARD-<KIND> lines (kib/guest/wayland_guard.py) and start_wayland_notifier greps them out of
# `docker logs`. Rename a kind on either side and NOTHING fails — the proxy keeps filtering, the
# desktop just stops being told, which is exactly the failure nobody notices. Kinds are
# discovered from both sources, so a new one is covered the day it is added.
wg_emitted="$(grep -oE 'log\("[A-Z]+"' "$KIB_ROOT/kib/guest/wayland_guard.py" | sed 's/log("//; s/"//' | sort -u)"
wg_watched="$(grep -oE 'WLGUARD-[A-Z]+\*' "$KIB_ROOT/host/desktop.sh" | sed 's/WLGUARD-//; s/\*//' | sort -u)"
wg_missing=""
for wg_k in $wg_watched; do
    printf '%s\n' "$wg_emitted" | grep -qx "$wg_k" || wg_missing="$wg_missing $wg_k"
done
if [ -z "$wg_missing" ] && [ -n "$wg_watched" ]; then
    pass "every WLGUARD kind the notifier greps is one the guard still emits"
else
    fail "the clipboard notifier greps a kind the guard never emits:${wg_missing:- (none watched)}" \
        "a renamed log kind silently ends every clipboard desktop alert"
fi
unset wg_emitted wg_watched wg_missing wg_k

# Every /dev/null varlink shadow must stay INSIDE add_resolv_sync_args' existence-guarded loop,
# i.e. name the socket via the loop variable and never a literal. runc has to create the
# mountpoint and cannot on a read-only bind, so a hardcoded name aborts the whole launch the
# moment that socket is absent at create time (`make mountpoint …: read-only file system`) —
# which is what the literal io.systemd.Resolve/.Monitor mounts this replaced would have done.
# Nothing in the check suite can see a docker run, so the shape is pinned in the source instead.
vl_body="$(sed -n '/^add_resolv_sync_args() {/,/^}/p' "$KIB_ROOT/host/net.sh")"
vl_all="$(printf '%s\n' "$vl_body" | grep -c '/dev/null:' || true)"
# shellcheck disable=SC2016  # a grep pattern matching the literal text ${_s##*/}, not an expansion
vl_var="$(printf '%s\n' "$vl_body" | grep -c '/dev/null:.*\${_s##\*/}' || true)"
if [ "$vl_all" -ge 1 ] && [ "$vl_all" = "$vl_var" ]; then
    pass "every varlink /dev/null shadow is loop-derived, never a literal socket name"
else
    fail "add_resolv_sync_args hardcodes a varlink socket name ($vl_var/$vl_all loop-derived)" \
        "runc cannot create a mountpoint on a :ro bind — an absent socket aborts every launch"
fi
unset vl_body vl_all vl_var
