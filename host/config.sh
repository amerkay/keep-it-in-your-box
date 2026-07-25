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
# Writes: CLAUDE_HOME CLAUDE_JSON SLUG SESSION_BASE SHARED_BASE LOCK_DIR LOCK_FILE
#         BOOT_LOCK STATE_DIR EPHEMERAL SCRATCH_SUFFIX
# shellcheck disable=SC2034  # the globals above are read in bin/kib and the other units

_scope() { kib_py host.config_scope "$@"; }

# ── Identity and paths ───────────────────────────────────────────
# Called once, before anything touches a file. Pure: no mkdir, no docker.
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

    # Host-only state (single-container patterns, the macOS clipboard spool, the lock witness).
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

# ── Sandbox policy CLAUDE.md ─────────────────────────────────────
# Assembled fresh each launch into this session's config dir as `policy block + the user's
# canonical CLAUDE.md`, so the policy loads ONLY in-box and a host `claude` never sees it.
# Regenerated, not merge-preserved — the user's `#` memory lives in canonical and flows in
# every launch, so anything written to the in-box copy is transient by design.
assemble_sandbox_claude_md() {
    local policy="$KIB_ROOT/guest/policy/shared-CLAUDE.md"
    [ -f "$policy" ] || return 0
    local md="$SESSION_BASE/CLAUDE.md"
    local b="<!-- >>> kib sandbox policy (auto-synced by kib — do not edit this block) >>> -->"
    local e="<!-- <<< kib sandbox policy (auto-synced by kib) <<< -->"
    {
        printf '%s\n' "$b"
        cat "$policy"
        printf '%s\n' "$e"
        # The user's own memory, verbatim, below the policy block. Absent on a fresh install.
        if [ -f "$CLAUDE_HOME/CLAUDE.md" ]; then cat "$CLAUDE_HOME/CLAUDE.md"; fi
    } >"$md.kib.tmp" && mv "$md.kib.tmp" "$md"
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
        _scope scope-in-json "$CLAUDE_JSON" "$PWD" "$SESSION_BASE/.claude.json" \
            || warn "could not scope .claude.json — starting this session from an empty config."
        # This project's ↑ history only (never another project's prompts/pastes).
        _scope seed-history "$CLAUDE_HOME/history.jsonl" "$PWD" "$SESSION_BASE/history.jsonl" \
            || : >"$SESSION_BASE/history.jsonl"
    else
        printf '{\n  "projects": {}\n}\n' >"$SESSION_BASE/.claude.json"
        : >"$SESSION_BASE/history.jsonl"
    fi

    # Sandbox policy + the user's canonical memory, placed directly (not a shared symlink).
    assemble_sandbox_claude_md
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
