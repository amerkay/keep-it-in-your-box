#!/usr/bin/env bash
# Sourced by tests/check.sh — one guard per settled bug.
#
# Every check here corresponds to a failure that actually shipped. Do not relax one to make a
# refactor pass; the bug is what the assertion is for.

section "Regression guards"

# settings.json must never be bind-mounted from canonical: it is the file a HOST `claude` loads,
# and hooks[].command / apiKeyHelper in it are host code execution. The box gets a vetted COPY.
# Match on the BIND, not the filename — the old code took the name from a loop variable, so
# grepping "settings.json:" silently never fired. Two $CLAUDE_HOME binds are legitimate (this
# project's transcripts, the ro-by-default asset loop); anything else is the regression.
stray_home_binds="$(grep -E '^[[:space:]]*ARGS\+=\(-v "\$CLAUDE_HOME/' "$KIB_ROOT/host/lifecycle.sh" \
    | grep -vE '\$CLAUDE_HOME/projects/\$SLUG:' | grep -vE '\$CLAUDE_HOME/\$_entry:' || true)"
if [ -n "$stray_home_binds" ]; then
    fail "canonical ~/.claude content is bind-mounted into the container: $(printf '%s' "$stray_home_binds" | tr -s ' ')" \
        "a sandboxed session could then write the settings.json the host claude loads"
elif ! grep -q 'merge_out_shared_settings' "$KIB_ROOT/host/config.sh"; then
    fail "merge_out_shared_settings is never called" \
        "in-session settings edits would silently never reach ~/.claude"
else
    pass "settings.json is staged as a vetted copy, never bound from canonical"
fi

# The fold-back must refuse an unvettable file rather than fold it unchecked.
if sed -n '/^merge_out_shared_settings()/,/^}$/p' "$KIB_ROOT/host/config.sh" | grep -q 'have_python'; then
    pass "settings fold-back refuses to merge when it cannot vet the file"
else
    fail "merge_out_shared_settings folds settings.json back without a python vet" \
        "no vet, no fold-back — otherwise a host without python3 loses the protection"
fi

# THE logout regression. Anthropic refresh tokens are single-use and rotate, so a broker handed
# the live credentials file invalidates the token family for the host CLI and every other
# project's sidecar. Its secret is the static claude-token, mounted READ-ONLY.
# No `sed | grep -q`: under pipefail, grep -q exits on first match and SIGPIPEs the sed, so the
# pipeline reports 141 and a MATCH reads as a failure.
if grep -qE '^[[:space:]]*-v ".*\.credentials\.json:' "$KIB_ROOT/host/broker.sh"; then
    fail "host/broker.sh bind-mounts .credentials.json into the broker" \
        "that is the logout bug — broker the static token file instead (kib broker login)"
else
    pass "the broker never mounts the live .credentials.json (static token only)"
fi

# Every credential mounted from $KIB_DIR — broker token(s) at /run/broker/token/<id> and each
# hosted-MCP sidecar's cred at /run/cred/<file> — must be READ-ONLY, so there is no write path
# to a credential by construction.
kib_all="$(grep -oE '\-v "\$KIB_DIR/[^"]*"' "$KIB_ROOT/host/broker.sh" || true)"
kib_n=$(printf '%s\n' "$kib_all" | grep -c . || true)
if [ "$kib_n" -gt 0 ] && ! printf '%s\n' "$kib_all" | grep -qv ':ro"$'; then
    pass "broker/hosted-MCP credential mounts are all read-only ($kib_n mount(s))"
else
    fail "a \$KIB_DIR credential mount is not read-only" \
        "every -v \"\$KIB_DIR/…\" must end :ro (found $kib_n, at least one without)"
fi

# Screen clearing (removed): kib must not `tput reset` — it wiped a short command's output
# and clobbered scrollback when interactive Claude quit. Claude Code's TUI manages its own
# screen, so kib leaves the terminal alone.
if sed 's/#.*$//' "$KIB_ROOT/bin/kib" "$KIB_ROOT/host/lifecycle.sh" | grep -qE '\btput[[:space:]]+reset\b'; then
    fail "kib calls 'tput reset'" "removed on purpose — it wiped command output + scrollback"
else
    pass "kib leaves the terminal to Claude's TUI (no 'tput reset')"
fi

# A backgrounded rebuild must not decide "nobody is watching" from the tty alone. setsid drops
# the controlling terminal but leaves fd 1 on the user's terminal, so `[ -t 1 ]` stayed true
# and BuildKit drew its progress UI over the running Claude session while the log got nothing.
if grep -qE '^if \[ "\$\{1:-\}" != --background \] && \[ -t 1 \]' "$KIB_ROOT/tools/build-bg.sh" \
    && grep -q 'build-bg.sh" --background >/dev/null 2>&1' "$KIB_ROOT/host/image.sh"; then
    pass "backgrounded rebuild stays off the terminal (--background + redirect, not just [ -t 1 ])"
else
    fail "background rebuild can stream over the session" \
        "build-bg.sh must honour --background, and host/image.sh must pass it AND redirect"
fi

# FUSE reads must be pread, not lseek+read. With nothreads=False several worker threads serve
# one open file and share the fd's offset, so racing lseeks made a reader see the file
# truncated at a 16 KiB boundary — silent corruption that showed up as "flaky" lint runs.
if grep -qE '^\s*os\.lseek\(' "$KIB_ROOT/kib/guest/fuse.py"; then
    fail "kib/guest/fuse.py uses lseek+read/write" \
        "use os.pread/os.pwrite — a shared fd offset truncates concurrent reads at 16 KiB"
elif grep -q 'os.pread(' "$KIB_ROOT/kib/guest/fuse.py" && grep -q 'os.pwrite(' "$KIB_ROOT/kib/guest/fuse.py"; then
    pass "FUSE passthrough reads/writes are offset-atomic (pread/pwrite, no shared fd offset)"
else
    fail "kib/guest/fuse.py lost its pread/pwrite passthrough" "expected os.pread + os.pwrite"
fi

# The pre-commit hook kib used to install into every project is gone, and the marker it left
# behind is still recognised so the one-time cleanup can fire.
if [ -e "$KIB_ROOT/ccignore-precommit.py" ]; then
    fail "the auto-installed pre-commit hook is back" "its checks belong in host/gitguard.sh"
elif grep -q 'MARKER: ccignore-precommit' "$KIB_ROOT/host/gitguard.sh"; then
    pass "no hook is installed into user repos, and the legacy marker is still cleaned up"
else
    fail "the legacy hook marker is no longer recognised" \
        "existing project repos would keep kib's obsolete pre-commit hook forever"
fi

# PYTHONPATH must never be set image-wide: it would leak into every process the agent runs.
if grep -qE '^\s*ENV\s+PYTHONPATH' "$KIB_ROOT/Dockerfile"; then
    fail "Dockerfile sets PYTHONPATH image-wide" "it would leak into every agent subprocess"
else
    pass "PYTHONPATH is per-exec only (guest shims), never an image ENV"
fi

# The audit gate's two severities through the BASH entry point — the Python side is unit-tested,
# but the hazard is here: called as a plain command under `set -e`, a non-zero return for a
# warn-class finding turns "you are tracking a hidden path" into "the sandbox will not start".
# `launch` mode only — `report` raises a desktop notification, which a suite must not do.
t_audit_gate_severity() {
    local dir rc out
    dir="$(mktemp -d)"

    _gate_in() { # _gate_in <repo> — run kib_audit_gate launch there, under the real set -e
        (
            set -euo pipefail
            export KIB_ROOT
            # shellcheck source=../../host/_load.sh
            . "$KIB_ROOT/host/_load.sh"
            cd "$1" || exit 9
            kib_audit_gate launch
            echo GATE-RETURNED-OK
        ) 2>&1
    }

    # warn-class: a tracked path matching .kibignore is named, and the launch continues.
    (
        GIT_TEMPLATE_DIR= git init -q "$dir/warn"
        cd "$dir/warn" || exit 1
        printf 'secret.txt\n' >.kibignore
        printf 'v\n' >secret.txt
        git add -A
    ) >/dev/null 2>&1
    rc=0
    out="$(_gate_in "$dir/warn")" || rc=$?
    if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'GATE-RETURNED-OK' \
        && printf '%s' "$out" | grep -q 'secret.txt'; then
        pass "audit gate: a tracked hidden path warns and the launch continues"
    else
        fail "audit gate warn-class aborted the launch" "rc=$rc out=$(printf '%s' "$out" | tr '\n' ' ' | head -c 160)"
    fi

    # refuse-class: a host-executed git config key stops the launch with exit 5.
    (
        GIT_TEMPLATE_DIR= git init -q "$dir/refuse"
        git -C "$dir/refuse" config --local core.fsmonitor /tmp/fsm.sh
    ) >/dev/null 2>&1
    rc=0
    out="$(_gate_in "$dir/refuse")" || rc=$?
    if [ "$rc" = 5 ] && printf '%s' "$out" | grep -q 'fsmonitor'; then
        pass "audit gate: a host-executed git config key refuses the launch (exit 5)"
    else
        fail "audit gate refuse-class wrong" "rc=$rc (want 5) out=$(printf '%s' "$out" | tr '\n' ' ' | head -c 160)"
    fi

    # A clean repo must be silent and non-fatal.
    GIT_TEMPLATE_DIR= git init -q "$dir/clean" >/dev/null 2>&1
    rc=0
    out="$(_gate_in "$dir/clean")" || rc=$?
    if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'GATE-RETURNED-OK'; then
        pass "audit gate: a clean repo is a silent no-op"
    else
        fail "audit gate on a clean repo" "rc=$rc out=$(printf '%s' "$out" | tr '\n' ' ' | head -c 160)"
    fi
    rm -rf "$dir"
}
t_audit_gate_severity

# DNS (broker): resolv-sync must PRESERVE Docker's embedded resolver (127.0.0.11) as the first
# nameserver. When the container joins the broker's user-defined network its resolv.conf
# becomes `nameserver 127.0.0.11`; if the sync overwrites that with the host upstreams, the
# `kib-broker` alias stops resolving mid-session (the ENOTFOUND bug). Runs the REAL script.
t_resolv_embedded() {
    local dir first pid
    dir="$(mktemp -d)"
    # broker on: DST has the embedded resolver; host SRC has an upstream + the loopback stub.
    printf 'search .\nnameserver 127.0.0.11\noptions ndots:0\n' >"$dir/dst"
    printf '# host\nnameserver 192.168.18.250\nnameserver 127.0.0.53\nsearch lan\n' >"$dir/src"
    KIB_RESOLV_DST="$dir/dst" KIB_RESOLV_SYNC_INTERVAL=1 \
        sh "$KIB_ROOT/guest/bin/resolv-sync.sh" "$dir/src" 2>/dev/null &
    pid=$!
    sleep 0.5
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
    first="$(grep -m1 '^[[:space:]]*nameserver' "$dir/dst" 2>/dev/null | awk '{print $2}')"
    is "resolv-sync: embedded DNS (127.0.0.11) kept FIRST — the broker alias survives" \
        127.0.0.11 "$first"
    if grep -q '192.168.18.250' "$dir/dst" && ! grep -q '127.0.0.53' "$dir/dst"; then
        pass "resolv-sync: keeps the host upstream, strips the loopback stub"
    else
        fail "resolv-sync upstream/stub handling"
    fi
    # broker off: DST has no embedded resolver → output is upstreams only (unchanged).
    printf 'nameserver 10.0.0.1\n' >"$dir/dst2"
    KIB_RESOLV_DST="$dir/dst2" sh "$KIB_ROOT/guest/bin/resolv-sync.sh" "$dir/src" 2>/dev/null &
    pid=$!
    sleep 0.5
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
    if grep -q '127.0.0.11' "$dir/dst2"; then
        fail "resolv-sync broker-off" "injected 127.0.0.11 where DST had none"
    else
        pass "resolv-sync: no embedded DNS present → upstreams only (broker off, unchanged)"
    fi
    rm -rf "$dir"
}
t_resolv_embedded
