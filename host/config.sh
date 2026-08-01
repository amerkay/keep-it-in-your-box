#!/usr/bin/env bash
# Per-project session assembly from the canonical ~/.claude, and the way back out.
#
# Canonical ~/.claude and ~/.claude.json stay STOCK-UNTOUCHED — same login, transcripts and
# history a plain host `claude` sees, so host⇄box switching is seamless. Isolation comes from
# assembling each container's config from that store per launch and merging this project's
# slice back on exit. The JSON/JSONL surgery is kib.host.config_scope; this file is placement
# and locking. (docs/design-notes/container-lifecycle.md)
#
# Reads:  KIB_ROOT KIB_STATE_ROOT PWD
# Writes: CLAUDE_HOME CLAUDE_JSON SLUG SESSION_BASE SHARED_BASE LOCK_DIR
#         LOCK_FILE BOOT_LOCK STATE_DIR EPHEMERAL SCRATCH_SUFFIX
#         KIB_ASSETS_OPEN KIB_ASSETS_PROMPT
# shellcheck disable=SC2034  # the globals above are read in bin/kib and the other units

_scope() { kib_py host.config_scope "$@"; }

# ── Identity and paths ───────────────────────────────────────────
# Called once, before anything touches a file. Pure: no mkdir, no docker.
#
# One key, host and box: Claude keys projects/, .claude.json and history.jsonl by its RESOLVED
# cwd, and the sidecar binds the redacted view at the project's HOST path — so that resolves to
# $PWD and canonical and the session share a slug. Remove the mismatch, never translate it.
kib_resolve_paths() {
    CLAUDE_HOME="$HOME/.claude"
    CLAUDE_JSON="$HOME/.claude.json"
    SLUG="$(printf '%s' "$PWD" | sed 's/[^a-zA-Z0-9]/-/g')"
    SESSION_BASE="$KIB_STATE_ROOT/$SLUG/session"
    SHARED_BASE="$KIB_STATE_ROOT/$SLUG/shared"
    EPHEMERAL=0
    SCRATCH_SUFFIX=""

    # OUTSIDE the bind-mounted dirs: those are rw in the container, so a sandboxed Claude could
    # unlink a lock — and unlinking one another kib holds flocked lets the next lock a FRESH
    # inode, giving two "last terminals out" both tearing down under a live session.
    LOCK_DIR="$KIB_STATE_ROOT/.locks"
    LOCK_FILE="$LOCK_DIR/$SLUG.lock"
    BOOT_LOCK="$LOCK_DIR/$SLUG.boot.lock"

    # Host-only state (the staged redaction patterns, the macOS clipboard spool, the witnesses).
    # Out of the bind-mounted dirs for the same reason as the locks — none of it is the
    # sandbox's to edit.
    STATE_DIR="$KIB_STATE_ROOT/.state"
}

# Canonical ~/.claude must exist (or be freshly skeletoned). Runs before any assembly.
ensure_claude_home() {
    [ -d "$CLAUDE_HOME" ] && return 0
    mkdir -p "$CLAUDE_HOME/projects" && chmod 700 "$CLAUDE_HOME"
    echo "🆕 kib: no ~/.claude yet — created a fresh skeleton (first login populates it)." >&2
}

# ── Sandbox policy → managed-policy CLAUDE.md ────────────────────
# Bound :ro at Claude's Linux managed-policy path (the box is Linux whatever the host is), so
# it loads in EVERY in-box session ahead of user and project memory, cannot be dropped by a
# repo's claudeMdExcludes, and is not writable by the session — unlike the config dir, where
# it used to be concatenated into CLAUDE.md. The image pre-creates the directory; the content
# is bound, not baked, so editing the policy needs a relaunch and not a rebuild.
KIB_POLICY_FILE_HOST="$KIB_ROOT/guest/policy/etc-CLAUDE.md"
KIB_POLICY_CPATH="/etc/claude-code/CLAUDE.md"

# The sleep guard's hooks, in the SAME managed-policy directory and for the same reason: it is
# the one settings scope the session cannot edit (bound :ro) and the one that never folds back
# out to canonical. `hooks[].command` in ~/.claude/settings.json is host code execution and
# validate_shared_settings refuses it — correctly, since the box can write that file and it
# loads in every project AND a host `claude`. Managed settings are outside that path entirely:
# highest precedence, unwritable from in here, and never merged anywhere.
KIB_SLEEP_HOOK_FILE_HOST="$KIB_ROOT/guest/policy/sleep-hook.py"
KIB_SLEEP_HOOK_CPATH="/etc/claude-code/sleep-hook.py"
KIB_MANAGED_FILE_HOST="$KIB_ROOT/guest/policy/managed-settings.json"
KIB_MANAGED_CPATH="/etc/claude-code/managed-settings.json"

add_policy_args() {
    # Fail closed: a box whose agent never sees the sandbox rules is the one case where
    # launching anyway is worse than not launching.
    [ -f "$KIB_POLICY_FILE_HOST" ] \
        || die "missing $KIB_POLICY_FILE_HOST — refusing to launch a box with no sandbox policy."
    ARGS+=(-v "$KIB_POLICY_FILE_HOST:$KIB_POLICY_CPATH:ro")

    # WARN, not die, unlike the policy above: the session itself is fine without these, and
    # nothing is left unguarded — only the machine's sleep behaviour degrades. The guard has no
    # fallback by design, so be explicit about what that costs rather than implying it copes.
    if [ -f "$KIB_SLEEP_HOOK_FILE_HOST" ] && [ -f "$KIB_MANAGED_FILE_HOST" ]; then
        ARGS+=(-v "$KIB_SLEEP_HOOK_FILE_HOST:$KIB_SLEEP_HOOK_CPATH:ro")
        ARGS+=(-v "$KIB_MANAGED_FILE_HOST:$KIB_MANAGED_CPATH:ro")
    else
        warn "missing the sleep-guard hook files under $KIB_ROOT/guest/policy —" \
            "this session publishes no activity state, so the machine may go to sleep while" \
            "Claude is still working."
    fi
}

# Attach-path check: the mount is fixed at creation, so a container an older kib left running
# has no policy in it. WARN, not die — unlike redaction or the broker, nothing is unguarded
# here (the FUSE view and the read-only mounts still hold); the session just runs without the
# instructions, which is degraded, not open.
verify_policy_attach() {
    docker exec "$CNAME" test -s "$KIB_POLICY_CPATH" 2>/dev/null && return 0
    warn "this project's container is running without the sandbox policy at" \
        "$KIB_POLICY_CPATH, so this session will not see the sandbox rules." \
        "The guards themselves still hold. Close all kib sessions for this project" \
        "and relaunch to restore it."
}

# ── User memory ──────────────────────────────────────────────────
# The user's canonical CLAUDE.md, copied in verbatim each launch (the policy is no longer
# prepended — see above). Copied rather than bound: an in-box edit must not reach canonical,
# which a host `claude` also loads, so `#` memory written in here is transient by design.
place_user_claude_md() {
    local md="$SESSION_BASE/CLAUDE.md"
    if [ -f "$CLAUDE_HOME/CLAUDE.md" ]; then
        cp "$CLAUDE_HOME/CLAUDE.md" "$md.kib.tmp" && mv "$md.kib.tmp" "$md"
    else
        rm -f "$md" # absent on a fresh install, or deleted since the last launch
    fi
}

# ── Shared settings.json: refuse host-reaching keys ──────────────
# settings.json is staged into EVERY project's box and folded back out, so one poisoned session
# reaches every other project's next session AND the host claude (audit H5). It has to stay
# writable — /config and theme changes are normal — so the control runs here instead, on the
# host, before any container reads it, on both the create and attach paths. Catching it at
# launch catches it before the NEXT session loads it, which is the propagation step. Broken
# JSON warns (Claude ignores an unparseable file anyway); an unreadable one fails closed.
validate_shared_settings() {
    local f="$CLAUDE_HOME/settings.json"
    [ -e "$f" ] || return 0
    have_python || {
        warn "python3 not found on the host — cannot validate the shared settings.json."
        return 0
    }
    local bad rc=0
    bad="$(kib_py host.settings_scan scan "$f")" || rc=$?

    # shellcheck disable=SC2088  # the tildes below are prose for the user, not paths
    case "$rc" in
        0) return 0 ;;
        3)
            warn "~/.claude/settings.json is not valid JSON — skipping validation." \
                "Claude ignores an unparseable settings file, so this is not fatal."
            return 0
            ;;
        4) die "cannot read ~/.claude/settings.json. Refusing to launch:" \
            "an unreadable settings file cannot be checked for keys that" \
            "run commands on your behalf." ;;
    esac

    printf '\n' >&2
    # shellcheck disable=SC2088  # prose for the user, not a path we open
    die "~/.claude/settings.json contains a key that runs a command or" \
        "redirects your credentials:" \
        "" \
        "$(printf '%s\n' "$bad" | sed 's/^/    /')" \
        "" \
        "A sandboxed session can write this file, and it loads in EVERY project (and the" \
        "host claude). Remove the key, then relaunch:" \
        "    \$EDITOR ~/.claude/settings.json"
}

# ── Shared assets: one open tier ─────────────────────────────────
# All five auto-load in every project and in a host `claude`, and all five mount WRITABLE and
# symlinked straight at canonical — so an install or an authored skill is shared exactly as it is
# on the host. plugins/ and hooks/ used to mount :ro (unlocked by a verb, farmed per project);
# that lock is gone and what these trees AUTO-RUN is detected instead. The trade is written up in
# full — including the cross-project residual it accepts — in `redaction-config-guard.md`.
KIB_ASSETS_OPEN="skills agents commands plugins hooks"
# The prompt-text subset, for the cheap "changed since last launch" report — see why below.
KIB_ASSETS_PROMPT="skills agents commands"

# ── Shared asset trees: report what a host `claude` would AUTO-RUN ───
# These trees are plain bind mounts with nothing to interpose on, so this is detection, not
# prevention — and what it detects is host RCE only in the one case where the host has its own
# unsandboxed `claude` to load them. So the probe gates the whole check: no host claude, no walk.
# `kib audit` calls this with force=1, for a user who wants to look anyway.
#
# Teardown, not launch: the finding is almost always what THIS session just wrote, and naming it
# while the user still remembers writing it beats naming it at the next launch. Change-scoped
# against a stamp, so an installed plugin's own hooks are reported once and not every exit.
validate_shared_assets() {
    local force="${1:-0}" _t bad hostcc stamp="$STATE_DIR/assets.scanned"
    # The host-claude gate FIRST: with no unsandboxed reader there is nothing to say, so a host
    # without python3 must not be told at every teardown that a check it would have skipped was
    # skipped. `host_claude_path` needs no python of its own.
    hostcc="$(host_claude_path)"
    if [ -z "$hostcc" ] && [ "$force" != 1 ]; then return 0; fi
    have_python || {
        warn "python3 not found on the host — cannot vet the shared ~/.claude asset trees."
        return 0
    }
    for _t in $KIB_ASSETS_OPEN; do
        [ -d "$CLAUDE_HOME/$_t" ] || continue
        # force=1 is `kib audit` — a look the user just asked for, so it scans WHOLE. Handing it
        # the stamp would answer "nothing changed since your last launch" to the question "what is
        # in my shared trees", which is the one question it exists to answer.
        if [ "$force" = 1 ]; then
            bad="$(kib_py host.asset_scan scan "$CLAUDE_HOME/$_t")" && continue
        else
            bad="$(kib_py host.asset_scan scan-new "$CLAUDE_HOME/$_t" "$stamp")" && continue
        fi
        # shellcheck disable=SC2088  # the tilde is prose for the user, not a path we open
        warn "~/.claude/$_t gained something that RUNS a command by itself, or links out of" \
            "the tree:" \
            "$(printf '%s\n' "$bad" | sed 's/^/    /')" \
            "It loads in EVERY project's next session — and in ${hostcc:-a host claude}, which" \
            "is NOT sandboxed, so that command runs as you on this machine. Review it, or" \
            "remove it. kib does not protect ~/.claude from what a session writes there."
        # Teardown only, like kib_audit_gate's: `kib audit` is something the user just typed and
        # is watching, so a popup on top of the report they asked for is only noise.
        [ "$force" = 1 ] || notify_desktop critical \
            "kib · shared ~/.claude/$_t now auto-runs a command" \
            "Something in ~/.claude/$_t runs a command or links out of the tree."
    done
    # AFTER the scan, and its OWN stamp — never report_shared_asset_writes'. That one is refreshed
    # by every launch of every project (the trees are global), so a second terminal opening
    # mid-session would move the reference point past what this session had already written into
    # plugins/ or hooks/ — trees that report has never covered. `kib audit` is a look, not a
    # checkpoint, so it does not move the mark either.
    if [ "$force" != 1 ]; then
        : >"$stamp" 2>/dev/null || true
    fi
    # Explicit: a loop whose last iteration ends on a false test returns 1, and under `set -e`
    # that aborts the launch with no message at all. Never end a launch-path function on a test.
    return 0
}

# ── The one thing the box cannot protect you from ────────────────
# Every ~/.claude asset tree is writable from a session, and all five auto-load. Inside another
# box that is in-container execution — the same class as prompt injection, which the design
# already accepts. In a NATIVE `claude` it is code running as you, outside any sandbox, which is
# a different thing entirely. So the notice exists only when that reader does: silent otherwise,
# because a warning about a program you have not installed is noise that trains you to skip the
# rest. Removing the host install is the only thing that actually closes it.
warn_host_claude() {
    local cc
    # Prime the memo in THIS shell: every caller reads it through `$(…)`, and a subshell's
    # assignment dies with it — so without one direct call each site re-walks PATH.
    host_claude_path >/dev/null
    cc="$(host_claude_path)"
    [ -n "$cc" ] || return 0
    echo "⚠️  a native claude is installed at $cc — it is NOT sandboxed, and it loads the same" >&2
    echo "   ~/.claude skills/agents/commands/plugins/hooks a session in here can write." >&2
    echo "   kib reports what those trees auto-run; only uninstalling it closes the path." >&2
    return 0
}

# What a sandboxed session (or anything else) wrote into the PROMPT trees since the last launch.
# Reported HERE, not only mid-session, because a write while no session ran — another project's
# box, a host process — still loads in this one. The stamp is refreshed after reporting, and
# validate_shared_assets scopes its teardown scan against the same one.
#
# Prompt trees only, deliberately: plugins/ is 100k+ entries and ~30s to walk over macOS virtiofs
# (macos.md), and every ordinary `/plugin install` would trip it. What a plugin AUTO-RUNS is the
# part worth an alert, and that is validate_shared_assets' job.
report_shared_asset_writes() {
    local stamp="$STATE_DIR/assets.seen" _t hits=""
    if [ -f "$stamp" ]; then
        for _t in $KIB_ASSETS_PROMPT; do
            [ -d "$CLAUDE_HOME/$_t" ] || continue
            # NO pipe here, and `sed` not `head` below. Under `set -o pipefail` a `find | head`
            # returns 141 the moment head closes the pipe early, and `find` alone returns 1 on
            # any unreadable subdir — either one aborts the launch silently.
            hits="$hits$(find "$CLAUDE_HOME/$_t" -type f -newer "$stamp" 2>/dev/null || true)
"
        done
    fi
    : >"$stamp" 2>/dev/null || true
    # Seed the teardown scan's stamp on a FIRST launch only — never refresh it here, which is the
    # whole reason it is a second file (validate_shared_assets). Seeded, the first teardown after
    # an upgrade reports what this session wrote rather than every plugin already installed, and
    # does not walk a 100k-entry cache to say so. Same judgement as gitaudit's `_since_stamp`.
    [ -f "$STATE_DIR/assets.scanned" ] || : >"$STATE_DIR/assets.scanned" 2>/dev/null || true
    case "$hits" in *[![:space:]]*) ;; *) return 0 ;; esac
    warn "shared prompt assets changed since the last launch:" \
        "$(printf '%s\n' "$hits" | sed -n '/./{s/^/    /;p;}' | sed -n '1,5p')" \
        "They load in every project from now on. Review them if that was not you."
    return 0
}

# These used to be bind-mounted rw from canonical, so a sandboxed session could write the exact
# file a HOST `claude` later loads — and `hooks[].command` / `apiKeyHelper` in it are host code
# execution. The box gets a COPY in $SHARED_BASE (a whole-dir mount, so Claude's atomic rename
# works — the EBUSY footgun that made the credential dir-backed), vetted on the way out.
stage_shared_settings() {
    local f
    for f in settings.json keybindings.json; do
        # Unlink first, never cp over what is there: a file deleted canonically must not be
        # resurrected by a stale copy, and — the one that bit — a leftover single-file
        # mountpoint here is ROOT-owned, so cp fails EACCES where unlink succeeds. A fresh
        # file is also 0600 rather than inheriting whatever mode was there.
        rm -f "$SHARED_BASE/$f" 2>/dev/null || true
        [ -f "$CLAUDE_HOME/$f" ] || continue
        (
            umask 077
            cp "$CLAUDE_HOME/$f" "$SHARED_BASE/$f"
        ) \
            || warn "could not stage $f into this session — the box starts from defaults."
    done
}

# Under the caller's flock on ~/.claude.json.lock. A settings.json that gained a command-running
# key is REFUSED — canonical stays untouched and the rejected copy is left in $SHARED_BASE,
# named. keybindings.json has no command-valued keys, so it folds back unvetted.
merge_out_shared_settings() {
    local f src bad rc
    for f in settings.json keybindings.json; do
        src="$SHARED_BASE/$f"
        [ -f "$src" ] || continue
        cmp -s "$src" "$CLAUDE_HOME/$f" 2>/dev/null && continue # unchanged — leave canonical
        if [ "$f" = settings.json ]; then
            # No vet, no fold-back — an unvetted settings.json is exactly what this closes.
            have_python || {
                warn "python3 not found on the host — cannot vet this session's settings.json," \
                    "so it was NOT merged back into ~/.claude/settings.json."
                continue
            }
            rc=0
            bad="$(kib_py host.settings_scan scan "$src")" || rc=$?
            case "$rc" in
                0) ;;
                1) # Move it aside, don't just name it in place: the next launch re-stages
                    # canonical over $src, so a path we told the user to go and look at
                    # would be gone by the time they looked.
                    mv -f "$src" "$src.rejected" 2>/dev/null || true
                    warn "this session's settings.json added a key that runs a command or" \
                        "redirects your credentials:" \
                        "" \
                        "$(printf '%s\n' "$bad" | sed 's/^/    /')" \
                        "" \
                        "NOT merged back — ~/.claude/settings.json is unchanged. The rejected" \
                        "copy is kept at $src.rejected if you want to look at it."
                    continue
                    ;;
                *)
                    warn "this session's settings.json is unreadable or not valid JSON —" \
                        "not merging it back into ~/.claude/settings.json."
                    continue
                    ;;
            esac
        fi
        if ! (
            umask 077
            cp "$src" "$CLAUDE_HOME/$f.kib.tmp"
        ) || ! mv -f "$CLAUDE_HOME/$f.kib.tmp" "$CLAUDE_HOME/$f"; then
            rm -f "$CLAUDE_HOME/$f.kib.tmp" 2>/dev/null || true
            warn "could not fold $f back to ~/.claude/$f."
        fi
    done
}

# ── Global-config pins ───────────────────────────────────────────
# Best-effort — a host without python3 just gets a warning. See kib.host.pins for why the
# pins are re-asserted every launch and why the write is conditional.
pin_global_config() {
    local f="$1"
    [ -f "$f" ] || return 0
    have_python || {
        warn "python3 not found on the host — cannot pin .claude.json keys."
        return 0
    }
    kib_py host.pins apply "$f" || warn "could not pin .claude.json keys (left it untouched)."
}

# ── Cold-start assembly ──────────────────────────────────────────
assemble_session_dir() {
    # Empty private base for the machine-runtime singletons (daemon, sessions,
    # file-history…); anything Claude Code writes that we do not recognise lands here,
    # never in canonical.
    mkdir -p "$SESSION_BASE/projects" 2>/dev/null || true

    if have_python; then
        # Scoped .claude.json (globals + this project's entry only). Fail-soft to empty.
        # ONE project key: the sidecar binds the project at its host path, so Claude resolves
        # the same cwd canonical is keyed by and there is nothing to translate.
        _scope scope-in-json "$CLAUDE_JSON" "$PWD" "$SESSION_BASE/.claude.json" \
            || warn "could not scope .claude.json — starting this session from an empty config."
        # This project's ↑ history only (never another project's prompts/pastes).
        _scope seed-history "$CLAUDE_HOME/history.jsonl" "$PWD" "$SESSION_BASE/history.jsonl" \
            || : >"$SESSION_BASE/history.jsonl"
    else
        printf '{\n  "projects": {}\n}\n' >"$SESSION_BASE/.claude.json"
        : >"$SESSION_BASE/history.jsonl"
    fi

    # The user's canonical memory, placed directly (not a shared symlink). The sandbox policy
    # is NOT here — it mounts at $KIB_POLICY_CPATH (add_policy_args).
    place_user_claude_md
    # settings/keybindings as a COPY, vetted on the way back out.
    stage_shared_settings
    # Silent-log drift canary: note any top-level ~/.claude entry kib does not recognise.
    check_claude_home_drift

    # This project's transcripts are shared host<->box via a nested bind, so --resume lists
    # the same sessions on both sides. Both ends must exist for the bind. NOT for an
    # ephemeral session: it must persist nothing to canonical.
    [ "$EPHEMERAL" = 1 ] || mkdir -p "$CLAUDE_HOME/projects/$SLUG" 2>/dev/null || true
}

# Diff canonical ~/.claude's top-level entries against the versioned manifest; LOG ONLY.
# Safe by default (unknown → container-private), so this only surfaces "Claude Code grew a
# new store".
check_claude_home_drift() {
    have_python || return 0
    local unknown
    unknown="$(_scope classify "$CLAUDE_HOME" 2>/dev/null || true)"
    [ -n "$unknown" ] || return 0
    echo "ℹ️  kib: unrecognised ~/.claude entries (kept container-private, not shared): $(printf '%s' "$unknown" | tr '\n' ' ')" >&2
}

# ── Merge-out ────────────────────────────────────────────────────
# Fold THIS project's changes back into canonical on the last terminal out — the only moment
# the session files are quiescent. Under a flock on ~/.claude.json.lock so a concurrent host
# claude cannot interleave a write. Subtree-only (.claude.json) + append-only (history) +
# changed-only (credential), so a race loses at most this session's edit and corrupts nothing.
merge_out_session() {
    have_python || {
        merge_out_credential
        merge_out_shared_settings
        return 0
    }
    exec 203>"$CLAUDE_JSON.lock"
    if lock_fd -w 30 -x 203; then
        _scope merge-out-json "$SESSION_BASE/.claude.json" "$PWD" "$CLAUDE_JSON" \
            || warn "could not merge this project's .claude.json changes back to ~/.claude.json."
        _scope merge-history "$SESSION_BASE/history.jsonl" "$PWD" "$CLAUDE_HOME/history.jsonl" \
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
