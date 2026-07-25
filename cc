#!/usr/bin/env bash
set -euo pipefail

# Host-side launcher. Brings up this project's container (or attaches to the running
# one) and runs the session inside it via `docker exec`. The subsystems it drives —
# image build/update, .ccignore redaction, gitignore/pre-commit sync — live in cc-lib.sh.

# ── Peel off the `cc`=`kib claude` alias's leading token(s), FIRST ──
# README's ~/.bashrc setup makes `cc` an alias for `$PWD/cc claude` — so EVERY invocation
# through it, including `cc --unlock-shared`, `cc --broker-login`, `cc --login foo`, etc.,
# arrives here with a `claude` token in front of the user's real first argument. Every check
# below that inspects "$1"/"$2" (the dir guard, --unlock-shared, the broker/provider subcommand
# dispatch, intercept_mcp_add, the final command dispatch) assumes a bare-flag/subcommand
# shape and silently falls through to `claude` itself otherwise — `claude` then rejects the
# flag it's never heard of. Strip however many appear (a second shows up only if the user also
# typed it out of habit: `cc claude mcp add`) once, here, before anything looks at "$1".
while [ "${1:-}" = claude ]; do shift; done

# ── Guard: forbid launching from sensitive host directories ──
# Exactly $HOME, ~/Desktop, ~/Documents, ~/Downloads; subdirectories are fine. Runs
# before any trap is installed, so the error stays on screen after exit.
#
# The credential subcommands are exempt: they manage HOST-GLOBAL credentials, never touch the
# project dir, and $HOME is the natural place to run them from — the guard below would
# otherwise reject `cc --login` there. (Dispatched further down, after sourcing cc-lib.sh.)
# --mcp-adopt DOES touch the project (it reads .mcp.json), so it is NOT exempt.
case "${1:-}" in
    --broker-login | --broker-logout | --broker-status | --login | --logout | --status | --add-mcp) _skip_dir_guard=1 ;;
    # `mcp add|add-json` is intercepted host-side (host-global, identity-free, like --add-mcp),
    # so it must work from $HOME too. A normal interactive session stays guarded. (The `cc`
    # alias's leading `claude` token(s) are already stripped above, so this sees the real
    # command whether it arrived as `cc mcp add …` or a bare `kib mcp add …`.)
    mcp) case "${2:-}" in add | add-json) _skip_dir_guard=1 ;; *) _skip_dir_guard=0 ;; esac ;;
    *) _skip_dir_guard=0 ;;
esac
_pwd="$(realpath "$PWD" 2>/dev/null || echo "$PWD")"
_home="$(realpath "$HOME" 2>/dev/null || echo "$HOME")"
_blocked=""
if [ "$_pwd" = "$_home" ]; then
    _blocked="\$HOME"
else
    for _dir in Desktop Documents Downloads; do
        [ "$_pwd" = "$_home/$_dir" ] && {
            _blocked="~/$_dir"
            break
        }
    done
fi
if [ -n "$_blocked" ] && [ "$_skip_dir_guard" = 0 ]; then
    echo "" >&2
    echo "❌ cc refuses to launch from $_blocked ($PWD)." >&2
    echo "   These directories are on the permanent forbidden list:" >&2
    echo "     \$HOME, ~/Desktop, ~/Documents, ~/Downloads" >&2
    echo "   (subdirectories are allowed — cd into one and retry.)" >&2
    echo "" >&2
    exit 1
fi
unset _pwd _home _blocked _dir _skip_dir_guard

IMAGE_NAME="keep-it-in-your-box"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── cc's own flags ───────────────────────────────────────────
# Consumed here so they never reach claude. --unlock-shared drops the read-only mounts over
# the shared assets, so an install lands in canonical ~/.claude for EVERY project (and the
# host claude) rather than just this one (see "Shared config surface" in CLAUDE.md).
UNLOCK_SHARED="${CC_UNLOCK_SHARED:-0}"
if [ "${1:-}" = "--unlock-shared" ]; then
    UNLOCK_SHARED=1
    shift
fi

# cc-portable.sh first: it owns all OS branching (CC_OS, the lock/hash/notify
# shims, preflight) and cc-lib.sh's helpers build on it. shellcheck source=cc-portable.sh
. "$SCRIPT_DIR/cc-portable.sh" || {
    echo "❌ cc: cannot load $SCRIPT_DIR/cc-portable.sh — the install is incomplete." >&2
    exit 1
}
# shellcheck source=cc-lib.sh
. "$SCRIPT_DIR/cc-lib.sh" || {
    echo "❌ cc: cannot load $SCRIPT_DIR/cc-lib.sh — the install is incomplete." >&2
    exit 1
}

# ── Broker token lifecycle: mint / remove / check, then exit ─────
# Handled AFTER sourcing (they need cc-lib.sh) but BEFORE preflight/build/identity: managing
# the token must work when the image is missing, the container is broken, or the project dir
# is irrelevant. Each subcommand exits with its own status — `cc --broker-status` returning
# non-zero is a usable exit code for a script.
# The `&& exit 0 || exit $?` form is deliberate: a function called bare would trip `set -e`
# the moment it returns non-zero (a rejected or absent token), skipping its own reporting.
# In an && / || list errexit is suspended, so the function always runs to completion and cc
# controls the exit status.
case "${1:-}" in
    --broker-login)
        shift
        broker_login && exit 0 || exit $?
        ;;
    --broker-logout)
        shift
        broker_logout && exit 0 || exit $?
        ;;
    --broker-status)
        shift
        broker_status && exit 0 || exit $?
        ;;
    # Unified, registry-driven surface. `cc --login <name>` (name defaults to claude), etc.
    --login)
        shift
        provider_login "${1:-claude}" && exit 0 || exit $?
        ;;
    --logout)
        shift
        provider_logout "${1:-claude}" && exit 0 || exit $?
        ;;
    --status)
        shift
        provider_status && exit 0 || exit $?
        ;;
    --add-mcp)
        shift
        mcp_add "$@" && exit 0 || exit $?
        ;;
        # Migrate an inline-credential MCP (claude mcp add --header …) into the broker. Touches the
        # project dir, so it runs after identity is known — dispatched below, not here.
esac

# Front-line preventer: catch a pasted `cc [claude] mcp add … --header/--env <secret>` (the user
# swaps claude→cc) HERE, host-side, before it can carry a secret into the container as argv. Its
# tri-state exit drives ours — 0 = auto-brokered/staged (done), 2 = blocked, anything else = not
# an intercept, fall through to a normal launch. See intercept_mcp_add in cc-lib.sh.
_ic=0
intercept_mcp_add "$@" || _ic=$?
[ "$_ic" = 0 ] && exit 0
[ "$_ic" = 2 ] && exit 2
unset _ic

preflight_platform # darwin: engine/perl/bind-mount checks; linux: no-op
build_image_if_missing
check_for_updates

# ── Identity: ONE container per project ──────────────────────
# Claude supports several concurrent sessions in one config dir (a [concurrentSessions]
# pid registry; the daemon arbitrates via daemon.lock). Both mechanisms assume the
# sessions share a PID namespace and a /tmp — true for two terminals on the host, false
# for two containers. So cc keeps one *long-lived* container per project and attaches
# every terminal to it with `docker exec`; Claude then sees what it sees on the host and
# its own arbitration does the work.
#
# The name must therefore be stable per project. Hash $PWD so two projects with the same
# basename don't collide.
PROJ_HASH="$(hash8 "$PWD")"
CNAME="cc-$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-40)-$PROJ_HASH"

# ── Per-project Claude session isolation ─────────────────────
# ~/.claude and ~/.claude.json stay CANONICAL and stock-untouched — the same login,
# transcripts and history a plain host `claude` sees, so switching between host claude and cc
# is seamless. Per-project isolation comes from ASSEMBLING each container's config from that
# canonical store per launch (into $SESSION_BASE/$SHARED_BASE below) and merging this project's
# changes back out on exit. Mounting one ~/.claude into every container instead made concurrent
# sessions fight over daemon.lock — and let every container read every other project's
# transcripts. See docs/design-notes/.
CLAUDE_HOME="$HOME/.claude"
CLAUDE_JSON="$HOME/.claude.json"
# cc-owned scratch/state, separate from canonical ~/.claude AND the never-mounted token dir
# ~/.keep-it-in-your-box/. XDG_STATE_HOME-respecting.
CC_STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/keep-it-in-your-box"
SLUG="$(printf '%s' "$PWD" | sed 's/[^a-zA-Z0-9]/-/g')"
# The two assembled dirs backing the two container paths (CLAUDE_CONFIG_DIR /
# CLAUDE_SECURESTORAGE_CONFIG_DIR). Rebuilt on each cold start from canonical ~/.claude.
SESSION_BASE="$CC_STATE_ROOT/$SLUG/session"
SHARED_BASE="$CC_STATE_ROOT/$SLUG/shared"
EPHEMERAL=0

# The locks arbitrating the container's lifetime live OUTSIDE the bind-mounted dirs, because
# those are bind-mounted rw into the container: a sandboxed Claude could delete the lock file
# from inside, and unlinking a lock whose inode another cc holds flocked lets the next one lock
# a *fresh* inode — two "last terminals out", both tearing down the container under a live
# session. Keep them host-only under $CC_STATE_ROOT (never mounted in).
LOCK_DIR="$CC_STATE_ROOT/.locks"
LOCK_FILE="$LOCK_DIR/$SLUG.lock"
BOOT_LOCK="$LOCK_DIR/$SLUG.boot.lock"

# Host-only state for the single-container FUSE mode, the macOS clipboard bridge, and the
# shared-config lock witness. Kept OUT of the bind-mounted dirs for the same reason as the
# locks: a sandboxed Claude must not edit the patterns redaction is validated against, the
# bridge's spool, or the lock witness. Per-container paths (below, next to FUSE_ROOT) pick up
# SCRATCH_SUFFIX so an ephemeral session never shares the real one's state.
STATE_DIR="$CC_STATE_ROOT/.state"

# Suffix for this session's scratch dirs. Empty for the project's shared container; set
# for an ephemeral one so it can never touch the real one's (see CC_FORCE_NEW_SESSION).
SCRATCH_SUFFIX=""

# Canonical ~/.claude must exist (or be freshly skeletoned). Runs before any assembly reads it.
ensure_claude_home() {
    [ -d "$CLAUDE_HOME" ] && return 0
    # Fresh install: a minimal skeleton; Claude + first login populate the rest.
    mkdir -p "$CLAUDE_HOME/projects" && chmod 700 "$CLAUDE_HOME"
    echo "🆕 cc: no ~/.claude yet — created a fresh skeleton (first login populates it)." >&2
}
ensure_claude_home

mkdir -p "$LOCK_DIR" && chmod 700 "$LOCK_DIR"
mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"

validate_shared_settings

if [ "$UNLOCK_SHARED" = 1 ]; then
    echo "⚠️  --unlock-shared: your ~/.claude plugins/skills/agents/commands/hooks are WRITABLE" >&2
    echo "   this session — an install lands in ~/.claude, shared with every project + host claude." >&2
else
    echo "🔒 shared config: read-only (installs land per-project; cc --unlock-shared to share)" >&2
fi

# Config dirs backing the two container paths. Created here (needed for lock/pin/warn paths);
# their CONTENTS are assembled fresh from canonical ~/.claude on the cold-start path only
# (assemble_session_dir), never while a container is already attached to them.
if [ "${CC_FORCE_NEW_SESSION:-0}" = "1" ]; then
    # Clean slate: its own container AND its own config dirs, so it has its own daemon and
    # cannot collide with the project's real one. Throwaway — discarded on exit, merge-out
    # disabled. Not needed just to open a second terminal (that attaches to the shared one).
    EPH_ROOT="$CC_STATE_ROOT/$SLUG.ephemeral.$$"
    SESSION_BASE="$EPH_ROOT/session"
    SHARED_BASE="$EPH_ROOT/shared"
    CNAME="$CNAME-eph-$$"
    EPHEMERAL=1
    # Its own scratch dirs too. Sharing the project's would mean this session's startup
    # ("clear anything a crashed session left behind") and its exit both tear down the
    # real container's live FUSE mount, unmasking .ccignore'd files under a live session.
    SCRATCH_SUFFIX=".eph.$$"
    mkdir -p "$SESSION_BASE" && chmod 700 "$SESSION_BASE"
    mkdir -p "$SHARED_BASE" && chmod 700 "$SHARED_BASE" # holds the real credential on the broker-off path
    # Reap it even if we bail out below (e.g. the sidecar fails): the real cleanup() trap
    # isn't installed until just before the container starts.
    trap 'rm -rf "$EPH_ROOT"' EXIT
    echo "⚠️  CC_FORCE_NEW_SESSION=1 — ephemeral session; no history, discarded on exit." >&2
else
    mkdir -p "$SESSION_BASE" && chmod 700 "$SESSION_BASE"
    mkdir -p "$SHARED_BASE" && chmod 700 "$SHARED_BASE" # holds the real credential on the broker-off path
    # SHARED lock, held for this terminal's lifetime: a reference count on the project's
    # container, not a mutex — any number of terminals hold it at once. It blocks only
    # while a departing session holds the lock *exclusively* to tear the container down,
    # so we can never attach to a dying container. Never unlinked (see build.lock).
    exec 200>"$LOCK_FILE"
    lock_fd -w 60 -s 200 || die "timed out waiting for the project lock ($LOCK_FILE)."
fi

# ── Assemble this project's config from canonical ~/.claude ──────
# scope-in .claude.json (globals + THIS project only), seed ↑ history to this project's lines,
# and place the assembled sandbox-policy CLAUDE.md. Cold-start only (called in the else branch
# of the container-running check below) so we never rewrite the config dir a live container is
# attached to. Uses claude-config-scope.py — the single home for the JSON/JSONL surgery.
_scope_py() { python3 "$SCRIPT_DIR/claude-config-scope.py" "$@"; }

assemble_session_dir() {
    # Empty private base for the machine-runtime singletons (daemon, sessions, file-history…);
    # anything Claude Code writes that we don't recognise lands here, never in canonical.
    mkdir -p "$SESSION_BASE/projects" 2>/dev/null || true

    # Scoped .claude.json (globals + this project's entry only). Fail-soft to an empty config.
    if command -v python3 >/dev/null 2>&1; then
        _scope_py scope-in-json "$CLAUDE_JSON" "$PWD" "$SESSION_BASE/.claude.json" \
            || warn "could not scope .claude.json — starting this session from an empty config."
    else
        printf '{\n  "projects": {}\n}\n' >"$SESSION_BASE/.claude.json"
    fi
    # This project's ↑ history only (never another project's prompts/pastes).
    if command -v python3 >/dev/null 2>&1; then
        _scope_py seed-history "$CLAUDE_HOME/history.jsonl" "$PWD" "$SESSION_BASE/history.jsonl" \
            || : >"$SESSION_BASE/history.jsonl"
    else
        : >"$SESSION_BASE/history.jsonl"
    fi
    # Sandbox policy + the user's canonical memory, placed directly (not a shared symlink).
    assemble_sandbox_claude_md

    # settings.json/keybindings.json as a COPY in the shared-assembly dir — never a live bind on
    # canonical, which would let the box write the file a host `claude` loads. Vetted on the way
    # back out (merge_out_shared_settings).
    stage_shared_settings

    # Silent-log drift canary: note any top-level ~/.claude entry cc doesn't recognise. Safe by
    # default (unknown → container-private), so this only surfaces "Claude Code grew a store".
    check_claude_home_drift

    # This project's transcripts are shared host<->box via a nested bind (added in
    # start_container), so --resume lists the same sessions on both sides. Both ends must exist
    # for the bind. NOT for an ephemeral session: it must persist nothing to canonical, so its
    # transcripts stay in its own (discarded) session base instead.
    [ "$EPHEMERAL" = 1 ] || mkdir -p "$CLAUDE_HOME/projects/$SLUG" 2>/dev/null || true
}

# Diff canonical ~/.claude's top-level entries against the versioned manifest; LOG ONLY (no
# desktop popup). A stronger line when /etc/claude-code-version changed since we last saw it.
check_claude_home_drift() {
    command -v python3 >/dev/null 2>&1 || return 0
    local unknown
    unknown="$(_scope_py classify "$CLAUDE_HOME" 2>/dev/null || true)"
    [ -n "$unknown" ] || return 0
    echo "ℹ️  cc: unrecognised ~/.claude entries (kept container-private, not shared): $(printf '%s' "$unknown" | tr '\n' ' ')" >&2
}

# pin_global_config runs later, per launch, on both the cold-start and attach paths (it needs
# the assembled .claude.json, which only exists after assemble_session_dir on a cold start).

# Migrate an inline-credential MCP into the broker, then exit. Runs here (not with the other
# subcommands) because it reads the project's .mcp.json and this session's .claude.json, both
# of which need identity resolved. Never starts a container.
if [ "${1:-}" = "--mcp-adopt" ]; then
    shift
    mcp_adopt "${1:-}" && exit 0 || exit $?
fi

# Warn (never block) if an MCP config carries an inline credential the agent can read. Runs on
# every launch — create and attach — since a user may add one between sessions.
warn_inline_mcp_secrets

sync_ccignore_gitignore

# ── Container lifecycle ──────────────────────────────────────
# The container outlives any single terminal, so everything it depends on (the sidecar,
# its scratch dirs) must be addressable by *any* cc process, not just its creator —
# hence paths derived from the project hash rather than mktemp.
FUSE_CNAME="${CNAME}-fuse"
FUSE_ROOT="/tmp/cc-fuse.${PROJ_HASH}${SCRATCH_SUFFIX}"
WL_CNAME="${CNAME}-wl"
WL_ROOT="/tmp/cc-wl.${PROJ_HASH}${SCRATCH_SUFFIX}"
# Single-container FUSE + clipboard bridge state (see STATE_DIR above). SCRATCH_SUFFIX is
# final by here, so an ephemeral session gets its own files and can't disturb the real one.
PATTERNS_STATE="$STATE_DIR/${SLUG}${SCRATCH_SUFFIX}.patterns"
CLIP_STATE="$STATE_DIR/${SLUG}${SCRATCH_SUFFIX}.clip"
# Credential-fallback witness: written by stage_credential at container creation when the box
# got the REAL ~/.claude/.credentials.json (broker off, or on-but-no-token). It has to be a
# host-side FILE, not a shell variable: the last terminal out is often one that merely ATTACHED
# and so never ran stage_credential — with a per-process flag it would skip merge_out_credential
# and leave canonical holding a refresh token the box has already rotated away, which logs the
# account out on the host (docs/design-notes/credential-broker.md).
CRED_WITNESS="$STATE_DIR/${SLUG}${SCRATCH_SUFFIX}.credfallback"
# Shared-config lock witness: a host-only file bound read-only into the shared-assembly dir
# ONLY when locked (the default). It is the ground-truth `running_unlocked` reads off the
# running container's mounts — a stable witness that always exists when locked, unlike any
# individual shared asset (a fresh user may have no plugins/skills/… to probe). See the mount
# block + running_unlocked below.
LOCK_WITNESS="$STATE_DIR/${SLUG}${SCRATCH_SUFFIX}.lockwitness"

# Credential broker (see cc-lib.sh "Credential broker"). Globals are always defined so the
# teardown/attach helpers can reference them unconditionally; the broker only actually runs
# when opted in. The network name derives from the project hash (docker network names allow
# [a-zA-Z0-9_.-]); an ephemeral suffix's dots are mapped to dashes to stay in the charset.
BROKER_CNAME="${CNAME}-broker"
BROKER_NET="ccbnet-${PROJ_HASH}$(printf '%s' "$SCRATCH_SUFFIX" | tr '.' '-')"
BROKER_DIR="$STATE_DIR/${SLUG}${SCRATCH_SUFFIX}.broker"
BROKER_OUT="$BROKER_DIR/out"
BROKER_HASH="$BROKER_DIR/hash"
BROKER_ENABLED=0
# The redaction interface (see cc-lib.sh) fills these: sidecar mode sets a mount
# SRC/OPTS for $PWD; single mode leaves SRC empty (the entrypoint mounts the view
# in-container) and appends its own `docker run` flags to REDACTION_ARGS.
PROJECT_MOUNT_SRC="$PWD"
PROJECT_MOUNT_OPTS=""
REDACTION_ARGS=()

container_running() { [ -n "$(docker ps -q -f "name=^${CNAME}$" 2>/dev/null)" ]; }
sidecar_running() { [ -n "$(docker ps -q -f "name=^${FUSE_CNAME}$" 2>/dev/null)" ]; }
broker_running() { [ -n "$(docker ps -q -f "name=^${BROKER_CNAME}$" 2>/dev/null)" ]; }

# Was the running container created with --unlock-shared? Read it off the mounts, which are
# the ground truth — no state file to go stale. The lock witness is the probe: cc binds it
# read-only into the shared-assembly dir ONLY when locked, and — unlike any individual shared
# asset (a fresh user may have no plugins/skills/…) — it is guaranteed present when locked.
running_unlocked() {
    ! docker inspect -f '{{range .Mounts}}{{.Destination}}{{"\n"}}{{end}}' "$CNAME" 2>/dev/null \
        | grep -qx '/home/hostuser/.claude-shared/.cc-shared-locked'
}

# `docker run -d` returns as soon as PID 1 exists, but the entrypoint still has real work
# to do as root — useradd, the shared-asset symlink farm, chown of the session dir —
# before it execs `gosu … sleep infinity`. An immediate `docker exec` would land mid-setup:
# no home dir yet, no symlinks, a chown walking the tree under us.
#
# Readiness is therefore a process whose command line is *exactly* `sleep infinity`, which
# only exists once the entrypoint has exec'd. The exactness is load-bearing: while the
# entrypoint is still working its own argv is `/bin/sh …/docker-entrypoint.sh sleep
# infinity`, and PID 1 (docker-init) carries `… -- …docker-entrypoint.sh sleep infinity`
# forever — a substring match would call a half-set-up container ready.
container_ready() {
    local args
    args="$(docker top "$CNAME" -o args 2>/dev/null)" \
        || args="$(docker top "$CNAME" 2>/dev/null \
            | awk 'NR>1 { $1=$2=$3=$4=$5=$6=$7=""; sub(/^ +/,""); print }')"
    printf '%s\n' "$args" | grep -qx 'sleep infinity'
}

wait_for_container_ready() {
    local _
    # ≤60s; a cold entrypoint is ~1s
    for _ in $(seq 1 120); do
        container_ready && return 0
        if ! container_running; then
            echo "❌ cc: the project container exited during startup. Logs:" >&2
            docker logs "$CNAME" 2>&1 | tail -20 | sed 's/^/   /' >&2 || true
            teardown_container
            exit 1
        fi
        sleep 0.5
    done
    # Leave nothing half-started behind: a running-but-never-ready container would make
    # every later cc attach to it and hit this same timeout.
    echo "❌ cc: the project container never finished starting up (60s)." >&2
    docker logs "$CNAME" 2>&1 | tail -20 | sed 's/^/   /' >&2 || true
    teardown_container
    exit 1
}

teardown_container() {
    docker stop -t 5 "$CNAME" >/dev/null 2>&1 || true # started with --rm; stop removes it

    # Redaction teardown is mode-specific (sidecar: unmount + rm the FUSE container +
    # rm its scratch root, in that order; single: the mount died with the container,
    # so just drop the host state file). See teardown_redaction in cc-lib.sh.
    teardown_redaction

    # Clipboard mediation + its host-side notification follower. Plain dirs, so none of
    # the unmount care in the sidecar teardown applies. Both are no-ops in the mode that
    # didn't start them.
    stop_wayland_guard
    stop_clipboard_bridge

    # Credential broker sidecar + its user-defined network. After the main container is
    # stopped above, so the network has no endpoint and `docker network rm` succeeds. No-op
    # when the broker never ran.
    stop_broker

    # The resolv.conf watcher is an in-container process (a detached `docker exec`), so it is
    # killed when the container is removed — nothing to tear down here.
}

start_container() {
    # Redaction: sidecar (Linux) sets PROJECT_MOUNT_SRC to the redacting mount for
    # $PWD; single (macOS / CC_SINGLE_CONTAINER=1) leaves it empty and pushes its own
    # flags onto REDACTION_ARGS — the entrypoint mounts the view in-container.
    prepare_redaction
    # Clipboard: a mediated Wayland proxy on Linux, a pbpaste bridge on macOS. Both
    # must precede the mounts below (they bind the proxy socket / spool dir).
    if is_macos; then
        start_clipboard_bridge
    else
        start_wayland_guard
    fi

    # Credential broker: hold the real OAuth token host-side and hand the agent only a
    # placeholder + ANTHROPIC_BASE_URL pointed at the broker. Must precede the ARGS below,
    # which add that base-URL env and the placeholder shadow (add_broker_env_args). On by
    # default; a first launch with no token runs the login, or falls back to the real cred.
    start_broker
    # If the broker isn't shadowing a synthetic credential (off, or on-but-no-token fallback),
    # copy the real ~/.claude/.credentials.json into the shared-assembly DIR so the box can
    # authenticate. Copy, never a single-file bind (rename footgun); folded back on exit.
    stage_credential

    # --init: PID 1 is `sleep infinity`, which would never reap the zombies left behind by
    # exec'd sessions. Docker's init does.
    ARGS=(
        -d --init --rm
        --name "$CNAME"

        # This project's private state: daemon, sessions, jobs, and the three files assembled
        # from canonical (.claude.json, history.jsonl, CLAUDE.md). No other project mounts it.
        -v "$SESSION_BASE:/home/hostuser/.claude-session"

        # Shared-assembly dir: a real host directory the shared assets nest-bind into (below),
        # plus the credential (synthetic shadow, or the real one copied in by stage_credential).
        # A real dir, so Claude's atomic credential rename works.
        -v "$SHARED_BASE:/home/hostuser/.claude-shared"

        # config (+ .claude.json) resolve to the per-project session dir; the credential store
        # to the shared-assembly dir. Container-side paths unchanged from the old layout.
        -e CLAUDE_CONFIG_DIR=/home/hostuser/.claude-session
        -e CLAUDE_SECURESTORAGE_CONFIG_DIR=/home/hostuser/.claude-shared

        # Host UID/GID/HOME for runtime user creation. `docker exec` inherits these from
        # the container config, so attached sessions get them too.
        -e HOST_UID="$(id -u)"
        -e HOST_GID="$(id -g)"
        -e HOST_HOME="$HOME"
        -e HOST_PWD="$PWD"

        # Drop everything; add back only what the entrypoint needs for user setup + gosu.
        --cap-drop=ALL
        --cap-add=SETUID
        --cap-add=SETGID
        --cap-add=CHOWN
        --cap-add=DAC_OVERRIDE
        --cap-add=FOWNER

        # The image still ships setuid binaries (su, mount, passwd, fusermount3), and the
        # entrypoint drops to the host uid via gosu. no-new-privileges makes a setuid exec
        # unable to regain privileges afterwards. Defence in depth: the session's caps are
        # already empty, so this closes the escalation route rather than a live hole.
        --security-opt no-new-privileges

        # Bridge network + Claude's own domain allowlist. --add-host so a dev server on
        # the host stays reachable.
        --add-host=host.docker.internal:host-gateway

        -e DISABLE_TELEMETRY=1
        -e DISABLE_ERROR_REPORTING=1

    )

    # Project at the same absolute path as on the host, so Claude's path-keyed project
    # configs resolve. Sidecar mode points $PWD at the redacting mount (rslave propagates
    # its sub-mounts in); single mode adds NO bind for $PWD — the in-container entrypoint
    # mounts the redacted view there itself — and supplies its own flags via REDACTION_ARGS.
    if [ -n "$PROJECT_MOUNT_SRC" ]; then
        ARGS+=(-v "$PROJECT_MOUNT_SRC:$PWD$PROJECT_MOUNT_OPTS")
    fi
    # `if`, not `[ … ] && ARGS+=`: the codebase's convention for array appends under set -e.
    if [ "${#REDACTION_ARGS[@]}" -gt 0 ]; then
        ARGS+=("${REDACTION_ARGS[@]}")
    fi

    # Clipboard mounts: the mediated Wayland socket on Linux (reads pass, writes refused —
    # the raw socket would be host code execution at your next terminal paste), or the
    # pbpaste bridge spool on macOS. Both no-op if their sidecar/bridge didn't come up.
    if is_macos; then
        add_clipboard_bridge_args
    else
        add_wayland_args
    fi

    # Follow the host's live DNS: mount systemd-resolved's live resolv.conf dir + the watcher
    # (see add_resolv_sync_args in cc-lib.sh). Linux only — on macOS the engine VM already
    # tracks the host resolver, so there is nothing to sync.
    is_macos || add_resolv_sync_args

    local git_name git_email
    git_name="$(git config --global user.name 2>/dev/null || true)"
    git_email="$(git config --global user.email 2>/dev/null || true)"
    if [ -n "$git_name" ]; then
        ARGS+=(
            -e GIT_AUTHOR_NAME="$git_name"
            -e GIT_COMMITTER_NAME="$git_name"
            -e GIT_AUTHOR_EMAIL="$git_email"
            -e GIT_COMMITTER_EMAIL="$git_email"
        )
    fi

    # Read-only: executed on the *host* later, so a container that could write it would
    # have host code execution (git hooks at the next commit). Belt-and-braces only — it
    # covers just this repo's top-level .git, and only if it exists at launch; the FUSE
    # guard is what actually covers nested repos, submodules and mid-session repos.
    # Sidecar mode only: in single mode $PWD is the in-container FUSE view, so binding the
    # host .git/hooks over it would shadow the view (and the guard already covers it).
    if [ "$CC_FUSE_MODE" = sidecar ] && [ -d "$PWD/.git/hooks" ]; then
        ARGS+=(-v "$PWD/.git/hooks:$PWD/.git/hooks:ro")
    fi

    # This project's transcripts, shared host<->box so --resume lists the same sessions on
    # both sides. Nested rw bind inside the session mount; Docker applies mounts parent-first.
    # Skipped for an ephemeral session — it must persist nothing to canonical, so its
    # transcripts stay in its own discarded session base.
    if [ "$EPHEMERAL" != 1 ] && [ -d "$CLAUDE_HOME/projects/$SLUG" ]; then
        ARGS+=(-v "$CLAUDE_HOME/projects/$SLUG:/home/hostuser/.claude-session/projects/$SLUG")
    fi

    # NOTE: settings.json / keybindings.json are deliberately NOT bound here. They are staged as
    # writable COPIES inside $SHARED_BASE (stage_shared_settings), which the whole-dir mount above
    # already serves, and vetted before they may re-enter canonical on exit. Binding canonical rw
    # here — as this did — let a sandboxed session write the settings.json a HOST `claude` loads.

    # plugins/skills/agents/commands/hooks auto-load in EVERY project's next session (and the
    # host claude), so a write from one sandboxed repo is a cross-project pivot (audit H6):
    # READ-ONLY by default. Nothing is lost — the entrypoint gives each project its own farmed
    # dir, so in-session creation/installs still work, they just land per-project. Under
    # --unlock-shared they are writable and installs land in canonical ~/.claude (promoted to
    # every project + the host claude).
    local _ro=":ro"
    [ "$UNLOCK_SHARED" = 1 ] && _ro=""
    local _entry
    # `if`, not `[ … ] && ARGS+=`: a false test on the final iteration would make the whole
    # loop exit 1, which under `set -e` kills cc before the container starts.
    for _entry in plugins skills agents commands hooks; do
        if [ -e "$CLAUDE_HOME/$_entry" ]; then
            ARGS+=(-v "$CLAUDE_HOME/$_entry:/home/hostuser/.claude-shared/$_entry$_ro")
        fi
    done

    # Lock witness: a read-only bind that exists ONLY when locked, so running_unlocked can read
    # the lock state off the mounts even for a user with no shared assets to probe.
    if [ "$UNLOCK_SHARED" = 0 ]; then
        printf 'locked\n' >"$LOCK_WITNESS" 2>/dev/null || true
        if [ -f "$LOCK_WITNESS" ]; then
            ARGS+=(-v "$LOCK_WITNESS:/home/hostuser/.claude-shared/.cc-shared-locked:ro")
        fi
    fi

    # Broker wiring: -e ANTHROPIC_BASE_URL + the placeholder credential that SHADOWS the real
    # .credentials.json. Appended after the shared mounts above so it overlays the file inside
    # them (Docker applies mounts parent-first). No-op unless the broker came up.
    add_broker_env_args

    # The container just idles; the real work runs in `docker exec` sessions, so it
    # survives any one terminal closing.
    docker run "${ARGS[@]}" "$IMAGE_NAME" sleep infinity >/dev/null \
        || die "failed to start the project container."

    # Dual-home onto the broker net AFTER the run (a second --network at run time would
    # replace the default bridge; connecting keeps both + enables embedded DNS for the
    # `cc-broker` alias). host-gateway + default-bridge/LAN reachability are preserved.
    connect_broker_network
}

# ── Bring the container up, or attach to the running one ─────
# The boot lock serialises this section: two terminals launched at the same instant must
# not both try to `docker run` the same container name.
exec 201>"$BOOT_LOCK"
lock_fd -x 201
if container_running; then
    # Redaction is fixed at container creation: the rules are read once, and the
    # container outlives any one terminal. A second terminal must never silently run
    # under stale — or absent — rules, so verify_redaction_attach refuses to attach if
    # the redaction layer is missing or the .ccignore it enforces has since changed.
    # Both modes (sidecar/single) are checked through the same interface.
    verify_redaction_attach
    # Same hazard for the credential broker: a container running without it (or under a
    # since-changed broker config) must not be attached to as if the token were brokered.
    verify_broker_attach
    # The read-only mounts over ~/.claude-shared are fixed at container creation, and the
    # container outlives any one terminal — so a second terminal must never silently get the
    # other mode. Same hazard, same shape of refusal, as the stale-.ccignore check above.
    if [ "$(running_unlocked && echo 1 || echo 0)" != "$UNLOCK_SHARED" ]; then
        if [ "$UNLOCK_SHARED" = 1 ]; then
            die "this project's container is running with the shared config LOCKED, and" \
                "the mounts are fixed at creation. Close all cc sessions for this project," \
                "then run:" \
                "    cc --unlock-shared"
        fi
        # Also the shape of a container created before the shared-config lock existed:
        # it has no read-only mounts either, and must not be attached to as if it had.
        die "this project's container has ~/.claude-shared WRITABLE — it was started with" \
            "--unlock-shared, or it predates the shared-config lock. Refusing to attach" \
            "without the flag: the session would look protected and would not be." \
            "Close all cc sessions for this project and relaunch, or attach with:" \
            "    cc --unlock-shared"
    fi
    wait_for_container_ready # in case its creator died mid-startup
    # Re-assert the pins on the live session file (a concurrent session may have rewritten it
    # wholesale). Do NOT re-assemble here — the running container is bound to these files.
    pin_global_config "$SESSION_BASE/.claude.json"
    echo "🔗 cc: attaching to this project's running container ($CNAME)." >&2
else
    teardown_container # clear anything a crashed session left behind
    # Cold start: rebuild this project's config from canonical ~/.claude, then pin. Only here —
    # never while a container is attached to these bind-mounted files.
    assemble_session_dir
    pin_global_config "$SESSION_BASE/.claude.json"
    start_container
    wait_for_container_ready
    # One resolv.conf watcher for the container's lifetime (see cc-lib.sh). Linux only:
    # on macOS the engine VM already tracks the host resolver, so there is nothing to
    # sync — one info line, and deliberately no desktop notification.
    if is_macos; then
        echo "ℹ️  DNS: handled by the Docker engine VM — follows the host resolver." >&2
    else
        start_resolv_sync
    fi
fi
lock_fd -u 201
exec 201>&-

# ── Sleep guard (inhibits sleep while Claude is producing output) ──
# The container is shared by every terminal on the project, so the guard must be told
# which processes are *ours*: we stamp this terminal's session with a unique marker in
# its environment (below), and the guard samples only pids carrying it. Without this,
# one working session makes every terminal's guard inhibit.
SESSION_TAG="cc-$$-$(date +%s)"

# 200>&- / 201>&-: it must not inherit our lock fds. A guard outliving cc would keep
# holding the project's shared lock and stop the container from ever being torn down.
"$SCRIPT_DIR/sleep-guard.sh" "$CNAME" "$SESSION_TAG" 200>&- 201>&- &
SLEEP_GUARD_PID=$!

# Merge THIS project's changes back into canonical ~/.claude on the last terminal out — the
# only moment the session files are quiescent (the container is already stopped). Under a flock
# on ~/.claude.json.lock, so a concurrent host claude / same-project cc can't interleave a
# write. Subtree-only (.claude.json) + append-only (history) + changed-only (credential): a
# race loses at most this session's edit, never corrupts unrelated data. See
# claude-config-scope.py. Not called for ephemeral sessions (merge-out disabled by design).
merge_out_session() {
    command -v python3 >/dev/null 2>&1 || {
        merge_out_credential
        merge_out_shared_settings
        return 0
    }
    exec 203>"$CLAUDE_JSON.lock"
    if lock_fd -w 30 -x 203; then
        _scope_py merge-out-json "$SESSION_BASE/.claude.json" "$PWD" "$CLAUDE_JSON" \
            || warn "could not merge this project's .claude.json changes back to ~/.claude.json."
        _scope_py merge-history "$SESSION_BASE/history.jsonl" "$PWD" "$CLAUDE_HOME/history.jsonl" \
            || true
        merge_out_credential
        merge_out_shared_settings
        lock_fd -u 203
    else
        # Silence here would discard the whole session's config + ↑ history without a trace.
        warn "timed out waiting for $CLAUDE_JSON.lock — this session's .claude.json and" \
            "↑ history changes were NOT merged back into ~/.claude."
    fi
    exec 203>&-
}

cleanup() {
    kill "$SLEEP_GUARD_PID" 2>/dev/null || true

    if [ "$EPHEMERAL" = 1 ]; then
        teardown_container
        [ -n "${EPH_ROOT:-}" ] && rm -rf "$EPH_ROOT"
    else
        # Are we the last terminal out? Drop our shared lock, then try to take the lock
        # exclusively — which can only succeed if no other cc still holds it. While we
        # hold it, a starting cc blocks on its `flock -s`, so it cannot attach to a
        # container we are about to stop.
        exec 200>&-
        exec 202>"$LOCK_FILE"
        if lock_fd -n -x 202; then
            teardown_container # stop the container first: the session files go quiescent
            merge_out_session  # then fold this project's changes back to canonical
            lock_fd -u 202
        fi
        exec 202>&-
    fi

    # No `tput reset` here (nor before the exec below). A full reset wipes the terminal AND its
    # scrollback: it erased a short command's output (`-p`, `bash -lc`) the instant it exited,
    # and clobbered your scrollback when interactive Claude quit. Claude Code's TUI manages its
    # own screen — exactly as it does run directly on the host — so cc leaves the terminal alone.
    # cc's startup diagnostics and any error message therefore stay on screen and readable.
    :
}
trap cleanup EXIT
# Closing the terminal window sends SIGHUP; `kill` sends SIGTERM. Bash treats both as
# fatal and dies *without* running the EXIT trap — orphaning the sleep-guard (still
# holding a sleep inhibitor) and, if this was the last terminal, stranding the container
# for good. Exit through the normal path instead, so cleanup runs.
trap 'exit 129' HUP
trap 'exit 143' TERM

# ── Run this terminal's session inside the project container ──
# Re-entering through the entrypoint (rather than calling claude directly) reuses its
# "already the target user" branch, which sets HOME and PATH correctly.
# The `cc` alias's leading `claude` token was already peeled off at the top of the script, so
# what's left of "$@" decides the command directly: nothing / a bare flag (`--resume`) → an
# interactive session with the skip-permissions default the box is built around; a leading
# `mcp …` (a claude→cc swap on `claude mcp …`, or a bare `kib mcp …`) is a Claude subcommand,
# not a container binary, so route it through claude too — the secret-bearing `mcp add` forms
# were already intercepted host-side above. Anything else runs verbatim in the box (`kib bash`,
# `kib python app.py`).
if [ $# -eq 0 ]; then
    CMD=(claude --dangerously-skip-permissions)
elif [ "$1" = mcp ] || [[ "$1" == -* ]]; then
    CMD=(claude --dangerously-skip-permissions "$@")
else
    CMD=("$@")
fi

# No screen clear before handing off: Claude Code's TUI sets up its own screen (exactly as it
# does when run on the host), so a reset here would only wipe cc's startup diagnostics
# (broker / FUSE / DNS status) before you could read them — and for `-p` / `bash -lc` runs
# there is no TUI at all, so it would just eat their output.

# Single-container FUSE mode: the container is created with SYS_ADMIN (needed to mount),
# and `docker exec` gives EVERY session the container's full cap set — it does NOT inherit
# PID 1's reduced bounding set. So the drop must happen per session, here: enter as root
# (no --user) and `setpriv` off SYS_ADMIN/SETPCAP (needs CAP_SETPCAP effective, which root
# has) before `gosu` drops to the agent uid. Sidecar mode's container never had SYS_ADMIN,
# so it keeps the plain --user entry. USERFLAG is expanded with the set -u / bash-3.2-safe
# `[@]+` guard because it is empty in single mode.
INCMD=(/usr/local/bin/docker-entrypoint.sh "${CMD[@]}")
if [ "$CC_FUSE_MODE" = single ]; then
    INCMD=(setpriv --bounding-set -sys_admin,-setpcap gosu "$(id -u):$(id -g)" "${INCMD[@]}")
    USERFLAG=()
else
    USERFLAG=(--user "$(id -u):$(id -g)")
fi

# CC_SESSION_TAG marks every process in this terminal's session: claude, its tools and
# its subagents all inherit it across fork/exec, so the sleep guard can scope its /proc
# sample to this session alone. It is set on the *exec*, not the container, so it is
# per-terminal and works against a container created before this existed.
echo >&2 # blank line separating cc's startup diagnostics from the app's own output
docker exec -it \
    ${USERFLAG[@]+"${USERFLAG[@]}"} \
    --workdir "$PWD" \
    -e COLUMNS="$(tput cols 2>/dev/null || echo 120)" \
    -e LINES="$(tput lines 2>/dev/null || echo 40)" \
    -e TERM="${TERM:-xterm-256color}" \
    -e CC_SESSION_TAG="$SESSION_TAG" \
    "$CNAME" "${INCMD[@]}"
