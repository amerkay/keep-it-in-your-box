#!/usr/bin/env bash
# Container lifecycle: identity, locks, create-or-attach, readiness, teardown, and the
# `docker exec` that becomes this terminal's session.
#
# ONE long-lived container per project, every terminal attached by `docker exec`. Claude's own
# concurrent-session arbitration (pid registry + daemon.lock) assumes the sessions share a PID
# namespace and a /tmp — true for two terminals, false for two containers — so giving it one
# container makes it see exactly what it sees on the host and arbitrate for itself.
# (docs/design-notes/container-lifecycle.md)
#
# Reads:  KIB_ROOT IMAGE_NAME UNLOCK_SHARED and the globals host/config.sh sets
# Writes: PROJ_HASH CNAME FUSE_CNAME FUSE_ROOT WL_CNAME WL_ROOT PATTERNS_STATE PASSWD_STATE
#         GROUP_STATE CLIP_STATE
#         CRED_WITNESS LOCK_WITNESS SESSION_CDIR SHARED_CDIR SHARED_ASSET_CDIR
#         LOCK_WITNESS_CPATH TRANSCRIPTS_CPATH BROKER_CNAME BROKER_NET BROKER_DIR BROKER_OUT
#         BROKER_HASH BROKER_ENABLED REDACTION_ARGS ARGS
#         SLEEP_GUARD_PID SESSION_TAG EPH_ROOT
# shellcheck disable=SC2034  # most of the above are consumed in the other host units

# ── Identity ─────────────────────────────────────────────────────
# Stable per project: hash $PWD so same-basename projects do not collide. Paths derive from the
# hash rather than mktemp so ANY kib process can address them, not just the creator.
kib_identity() {
    PROJ_HASH="$(hash8 "$PWD")"
    CNAME="kib-$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-40)-$PROJ_HASH"

    if [ "${KIB_FORCE_NEW_SESSION:-0}" = "1" ]; then
        # Clean slate: its own container and config dirs, so its daemon cannot collide with
        # the project's. Discarded on exit, merge-out disabled.
        EPH_ROOT="$KIB_STATE_ROOT/$SLUG.ephemeral.$$"
        SESSION_BASE="$EPH_ROOT/session"
        SHARED_BASE="$EPH_ROOT/shared"
        CNAME="$CNAME-eph-$$"
        EPHEMERAL=1
        # Its own scratch dirs: sharing the project's would have this session's startup sweep
        # and its exit both tear down the real container's live FUSE mount, unmasking files.
        SCRATCH_SUFFIX=".eph.$$"
    fi

    FUSE_CNAME="${CNAME}-fuse"
    # Platform-sensitive: on macOS the propagation root must live inside the engine VM, not on
    # a virtiofs share of the Mac. host/portable.sh owns that choice.
    FUSE_ROOT="$(fuse_root_path "${PROJ_HASH}${SCRATCH_SUFFIX}")"
    WL_CNAME="${CNAME}-wl"
    WL_ROOT="/tmp/kib-wl.${PROJ_HASH}${SCRATCH_SUFFIX}"
    PATTERNS_STATE="$STATE_DIR/${SLUG}${SCRATCH_SUFFIX}.patterns"
    # The sidecar's /etc/passwd + /etc/group, synthesised so fusermount3 can resolve its own uid
    # without the host's user table crossing the boundary (see _stage_passwd). Host-side state,
    # never inside FUSE_ROOT: on macOS that root is VM-internal and the Mac cannot write to it.
    PASSWD_STATE="$STATE_DIR/${SLUG}${SCRATCH_SUFFIX}.passwd"
    GROUP_STATE="$STATE_DIR/${SLUG}${SCRATCH_SUFFIX}.group"
    CLIP_STATE="$STATE_DIR/${SLUG}${SCRATCH_SUFFIX}.clip"
    # Written at creation when the box got the REAL credential. A host-side FILE, not a shell
    # variable: the last terminal out often merely ATTACHED and never ran stage_credential, so
    # a per-process flag would skip merge_out_credential and leave canonical holding a token
    # the box has already rotated away — which logs the account out.
    CRED_WITNESS="$STATE_DIR/${SLUG}${SCRATCH_SUFFIX}.credfallback"
    # Bound :ro at a flat container path only when locked (the default), and read back off the
    # running container's mounts by `running_unlocked`. A witness that always exists when
    # locked, unlike any individual shared asset — a fresh user may have no plugins at all.
    LOCK_WITNESS="$STATE_DIR/${SLUG}${SCRATCH_SUFFIX}.lockwitness"

    # Always defined so teardown/attach can reference them unconditionally. The network name
    # maps the ephemeral suffix's dots to dashes to stay inside docker's charset.
    BROKER_CNAME="${CNAME}-broker"
    BROKER_NET="kib-broker-net-${PROJ_HASH}$(printf '%s' "$SCRATCH_SUFFIX" | tr '.' '-')"
    BROKER_DIR="$STATE_DIR/${SLUG}${SCRATCH_SUFFIX}.broker"
    BROKER_OUT="$BROKER_DIR/out"
    BROKER_HASH="$BROKER_DIR/hash"
    BROKER_ENABLED=0

    # prepare_redaction fills this with the bind that brings the sidecar's redacted view in over
    # $PWD. The seam is deliberate: redaction.sh stays the only file that knows about /dev/fuse
    # and the caps that go with it — none of which reach this container.
    REDACTION_ARGS=()
}

# Container-side paths. The two dir mounts, then the flat ones for the binds that would
# otherwise nest inside them (see bind_via_link).
#
# The session dir is mounted at the HOST user's OWN ~/.claude path — /home/kay/.claude,
# /Users/veronica/.claude — never a fixed /home/hostuser spelling. Claude records plugin paths
# absolute (installLocation, installPath) and now VALIDATES them against the running config
# dir, so a box whose config dir is spelled differently refuses the state canonical hands it
# ("corrupted installLocation … expected a path inside …"). Same spelling both sides means
# there is nothing to translate, and no per-field rewrite to keep in step with upstream.
SESSION_CDIR="${HOME%/}/.claude"
# …except for a project INSIDE canonical's own store, where that would nest the $PWD bind in
# this one and abort the whole `docker run` on Docker Desktop (macos.md). Rare; step aside.
case "$PWD/" in "$SESSION_CDIR"/*) SESSION_CDIR=/home/hostuser/.claude-session ;; esac
SHARED_CDIR=/home/hostuser/.claude-shared
SHARED_ASSET_CDIR=/run/kib/shared
LOCK_WITNESS_CPATH=/run/kib/shared/.kib-shared-locked
TRANSCRIPTS_CPATH=/run/kib/transcripts
PLACEHOLDER_CRED_CPATH=/run/kib/placeholder-cred

container_running() { [ -n "$(docker ps -q -f "name=^${CNAME}$" 2>/dev/null)" ]; }
broker_running() { [ -n "$(docker ps -q -f "name=^${BROKER_CNAME}$" 2>/dev/null)" ]; }

# Was the running container created with --unlock-shared? Read it off the mounts, which are
# the ground truth — no state file to go stale. A container from a kib that mounted the witness
# elsewhere reads as unlocked, which fails closed: kib_bring_up refuses to attach.
running_unlocked() {
    ! docker inspect -f '{{range .Mounts}}{{.Destination}}{{"\n"}}{{end}}' "$CNAME" 2>/dev/null \
        | grep -qx "$LOCK_WITNESS_CPATH"
}

# ── Nested binds are refused — mount flat, link into place ───────────────────
# A bind whose destination sits INSIDE another bind aborts the whole `docker run` on Docker
# Desktop: runc resolves the mountpoint through the parent, lands on the engine VM's
# /run/host_virtiofs view of it, finds a path outside the container rootfs and errors. The
# check runs after resolution either way, so pre-creating the mountpoint does not help.
# Mount at a flat path instead and leave a symlink to it in the parent bind's HOST-side dir:
# dangling on the host (kib scratch — nothing reads it there), resolved in the container.
bind_via_link() { # <host src> <flat container dest> <link path in the parent's host dir> [:ro]
    local src="$1" dest="$2" link="$3" opts="${4:-}"
    # An older kib left docker's own mountpoint here, ROOT-owned; unlinking it needs only the
    # parent's write bit, which we have.
    if [ ! -L "$link" ]; then
        rm -rf "$link" 2>/dev/null || true
    fi
    mkdir -p "$(dirname "$link")" 2>/dev/null || true
    ln -sfn "$dest" "$link" 2>/dev/null \
        || warn "could not link $link -> $dest; it will be missing inside the box."
    ARGS+=(-v "$src:$dest$opts")
}

# `docker run -d` returns as soon as PID 1 exists, but the entrypoint still has real work to
# do as root — useradd, the shared-asset symlink farm, chown of the session dir — before it
# execs `gosu … sleep infinity`. An immediate `docker exec` would land mid-setup: no home dir
# yet, no symlinks, a chown walking the tree under us.
#
# Readiness is therefore a process whose command line is *exactly* `sleep infinity`, which
# only exists once the entrypoint has exec'd. The exactness is load-bearing: while the
# entrypoint is still working its own argv is `/bin/sh …/docker-entrypoint.sh sleep infinity`,
# and PID 1 (docker-init) carries `… -- …docker-entrypoint.sh sleep infinity` forever — a
# substring match would call a half-set-up container ready.
#
# Docker Desktop refuses the ps args, so the `-o args` form fails on every poll and the whole
# wait pays two engine round-trips per iteration instead of one. Latch the refusal.
_TOP_ARGS_OK=1
container_ready() {
    local args
    if [ "$_TOP_ARGS_OK" = 1 ] && args="$(docker top "$CNAME" -o args 2>/dev/null)"; then
        :
    else
        _TOP_ARGS_OK=0
        args="$(docker top "$CNAME" 2>/dev/null \
            | awk 'NR>1 { $1=$2=$3=$4=$5=$6=$7=""; sub(/^ +/,""); print }')"
    fi
    printf '%s\n' "$args" | grep -qx 'sleep infinity'
}

# Ready, or gone — either way there is no point waiting longer. The caller decides which.
_container_ready_or_gone() { container_ready || ! container_running; }

wait_for_container_ready() {
    wait_until 120 0.5 _container_ready_or_gone # ≤60s; a cold entrypoint is ~1s
    container_ready && return 0
    if container_running; then
        echo "❌ kib: the project container never finished starting up (60s)." >&2
    else
        echo "❌ kib: the project container exited during startup. Logs:" >&2
    fi
    docker logs "$CNAME" 2>&1 | tail -20 | sed 's/^/   /' >&2 || true
    # Leave nothing half-started behind: a running-but-never-ready container would make
    # every later kib attach to it and hit this same timeout.
    teardown_container
    exit 1
}

teardown_container() {
    docker stop -t 5 "$CNAME" >/dev/null 2>&1 || true
    # Explicit, because the container is NOT created with --rm: a container that dies during
    # startup has to survive long enough for `docker logs` to report why. With --rm the engine
    # reaped it first and the only diagnostic was "No such container". Every cold start calls
    # this before `docker run`, so a stopped leftover never blocks the name.
    docker rm -f "$CNAME" >/dev/null 2>&1 || true

    # After the container, so its :rslave view of the mount is gone before we unmount it.
    teardown_redaction

    # Each no-ops on the platform that does not use it.
    stop_wayland_guard
    stop_clipboard_bridge

    # After the main container is stopped, so its network has no endpoint and `network rm`
    # succeeds. (The resolv.conf watcher needs nothing: it died with the container.)
    stop_broker
}

start_container() {
    # Stages the rule file and pushes the mount flags onto REDACTION_ARGS below.
    prepare_redaction
    # Must precede the mounts below, which bind the proxy socket / spool dir.
    if is_macos; then
        start_clipboard_bridge
    else
        start_wayland_guard
    fi

    # Must precede the ARGS below, which add its base-URL env and placeholder shadow.
    start_broker
    # Only when the broker is not shadowing a synthetic credential: copy the real one into the
    # shared-assembly DIR (never a single-file bind — rename footgun). Folded back on exit.
    stage_credential

    # --init: PID 1 is `sleep infinity`, which would never reap the zombies left behind by
    # exec'd sessions. Docker's init does.
    ARGS=(
        -d --init
        --name "$CNAME"

        # This project's private state: daemon, sessions, jobs, and the three files assembled
        # from canonical (.claude.json, history.jsonl, CLAUDE.md). No other project mounts it.
        -v "$SESSION_BASE:$SESSION_CDIR"

        # Shared-assembly dir: a real host directory holding the credential (synthetic shadow,
        # or the real one copied in) and one symlink per shared asset (below). A real dir, so
        # Claude's atomic credential rename works.
        -v "$SHARED_BASE:$SHARED_CDIR"

        # config (+ .claude.json) resolve to the per-project session dir; the credential store
        # to the shared-assembly dir.
        -e CLAUDE_CONFIG_DIR="$SESSION_CDIR"
        -e CLAUDE_SECURESTORAGE_CONFIG_DIR="$SHARED_CDIR"

        # Host UID/GID/HOME for runtime user creation. `docker exec` inherits these from the
        # container config, so attached sessions get them too.
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

        # The image still ships setuid binaries (su, mount, passwd, fusermount3). Defence in
        # depth — the session's caps are already empty, so this closes a route, not a hole.
        --security-opt no-new-privileges

        # NOT here, and this is the point of the sidecar topology: no --cap-add=SYS_ADMIN, no
        # --cap-add=SETPCAP, no --device /dev/fuse, and no apparmor override. This container is
        # capless at CREATION — a kernel fact — rather than capless once a shell has dropped
        # things, and it keeps docker-default's `deny mount,`.

        # Bridge network + Claude's own domain allowlist. --add-host so a dev server on the
        # host stays reachable.
        --add-host=host.docker.internal:host-gateway

        -e DISABLE_TELEMETRY=1
        -e DISABLE_ERROR_REPORTING=1
    )

    # The project comes in here and ONLY here: prepare_redaction binds the sidecar's redacted
    # view over $PWD (:rslave). There is no second, unredacted path to it.
    ARGS+=(${REDACTION_ARGS[@]+"${REDACTION_ARGS[@]}"})

    # Clipboard mounts: the mediated Wayland socket on Linux (reads pass, writes refused), or
    # the pbpaste bridge spool on macOS. Both no-op if their sidecar/bridge didn't come up.
    if is_macos; then
        add_clipboard_bridge_args
    else
        add_wayland_args
    fi

    # Follow the host's live DNS. Linux only — on macOS the engine VM already tracks the host
    # resolver, so there is nothing to sync.
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

    # .git/hooks is NOT bound read-only here: $PWD is the FUSE view, and a bind over a subpath
    # of it would shadow the very layer doing the enforcing. The guard covers it — and covers
    # what the bind never could: nested repos, submodules, and repos created mid-session.

    # This project's transcripts, shared host<->box so --resume lists the same sessions on
    # both sides. Would nest inside the session mount, hence the link. The sidecar binds the
    # view at the project's host path, so Claude — which keys by its RESOLVED cwd — uses the
    # same $SLUG canonical does, and source and link agree.
    #
    # Drop OUR links first, exactly as the shared-asset farm does. $SESSION_BASE outlives the
    # container, so a link keyed by a name we no longer use is never reaped, and it reads to an
    # auditor as another project's transcripts. Only links INTO $TRANSCRIPTS_CPATH are ours; a
    # real dir is Claude's.
    for _t in "$SESSION_BASE"/projects/*; do
        [ -L "$_t" ] || continue
        [ "$(readlink "$_t" 2>/dev/null)" = "$TRANSCRIPTS_CPATH" ] || continue
        rm -f "$_t" 2>/dev/null || true
    done
    unset _t

    # A REAL directory at either slug is a previous in-box session's transcripts that nothing
    # ever tied to canonical. bind_via_link `rm -rf`s a non-symlink, so fold them out first or
    # the upgrade destroys every prior in-box session and `--resume` stops listing them. Two
    # spellings: $SLUG, and the container-home key the in-container-mount window used
    # (kib_legacy_box_pwd) — drop that one once no session dir predates the sidecar restore.
    _bt_ok=1
    for _bt in "$SESSION_BASE/projects/$SLUG" "$SESSION_BASE/projects/$LEGACY_BOX_SLUG"; do
        # The two spellings coincide for a project outside $HOME — fold once, warn once.
        [ "$_bt" = "$SESSION_BASE/projects/$SLUG" ] || [ "$SLUG" != "$LEGACY_BOX_SLUG" ] || continue
        { [ -d "$_bt" ] && [ ! -L "$_bt" ]; } || continue
        _bt_this=0
        if [ "$EPHEMERAL" != 1 ] && mkdir -p "$CLAUDE_HOME/projects/$SLUG" 2>/dev/null; then
            for _f in "$_bt"/* "$_bt"/.[!.]*; do
                [ -e "$_f" ] || continue
                # -n: canonical wins a name clash. It is the copy both sides already share, and
                # a transcript is append-only, so the older duplicate is never the fuller one.
                mv -n "$_f" "$CLAUDE_HOME/projects/$SLUG/" 2>/dev/null || true
            done
            # Only an EMPTY dir may go: anything left means a move failed, and keeping the
            # data unlinked beats relinking over it.
            rmdir "$_bt" 2>/dev/null && _bt_this=1
        fi
        if [ "$_bt_this" != 1 ]; then
            # Only the CURRENT slug blocks the link below; a stranded legacy dir is inert.
            [ "$_bt" = "$SESSION_BASE/projects/$SLUG" ] && _bt_ok=0
            # Not a failure for an ephemeral session: it persists nothing to canonical BY
            # DESIGN, so the fold is skipped rather than attempted.
            [ "$EPHEMERAL" = 1 ] || warn "could not fold this box's old transcripts at $_bt" \
                "into $CLAUDE_HOME/projects/$SLUG — leaving them in place, so --resume will" \
                "not show them on the host. Nothing was deleted."
        fi
    done

    # Skipped for an ephemeral session — it must persist nothing to canonical. A link left
    # DANGLING would be worse than none: Claude cannot create its transcript dir over one,
    # which is why the sweep above drops ours whenever canonical has lost the directory.
    if [ "$_bt_ok" = 1 ] && [ "$EPHEMERAL" != 1 ] && [ -d "$CLAUDE_HOME/projects/$SLUG" ]; then
        bind_via_link "$CLAUDE_HOME/projects/$SLUG" "$TRANSCRIPTS_CPATH" \
            "$SESSION_BASE/projects/$SLUG"
    fi
    unset _bt _bt_ok _bt_this _f

    # settings.json / keybindings.json are deliberately NOT bound: stage_shared_settings puts
    # writable COPIES in $SHARED_BASE (already served by the dir mount above) and vets them
    # before they re-enter canonical. Binding canonical rw here — as this once did — let a
    # sandboxed session write the settings.json a HOST `claude` loads.

    # These auto-load in EVERY project's next session and the host claude, so a write from one
    # sandboxed repo is a cross-project pivot (audit H6) — READ-ONLY by default. Nothing is
    # lost: the entrypoint farms a per-project dir, so in-session installs still work, they
    # just land per-project. --unlock-shared makes them writable into canonical ~/.claude.
    local _ro=":ro"
    [ "$UNLOCK_SHARED" = 1 ] && _ro=""
    local _entry
    # `if`, not `[ … ] && ARGS+=`: a false test on the final iteration would make the whole
    # loop exit 1, which under `set -e` kills kib before the container starts.
    for _entry in plugins skills agents commands hooks; do
        if [ -e "$CLAUDE_HOME/$_entry" ]; then
            bind_via_link "$CLAUDE_HOME/$_entry" "$SHARED_ASSET_CDIR/$_entry" \
                "$SHARED_BASE/$_entry" "$_ro"
        elif [ -L "$SHARED_BASE/$_entry" ]; then
            # Gone from canonical since the last launch — drop our link rather than dangle.
            rm -f "$SHARED_BASE/$_entry" 2>/dev/null || true
        fi
    done

    # Lock witness: a read-only bind that exists ONLY when locked, so running_unlocked can
    # read the lock state off the mounts even for a user with no shared assets to probe.
    if [ "$UNLOCK_SHARED" = 0 ]; then
        printf 'locked\n' >"$LOCK_WITNESS" 2>/dev/null || true
        if [ -f "$LOCK_WITNESS" ]; then
            ARGS+=(-v "$LOCK_WITNESS:$LOCK_WITNESS_CPATH:ro")
        fi
    fi

    # Broker wiring: -e ANTHROPIC_BASE_URL + the placeholder credential that SHADOWS the real
    # .credentials.json (copied into the shared-assembly dir, not mounted). Must follow
    # stage_credential, which clears that path. No-op unless the broker came up.
    add_broker_env_args

    # The container just idles; the real work runs in `docker exec` sessions, so it survives
    # any one terminal closing.
    docker run "${ARGS[@]}" "$IMAGE_NAME" sleep infinity >/dev/null \
        || die "failed to start the project container."

    # Dual-home onto the broker net AFTER the run (a second --network at run time would
    # replace the default bridge; connecting keeps both + enables embedded DNS for the
    # broker alias). host-gateway + default-bridge/LAN reachability are preserved.
    connect_broker_network
}

# ── Session preparation ──────────────────────────────────────────
# Config dirs, the project lock, and the shared-config banner. Their CONTENTS are assembled
# fresh from canonical on the cold-start path only, never while a container is attached.
kib_prepare_session() {
    mkdir -p "$LOCK_DIR" && chmod 700 "$LOCK_DIR"
    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
    validate_shared_settings

    if [ "$UNLOCK_SHARED" = 1 ]; then
        echo "⚠️  --unlock-shared: your ~/.claude plugins/skills/agents/commands/hooks are WRITABLE" >&2
        echo "   this session — an install lands in ~/.claude, shared with every project + host claude." >&2
    else
        echo "🔒 shared config: read-only (installs land per-project; kib unlock-shared to share)" >&2
    fi

    mkdir -p "$SESSION_BASE" && chmod 700 "$SESSION_BASE"
    mkdir -p "$SHARED_BASE" && chmod 700 "$SHARED_BASE" # holds the real credential when the broker is off
    if [ "$EPHEMERAL" = 1 ]; then
        # Reap it even if we bail out below (e.g. the broker fails): the real cleanup() trap
        # is not installed until just before the container starts.
        trap 'rm -rf "$EPH_ROOT"' EXIT
        echo "⚠️  KIB_FORCE_NEW_SESSION=1 — ephemeral session; no history, discarded on exit." >&2
    else
        # SHARED lock held for this terminal's lifetime — a reference count on the container,
        # not a mutex. It blocks only while a departing session holds it EXCLUSIVELY to tear
        # the container down, so we can never attach to a dying one. Never unlinked.
        exec 200>"$LOCK_FILE"
        lock_fd -w 60 -s 200 || die "timed out waiting for the project lock ($LOCK_FILE)."
    fi
}

# ── Create or attach ─────────────────────────────────────────────
# The boot lock serialises this section: two terminals launched at the same instant must not
# both try to `docker run` the same container name.
kib_bring_up() {
    exec 201>"$BOOT_LOCK"
    lock_fd -x 201
    if container_running; then
        # Redaction rules are read once at creation and the container outlives any terminal,
        # so a second terminal must never silently run under stale — or absent — rules.
        verify_redaction_attach
        # Same hazard: never attach as if the token were brokered when it is not.
        verify_broker_attach
        # And for the read-only mounts over the container's shared-assets dir, fixed at
        # creation too.
        if [ "$(running_unlocked && echo 1 || echo 0)" != "$UNLOCK_SHARED" ]; then
            if [ "$UNLOCK_SHARED" = 1 ]; then
                die "this project's container is running with the shared config LOCKED, and" \
                    "the mounts are fixed at creation. Close all kib sessions for this" \
                    "project, then run:" \
                    "    kib unlock-shared"
            fi
            # Also the shape of a container created before the shared-config lock existed: it
            # has no read-only mounts either, and must not be attached to as if it had.
            die "this project's container has the shared assets (skills, agents, plugins," \
                "commands, hooks) WRITABLE — it was started with unlock-shared, or it" \
                "predates the shared-config lock. Refusing to attach" \
                "without the flag: the session would look protected and would not be." \
                "Close all kib sessions for this project and relaunch, or attach with:" \
                "    kib unlock-shared"
        fi
        wait_for_container_ready # in case its creator died mid-startup
        # Re-pin the live session file (a concurrent session may have rewritten it wholesale).
        # Do NOT re-assemble — the running container is bound to these files.
        pin_global_config "$SESSION_BASE/.claude.json"
        echo "🔗 kib: attaching to this project's running container ($CNAME)." >&2
    else
        teardown_container # clear anything a crashed session left behind
        # Cold start only: refuse to launch into a repo whose git config the host would
        # execute. Nothing is running yet, so exiting here strands nothing.
        kib_audit_gate launch
        # Rebuild this project's config from canonical ~/.claude, then pin. Only here — never
        # while a container is attached to these bind-mounted files.
        assemble_session_dir
        pin_global_config "$SESSION_BASE/.claude.json"
        start_container
        wait_for_container_ready
        # Linux only: macOS's engine VM already tracks the host resolver. One info line, and
        # deliberately no desktop notification.
        if is_macos; then
            echo "ℹ️  DNS: handled by the Docker engine VM — follows the host resolver." >&2
        else
            start_resolv_sync
        fi
    fi
    lock_fd -u 201
    exec 201>&-
}

# ── Exit path ────────────────────────────────────────────────────
kib_cleanup() {
    kill "$SLEEP_GUARD_PID" 2>/dev/null || true

    if [ "$EPHEMERAL" = 1 ]; then
        teardown_container
        [ -n "${EPH_ROOT:-}" ] && rm -rf "$EPH_ROOT"
    else
        # Last terminal out? Drop the shared lock, then try to take it exclusively — which
        # only succeeds if no other kib holds it. While we do, a starting kib blocks on its
        # shared acquire, so it cannot attach to a container we are about to stop.
        exec 200>&-
        exec 202>"$LOCK_FILE"
        if lock_fd -n -x 202; then
            teardown_container # stop the container first: the session files go quiescent
            merge_out_session  # then fold this project's changes back to canonical
            # …and say so if the repo grew something the host would run. `|| true` because
            # report mode returns the finding class, and this is the EXIT trap: a non-zero
            # here would overwrite the session's own exit status.
            kib_audit_gate teardown || true
            lock_fd -u 202
        fi
        exec 202>&-
    fi

    # NO `tput reset` here or before the exec below: it wipes the terminal AND its scrollback,
    # erasing a short command's output the instant it exits. Claude's TUI manages its own
    # screen, as it does on the host, so kib leaves the terminal alone. Regression-guarded.
    :
}

# ── Run this terminal's session inside the project container ─────
# Re-entering through the entrypoint (rather than calling claude directly) reuses its
# "already the target user" branch, which sets HOME and PATH correctly.
kib_run_session() {
    # Stamps this terminal's processes so the sleep guard samples only pids that are ours —
    # without it, one working session makes every terminal's guard inhibit.
    SESSION_TAG="kib-$$-$(date +%s)"

    # 200>&- / 201>&-: the guard must not inherit our lock fds. A guard outliving kib would
    # keep holding the project's shared lock and stop the container from ever being torn down.
    "$KIB_ROOT/host/sleep-guard.sh" "$CNAME" "$SESSION_TAG" 200>&- 201>&- &
    SLEEP_GUARD_PID=$!

    trap kib_cleanup EXIT
    # Bash dies on SIGHUP (window closed) and SIGTERM *without* running the EXIT trap, which
    # orphans the sleep guard still holding an inhibitor and strands the container if this was
    # the last terminal. Route both through a normal exit so cleanup runs.
    trap 'exit 129' HUP
    trap 'exit 143' TERM

    # No `setpriv` here. The container never had SYS_ADMIN or SETPCAP to drop — the sidecar
    # holds the mount — so `docker exec` handing a session the container's full cap set is
    # harmless: that set is the entrypoint's own add-backs (0xcb:
    # CHOWN/DAC_OVERRIDE/FOWNER/SETGID/SETUID), inert under no-new-privileges at a non-root uid.
    # security-test.sh asserts CapEff=0 and that SYS_ADMIN is absent from the bounding set.
    local -a incmd=(
        gosu "$(id -u):$(id -g)"
        /usr/local/bin/docker-entrypoint.sh "$@"
    )

    # Set on the *exec*, not the container, so the tag is per-terminal and works against a
    # container created before this existed. Claude's tools and subagents inherit it.
    echo >&2 # blank line separating kib's startup diagnostics from the app's own output
    docker exec -it \
        --workdir "$PWD" \
        -e COLUMNS="$(tput cols 2>/dev/null || echo 120)" \
        -e LINES="$(tput lines 2>/dev/null || echo 40)" \
        -e TERM="${TERM:-xterm-256color}" \
        -e KIB_SESSION_TAG="$SESSION_TAG" \
        "$CNAME" "${incmd[@]}"
}
