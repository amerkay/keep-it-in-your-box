#!/usr/bin/env bash
# Sourced by tests/check.sh — one guard per settled bug.
#
# Every check here corresponds to a failure that actually shipped. Do not relax one to make a
# refactor pass; the bug is what the assertion is for.

# shellcheck source=SCRIPTDIR/_guard.sh
. "${BASH_SOURCE%/*}/_guard.sh" # sourced by tests/check.sh, never run directly

section "Regression guards"

# settings.json must never be bind-mounted from canonical: it is the file a HOST `claude` loads,
# and hooks[].command / apiKeyHelper in it are host code execution. The box gets a vetted COPY.
# Match on the BIND, not the filename — the old code took the name from a loop variable, so
# grepping "settings.json:" silently never fired. Two $CLAUDE_HOME binds are legitimate (this
# project's transcripts, and `_bind_shared_asset`, the one helper both tiers go through);
# anything else is the regression.
# Both spellings of "mount this": the direct one and bind_via_link, which takes the same source
# as its first argument.
# shellcheck disable=SC2016  # literal grep patterns: they must match the source text verbatim
stray_home_binds="$(grep -E '^[[:space:]]*(ARGS\+=\(-v|bind_via_link) "\$CLAUDE_HOME/' \
    "$KIB_ROOT/host/lifecycle.sh" \
    | grep -vE '\$CLAUDE_HOME/projects/\$SLUG[":]' | grep -vE '\$CLAUDE_HOME/\$1[":]' || true)"
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
# shellcheck disable=SC2016  # a literal grep pattern: it must match the "$KIB_DIR" source text
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
if grep -qE '^if \[ "\$\{1:-\}" != --background \] && \[ -t 1 \]' "$KIB_ROOT/tools/build-image.sh" \
    && grep -q 'build-image.sh" --background >/dev/null 2>&1' "$KIB_ROOT/host/image.sh"; then
    pass "backgrounded rebuild stays off the terminal (--background + redirect, not just [ -t 1 ])"
else
    fail "background rebuild can stream over the session" \
        "build-image.sh must honour --background, and host/image.sh must pass it AND redirect"
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

# Every host process backgrounded from the launch path must close fds 200/201. One miss and the
# child holds the project's SHARED lock, so the last terminal out cannot take it exclusively —
# teardown never runs and the containers are stranded. Shipped that way in the background image
# rebuild, which outlives the session by minutes. Background JOBS are discovered, not listed, so
# a new one is covered the day it is added — but only fds 200/201 are asserted. 202 (teardown's
# exclusive retry) and 203 (the canonical .claude.json lock) are held only while tearing down,
# where nothing is backgrounded today; a background job added THERE would need them too.
# portable.sh is excluded — it DEFINES detach_pgrp, and closes every fd >=2 itself on darwin.
fd_bad=""
for fd_f in bin/kib host/lifecycle.sh host/desktop.sh host/broker.sh host/image.sh \
    host/redaction.sh host/net.sh host/config.sh; do
    [ -f "$KIB_ROOT/$fd_f" ] || continue
    while IFS= read -r fd_line; do
        # A file with no background job yields one empty line from the heredoc below.
        if [ -z "$fd_line" ]; then continue; fi
        case "$fd_line" in
            *'200>&-'*'201>&-'*) ;;
            *) fd_bad="$fd_bad $fd_f:$(printf '%s' "$fd_line" | sed 's/^ *//' | cut -c1-40)" ;;
        esac
    done <<EOF
$(grep -hE '(detach_pgrp |[^&>]& *$)' "$KIB_ROOT/$fd_f" | grep -v '&&')
EOF
done
if [ -z "$fd_bad" ]; then
    pass "every backgrounded host process closes the lock fds (200/201)"
else
    fail "a backgrounded host process inherits the project lock:$fd_bad" \
        "it holds the shared lock, so the last session out cannot tear the containers down"
fi
unset fd_bad fd_f fd_line

# The mirror of the above: undoing detach_pgrp goes through kill_pgrp, never a hand-rolled
# `kill -TERM -$pid` from a pidfile. A detached child that already exited frees its pid, Linux
# recycles numbers near-sequentially, and one launch's stale pidfile named the NEXT launch's own
# process group — SIGTERMing bin/kib right after the banner, silently, with no container. Four
# copies of the pattern existed; two had no guard at all.
# shellcheck disable=SC2016  # a literal grep pattern: it must match the source text verbatim
kp_bad="$(grep -rln 'kill -TERM "-\$' "$KIB_ROOT"/bin/kib "$KIB_ROOT"/host/*.sh \
    | grep -v '/portable\.sh$' || true)"
if [ -z "$kp_bad" ]; then
    pass "process groups are killed only through kill_pgrp (no recycled-pid signal)"
else
    fail "a hand-rolled group kill from a pidfile: $kp_bad" \
        "a recycled pid can name kib's own group — use kill_pgrp, which refuses that"
fi
unset kp_bad

# A script started BY detach_pgrp is a separate process, and bin/kib never exports KIB_ROOT — so
# requiring it from the environment makes the script exit instantly on every launch. It shipped
# that way in shared-watch.sh: the notifier never ran once, and the dead pid it recorded is what
# armed the group-kill above. Sourced files (host/_load.sh) are exempt: they see the caller's.
kr_bad=""
for kr_f in "$KIB_ROOT"/host/*.sh; do
    case "$kr_f" in */_load.sh) continue ;; esac
    grep -q '^#!' "$kr_f" 2>/dev/null || continue # sourced unit, not an executed script
    grep -q 'KIB_ROOT:?' "$kr_f" && kr_bad="$kr_bad $(basename "$kr_f")"
done
if [ -z "$kr_bad" ]; then
    pass "no detached host script demands KIB_ROOT from the environment"
else
    fail "script(s) require an unexported KIB_ROOT:$kr_bad" \
        "detach_pgrp gives them a fresh environment — derive it from \$0 instead"
fi
unset kr_bad kr_f

# The synthetic placeholder credential is held read-only by a :ro MOUNT, never by chmod.
# Docker Desktop's `fakeowner` bind layer records the mode but ignores it in access(2), so a
# 0400 copy is writable inside the box on macOS — the control silently did nothing there.
if awk '/^_stage_placeholder_credential\(\)/,/^}/' "$KIB_ROOT/host/broker.sh" \
    | grep -q 'bind_via_link .* :ro'; then
    pass "the placeholder credential is read-only by mount, not by mode bit (fakeowner)"
else
    fail "the placeholder credential lost its :ro mount" \
        "chmod alone is a no-op on Docker Desktop's fakeowner binds"
fi

# ── The sidecar topology ─────────────────────────────────────────
# The whole point of serving the view from its own container: the agent's must be capless at
# CREATION. Each of these was a live property of the in-container-mount window, and losing any
# one silently hands the agent mount capability back.
_red="$(sed 's/#.*$//' "$KIB_ROOT/host/redaction.sh")"
_life="$(sed 's/#.*$//' "$KIB_ROOT/host/lifecycle.sh")"

# lifecycle.sh builds the agent container's whole argv, so none of the four may appear in it at
# all. (redaction.sh legitimately passes them — to the SIDECAR.)
_leaked=""
for _flag in 'cap-add=SYS_ADMIN' 'cap-add=SETPCAP' '/dev/fuse' 'apparmor=unconfined'; do
    case "$_life" in *"$_flag"*) _leaked="$_leaked $_flag" ;; esac
done
# …and the one thing redaction.sh hands the agent is the bind, nothing else. Pinned exactly:
# an added flag lands on this line.
# shellcheck disable=SC2016  # matching redaction.sh's source text; the $vars stay literal
printf '%s\n' "$_red" | grep -q '^ *REDACTION_ARGS=(-v "\$FUSE_ROOT/mnt:\$PWD:rslave")$' \
    || _leaked="$_leaked REDACTION_ARGS"
if [ -z "$_leaked" ]; then
    pass "the agent's container is capless at creation (no SYS_ADMIN/SETPCAP//dev/fuse/apparmor)"
else
    fail "the agent's container regained:$_leaked" \
        "the sidecar holds the mount; nothing the agent runs may be able to mount"
fi

# `setpriv` was how the in-container mount clawed the caps back off each session. Its return
# means the container is being created with caps to drop again.
if printf '%s\n' "$_life" | grep -q 'setpriv'; then
    fail "host/lifecycle.sh runs setpriv on the session exec again" \
        "capless-at-runtime is the shape the sidecar exists to replace"
else
    pass "sessions need no runtime cap drop (nothing was granted to drop)"
fi

# Ordering, not presence: killing the server first leaves a mounted-but-ENOTCONN path that the
# next launch's rm -rf would delete THROUGH — the real project. Confirmed live on Docker Desktop
# that the mount outlives the container, so this is not theoretical.
_td="$(printf '%s\n' "$_red" | awk '/^teardown_redaction\(\)/,/^}/')"
if printf '%s\n' "$_td" | grep -q '_unmount_view' \
    && [ "$(printf '%s\n' "$_td" | grep -n '_unmount_view' | head -1 | cut -d: -f1)" \
        -lt "$(printf '%s\n' "$_td" | grep -n 'docker rm' | head -1 | cut -d: -f1)" ]; then
    pass "teardown unmounts the view BEFORE removing the sidecar"
else
    fail "teardown_redaction removes the sidecar before unmounting its view" \
        "a stale ENOTCONN mount is orphaned every exit, and rm -rf then hits the real project"
fi

# …and it must WARN, not die: teardown_redaction runs from the EXIT trap ahead of
# merge_out_session, so aborting there loses the session's .claude.json/history fold-back and
# overwrites its exit code. The refusal to delete a live view moves to the next launch instead.
if printf '%s\n' "$_td" | grep -q '_stale_mount_report warn' \
    && ! printf '%s\n' "$_td" | grep -q '_stale_mount_report die'; then
    pass "a view that will not unmount warns at teardown (the exit path still merges out)"
else
    fail "teardown_redaction dies on a view it could not unmount" \
        "it runs before merge_out_session, so the session's config changes are lost"
fi

# The sidecar's own /etc/passwd is synthesised, never the host's. fusermount3 aborts if it
# cannot resolve its uid, and binding the host's file works on Linux but CANNOT on macOS, where
# Open Directory keeps real users out of it.
# shellcheck disable=SC2016  # matching redaction.sh's source text: $PASSWD_STATE stays literal
if printf '%s\n' "$_red" | grep -q -- '-v "\$PASSWD_STATE:/etc/passwd:ro"' \
    && ! printf '%s\n' "$_red" | grep -q -- '-v /etc/passwd'; then
    pass "the sidecar gets a synthesised /etc/passwd, not the host's"
else
    fail "the sidecar binds the host's /etc/passwd" \
        "fusermount3 cannot resolve uid 501 from it on macOS — and it leaks the user table"
fi
unset _red _life _agent_args _leaked _flag _td

# The mount must remap ownership: on macOS the project reaches the sidecar over virtiofs as
# root:root, and without --uid/--gid git reads the whole tree as another user's and refuses it.
if grep -q -- '--uid' "$KIB_ROOT/host/redaction.sh" \
    && grep -q -- '--gid' "$KIB_ROOT/host/redaction.sh"; then
    pass "the FUSE view remaps ownership to the agent (git 'dubious ownership')"
else
    fail "the sidecar lost its --uid/--gid remap" \
        "virtiofs reports root:root; git then refuses the whole tree"
fi

# The server's syscalls run as ITS uid, not the caller's. Without default_permissions nothing in
# the project is permission-checked and a `chmod 000` file reads and writes fine.
if grep -q 'default_permissions=True' "$KIB_ROOT/kib/guest/fuse.py"; then
    pass "the FUSE mount asks the kernel to enforce owner/mode (default_permissions)"
else
    fail "kib/guest/fuse.py no longer mounts with default_permissions=True" \
        "a passthrough enforces no POSIX permission at all without it"
fi

# Inodes the server creates land on the HOST. Every path that makes one has to hand it to the
# caller, or a project file ends up owned by whoever the server happens to run as.
_unadopted=""
for _op in create mkdir symlink; do
    awk -v op="$_op" '$0 ~ "^    def " op "\\(" {f=1} f && /_adopt\(/ {ok=1} f && /^$/ {f=0}
        END {exit ok?0:1}' "$KIB_ROOT/kib/guest/fuse.py" || _unadopted="$_unadopted $_op"
done
if [ -z "$_unadopted" ]; then
    pass "every inode the server creates is chown'd to the caller"
else
    fail "kib/guest/fuse.py:$_unadopted no longer adopts the inode it creates" \
        "the file lands on the host owned by the server's uid"
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
            # shellcheck source=SCRIPTDIR/../../host/_load.sh
            . "$KIB_ROOT/host/_load.sh"
            cd "$1" || exit 9
            kib_audit_gate launch
            echo GATE-RETURNED-OK
        ) 2>&1
    }

    # warn-class: a tracked path matching .kibignore is named, and the launch continues.
    (
        GIT_TEMPLATE_DIR='' git init -q "$dir/warn"
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
        GIT_TEMPLATE_DIR='' git init -q "$dir/refuse"
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
    GIT_TEMPLATE_DIR='' git init -q "$dir/clean" >/dev/null 2>&1
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

# The HOST_HOME symlink is what makes Claude's absolute-path-keyed config resolve in the box.
# Its parent may not exist: macOS homes are under /Users, which a debian image has no reason to
# carry, and there is no $PWD bind to create it. `ln` then failed ENOENT and the
# entrypoint's `set -e` killed PID 1 — the container died during startup with no message.
# shellcheck disable=SC2016  # literal grep pattern: it must match the source text verbatim
hh_block="$(sed -n '/^if .*! -e "\$HOST_HOME"/,/^fi$/p' \
    "$KIB_ROOT/guest/entrypoint/docker-entrypoint.sh")"
# shellcheck disable=SC2016
if printf '%s\n' "$hh_block" | grep -q 'mkdir -p "\$(dirname "\$HOST_HOME")"'; then
    pass "the entrypoint creates HOST_HOME's parent before symlinking it"
else
    fail "the entrypoint symlinks HOST_HOME without creating its parent" \
        "on macOS /Users is not in the image, so the container exits during startup"
fi

# …and the `.claude` alias one level down must cover BOTH $USER_HOME and $HOST_HOME, because
# which one Claude resolves depends on the block above. The sidecar's $PWD bind makes $HOST_HOME
# a REAL directory for a project under $HOME, so that block is skipped and $USER_HOME/.claude is
# invisible; a project outside $HOME gets the symlink and needs the $USER_HOME spelling instead.
# Pinning one spelling is how a host-installed plugin's absolute installPath dangled:
# enabledPlugins true, nothing in /mcp, no error anywhere.
# shellcheck disable=SC2016  # literal grep pattern: it must match the source text verbatim
if grep -q 'for _h in "\$USER_HOME" "\${HOST_HOME:-}"' \
    "$KIB_ROOT/guest/entrypoint/docker-entrypoint.sh" \
    && grep -q 'ln -s "\$CLAUDE_SESSION_DIR" "\$_h/\.claude"' \
        "$KIB_ROOT/guest/entrypoint/docker-entrypoint.sh"; then
    pass "the .claude alias is placed at both \$USER_HOME and \$HOST_HOME"
else
    fail "the entrypoint's .claude alias covers only one of \$USER_HOME / \$HOST_HOME" \
        "host-installed plugins dangle and their MCP servers silently never start"
fi

# …and the alias only makes a recorded path RESOLVE. Claude also validates it is inside the running
# config dir, which no symlink can satisfy, so the dir must be SPELLED the way the host spells it.
# The real assignment is evaluated against a fake HOME/PWD, step-aside included.
_cdir_src="$(sed -n '/^SESSION_CDIR=/,/esac$/p' "$KIB_ROOT/host/lifecycle.sh")"
_cdir() (
    HOME="$1" PWD="$2"
    eval "$_cdir_src"
    printf '%s\n' "$SESSION_CDIR"
)
is "the config dir is spelled with the host's own home (linux)" \
    "/home/kay/.claude" "$(_cdir /home/kay /home/kay/proj)"
is "the config dir is spelled with the host's own home (macos)" \
    "/Users/veronica/.claude" "$(_cdir /Users/veronica /Users/veronica/proj)"
is "a project inside canonical's store steps aside from a nested bind" \
    "/home/hostuser/.claude-session" "$(_cdir /home/kay /home/kay/.claude/plugins/foo)"
unset _cdir_src

# ── The plugin farm must be real dirs down to where the installer writes ──────────────
# `/plugin install` clones into plugins/cache/temp_git_*, then renames onto
# plugins/cache/<marketplace>/<plugin>/<version>. A farm that stopped one level down left
# cache/<marketplace> a symlink into the READ-ONLY shared mount whenever canonical already held
# that marketplace, so the rename failed EROFS — the UI sat on "Installing…" for good and the
# clone was stranded. Behavioural, not a grep: the functions are extracted and run, against a
# shared tree made read-only exactly as the :ro bind makes it.
_farm_tmp="$(mktemp -d)"
sed -n '/^    prune_farm() {/,/^    }$/p; /^    farm_dir() {/,/^    }$/p' \
    "$KIB_ROOT/guest/entrypoint/docker-entrypoint.sh" | sed 's/^    //' >"$_farm_tmp/farm.sh"
mkdir -p "$_farm_tmp/shared/cache/mkt/plug/1.0.0" "$_farm_tmp/shared/cache/mkt/stale/1.0.0"
# Depth comes from the entrypoint's own CALL SITE, never a literal here: a function that supports
# a depth is worth nothing if the caller stops passing one. No match yields "" → floored to 0, the
# exact one-level farm that shipped broken, so the guard fails closed.
# shellcheck disable=SC2016  # a literal sed pattern: it must match the source text verbatim
_farm_depth="$(sed -n \
    's|.*farm_dir "\$CLAUDE_SHARED_DIR/plugins/cache" "\$CLAUDE_SESSION_DIR/plugins/cache" *\([0-9]*\) *$|\1|p' \
    "$KIB_ROOT/guest/entrypoint/docker-entrypoint.sh")"
cat >"$_farm_tmp/run.sh" <<'RUN'
set -e
CLAUDE_SHARED_DIR="$PWD/shared"
. ./farm.sh
farm_dir "$PWD/shared/cache" "$PWD/session/cache" "${FARM_DEPTH:-}"
RUN
if [ "$(id -u)" = "0" ]; then
    skip "the plugin farm reaches the installer's write depth" "root ignores the read-only bit"
else
    chmod -R a-w "$_farm_tmp/shared" # stand in for the :ro shared mount
    (cd "$_farm_tmp" && FARM_DEPTH="$_farm_depth" sh run.sh) >/dev/null 2>&1
    # The write an install actually performs: a new version inside an EXISTING shared plugin.
    if mkdir -p "$_farm_tmp/session/cache/mkt/plug/2.0.0" 2>/dev/null; then
        pass "/plugin install can write cache/<marketplace>/<plugin>/<version>"
    else
        fail "/plugin install cannot write cache/<marketplace>/<plugin>/<version>" \
            "the farm stops above the depth it writes at — install hangs on 'Installing…'"
    fi
    is "a shared version stays visible through the deepened farm" "symlink" \
        "$([ -L "$_farm_tmp/session/cache/mkt/plug/1.0.0" ] && echo symlink || echo missing)"

    # Deepening means we now CREATE mirror dirs, so they must be torn down too: a plugin dropped
    # from canonical would linger as a dir of dangling links — "enabled but nothing in /mcp".
    chmod -R u+w "$_farm_tmp/shared"
    rm -rf "$_farm_tmp/shared/cache/mkt/stale"
    chmod -R a-w "$_farm_tmp/shared"
    (cd "$_farm_tmp" && FARM_DEPTH="$_farm_depth" sh run.sh) >/dev/null 2>&1
    is "a plugin deleted from the shared dir leaves no dangling mirror" "gone" \
        "$([ -e "$_farm_tmp/session/cache/mkt/stale" ] && echo lingering || echo gone)"
    is "a locally installed version survives the re-farm" "kept" \
        "$([ -d "$_farm_tmp/session/cache/mkt/plug/2.0.0" ] && echo kept || echo lost)"
    chmod -R u+w "$_farm_tmp/shared"
fi
rm -rf "$_farm_tmp"
unset _farm_tmp

# A failed install strands its staging clone (hundreds of files) in plugins/cache/, which every
# later start then re-walks and re-chowns — the compounding cost that read as "frozen on startup".
# shellcheck disable=SC2016  # literal grep pattern: it must match the source text verbatim
if grep -q 'rm -rf "\$CLAUDE_SESSION_DIR"/plugins/cache/temp_git_\*' \
    "$KIB_ROOT/guest/entrypoint/docker-entrypoint.sh"; then
    pass "the entrypoint sweeps stranded plugin-install staging clones"
else
    fail "the entrypoint no longer sweeps plugins/cache/temp_git_*" \
        "a failed install's clone is re-walked and re-chowned at every container start"
fi

# Same cost, unbounded: the session-dir chown must not walk the whole plugin cache. It has to
# stay deep enough to cover the farm, though — that is the only root-created thing in there —
# so derive what farm_dir actually plants (target's depth + its depth argument + the leaf link)
# and hold the -maxdepth to it. Deepen one without the other and root-owned symlinks come back.
_ep="$KIB_ROOT/guest/entrypoint/docker-entrypoint.sh"
if grep -q 'chown -Rh .*CLAUDE_SESSION_DIR' "$_ep"; then
    fail "the session-dir chown is recursive again" \
        "it walks 100k+ plugin-cache entries — ~30s of macOS cold start (macos.md)"
else
    # shellcheck disable=SC2016  # awk program: $ is awk's, not the shell's
    _need="$(awk '/^ *farm_dir "\$CLAUDE_SHARED_DIR/ {
        d = split($3, seg, "/") - 1 + ($4 == "" ? 0 : $4) + 1
        if (d > max) max = d
    } END { print max + 0 }' "$_ep")"
    _bound="$(sed -n 's/.*-maxdepth \([0-9][0-9]*\).*/\1/p' "$_ep" | head -1)"
    is "the session-dir chown is bounded, and still covers the farm" "yes" \
        "$([ -n "$_bound" ] && [ "$_bound" -ge "$_need" ] && echo yes || echo "no ($_bound < $_need)")"
fi
unset _ep _need _bound

# The project container must NOT be created with --rm. It is the only place a startup failure
# explains itself: with --rm the engine reaped the container before wait_for_container_ready
# could read its logs, and the whole diagnostic was "No such container". teardown_container
# removes it explicitly instead.
sc_block="$(sed -n '/^start_container()/,/^}$/p' "$KIB_ROOT/host/lifecycle.sh")"
# shellcheck disable=SC2016  # a literal grep pattern: it must match the source text verbatim
rm_calls="$(grep -c 'docker rm -f "\$CNAME"' "$KIB_ROOT/host/lifecycle.sh" || true)"
if printf '%s\n' "$sc_block" | grep -q -- '--rm'; then
    fail "the project container is created with --rm" \
        "a container that dies during startup is reaped before its logs can be read"
elif [ "${rm_calls:-0}" -eq 0 ]; then
    fail "nothing removes the project container" "without --rm, teardown must rm it explicitly"
else
    pass "the project container survives a startup crash long enough to be logged"
fi
