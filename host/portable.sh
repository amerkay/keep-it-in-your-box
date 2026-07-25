#!/usr/bin/env bash
# Loaded second by host/_load.sh, and directly by tools/build-bg.sh and host/sleep-guard.sh.
# The ONE file that branches on OS: everywhere else calls the shims defined here.
#
# ── Portability contract (enforced by tests/check/portability.sh) ─
# Host-side scripts must run unmodified on stock macOS (bash 3.2 + BSD userland + system perl)
# AND on Linux. GNU-only tools (flock, setsid, sha256sum, grep -P, findmnt, notify-send) and
# bash-4isms (declare -A, ${var,,}, readarray) are allowed ONLY in this file's `linux` branches.
# Shims are DETERMINISTIC per OS — no native-first fallback, exactly two paths, and the check
# suite forces the perl paths on Linux so both stay exercised.
#
# Reads:  KIB_SINGLE_CONTAINER, KIB_CONFIG
# Writes: KIB_OS, KIB_FUSE_MODE, KIB_CFG_* (from ~/.keep-it-in-your-box/config) — all read
#         across the source boundary by the other host units
# shellcheck disable=SC2034

# Idempotent — bin/kib sources this through _load.sh; tests may re-source.
[ -n "${KIB_PORTABLE_SOURCED:-}" ] && return 0
KIB_PORTABLE_SOURCED=1

case "$(uname -s)" in
    Darwin) KIB_OS=darwin ;;
    *) KIB_OS=linux ;;
esac

is_macos() { [ "$KIB_OS" = darwin ]; }

# Redaction topology: cap-drop=ALL sidecar on Linux, single-container FUSE on macOS (which has
# no shared-mount propagation). KIB_SINGLE_CONTAINER=1 forces the macOS path on Linux — the
# test vehicle both suites run against.
# shellcheck disable=SC2034
if is_macos || [ "${KIB_SINGLE_CONTAINER:-0}" = 1 ]; then
    KIB_FUSE_MODE=single
else
    KIB_FUSE_MODE=sidecar
fi

_is_uint() { case "$1" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac }

# ── flock(1) shim ─────────────────────────────────────────────────
# Linux: pass through. Darwin: perl flock() on the *inherited* fd — `<&FD` dups the shell's fd
# into perl's STDIN so both share one open file description, which is what makes the lock
# outlive perl and release only on close or `lock_fd -u`, exactly like flock(1). Forms used:
#   -w N -s FD | -x FD | -n -x FD | -n FD | -u FD | -n FILE CMD...
_KIB_FLOCK_PL='
use Fcntl qw(:flock);
my ($mode, $nb, $to) = (shift, shift, shift);
my %M = (SH => LOCK_SH, EX => LOCK_EX, UN => LOCK_UN);
my $op = $M{$mode} | ($nb ? LOCK_NB : 0);
my $fh;
if (@ARGV) {                       # file form: open FILE, lock, run CMD, release
    open($fh, ">>", shift) or exit 2;
} else {                           # fd form: lock the inherited fd (STDIN)
    $fh = \*STDIN;
}
if ($to && $to > 0) { $SIG{ALRM} = sub { exit 1 }; alarm($to); }
flock($fh, $op) or exit 1;
alarm(0);
exit 0 unless @ARGV;
system(@ARGV);
exit($? == -1 ? 127 : $? >> 8);
'

lock_fd() {
    if [ "$KIB_OS" != darwin ]; then
        flock "$@"
        return
    fi
    local nb=0 mode="" to=0
    while [ $# -gt 0 ]; do
        case "$1" in
            -n | --nonblock) nb=1 ;;
            -s | --shared) mode=SH ;;
            -x | --exclusive) mode=EX ;;
            -u | --unlock) mode=UN ;;
            -w | --timeout)
                shift
                to="$1"
                ;;
            -w*) to="${1#-w}" ;;
            --)
                shift
                break
                ;;
            -*) ;; # ignore any flag we don't use
            *) break ;;
        esac
        shift
    done
    [ -n "$mode" ] || mode=EX # flock(1) defaults to exclusive
    if [ $# -eq 1 ] && _is_uint "$1"; then
        # $fd is a literal here so it can name the redirection; the perl program
        # and the other args stay escaped so they expand in the eval'd context.
        local fd="$1"
        eval "perl -e \"\$_KIB_FLOCK_PL\" \"\$mode\" \"\$nb\" \"\$to\" <&$fd"
    else
        perl -e "$_KIB_FLOCK_PL" "$mode" "$nb" "$to" "$@"
    fi
}

# ── sha256 (first 8 hex chars) ────────────────────────────────────
hash8() {
    if [ "$KIB_OS" = darwin ]; then
        printf '%s' "$1" | shasum -a 256 | cut -c1-8
    else
        printf '%s' "$1" | sha256sum | cut -c1-8
    fi
}

# ── own-process-group launcher ────────────────────────────────────
# Backgrounds "$@" in its own process group so `kill -TERM -$!` signals the whole tree. Darwin
# uses perl POSIX::setsid + exec: in a non-interactive script `&` leaves the child in the
# shell's process group, so setsid() succeeds and $! is the new group leader, as with setsid(1).
detach_pgrp() {
    if [ "$KIB_OS" = darwin ]; then
        perl -MPOSIX -e 'POSIX::setsid() or exit 127; exec @ARGV or exit 127' "$@" &
    else
        setsid "$@" &
    fi
}

# ── desktop notification ──────────────────────────────────────────
# <urgency: normal|critical> <title> <body>. Best-effort no-op with no notifier
# or no desktop session (ssh, `-p`).
notify_desktop() {
    local urgency="$1" title="$2" body="$3"
    if [ "$KIB_OS" = darwin ]; then
        command -v osascript >/dev/null 2>&1 || return 0
        # Escape for the AppleScript string literals.
        title=${title//\\/\\\\}
        title=${title//\"/\\\"}
        body=${body//\\/\\\\}
        body=${body//\"/\\\"}
        osascript -e "display notification \"$body\" with title \"$title\"" >/dev/null 2>&1 || true
    else
        local icon=dialog-information
        [ "$urgency" = critical ] && icon=dialog-error
        command -v notify-send >/dev/null 2>&1 || return 0
        notify-send -u "$urgency" -i "$icon" "$title" "$body" 2>/dev/null || true
    fi
}

# ── macOS launch preflight ────────────────────────────────────────
# Darwin only: fail fast on what would otherwise surface as a confusing mid-launch error. The
# redaction mount validates itself in entrypoint-fuse.sh, so this stays cheap.
_preflight_die_no_engine() {
    die "no reachable Docker engine on this Mac." \
        "kib is engine-agnostic — install any one of:" \
        "  • Docker Desktop   https://www.docker.com/products/docker-desktop/" \
        "  • OrbStack         https://orbstack.dev" \
        "  • Colima           brew install colima docker && colima start" \
        "then start it and relaunch."
}

preflight_platform() {
    [ "$KIB_OS" = darwin ] || return 0
    command -v docker >/dev/null 2>&1 || _preflight_die_no_engine
    docker info >/dev/null 2>&1 || _preflight_die_no_engine
    command -v perl >/dev/null 2>&1 || die \
        "perl was not found, but kib's macOS lock/setsid/notify shims need it." \
        "perl ships with macOS; restore it (or install via Homebrew: brew install perl)."

    # An engine not sharing $PWD would silently mount an empty project. Only checkable once
    # the image exists, so skip until then.
    if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        if ! docker run --rm --entrypoint true -v "$PWD:/kib-probe:ro" "$IMAGE_NAME" >/dev/null 2>&1; then
            die "this Docker engine did not share $PWD into a container." \
                "kib mounts your project by path, so the engine must expose it." \
                "Docker Desktop: Settings → Resources → File sharing must include" \
                "this path (or its parent). OrbStack/Colima share \$HOME by default."
        fi
    fi
}

# ── ~/.keep-it-in-your-box/config (host-only user prefs) ──────────────────────
# HOST-ONLY, never bind-mounted in: what governs the agent's credentials and egress must live
# where the agent cannot rewrite it. Simple `key = value`, no shell eval; unknown keys ignored.
#
# Keys (all optional; the assignments below are the defaults):
#   broker              = on | off    — start the credential broker. ON by default; disable
#                                       here or with KIB_BROKER=0. See broker_wanted().
#   egress              = open | restricted  — restricted activates the future E1 proxy.
#   allow_host_services = false | true  — under restricted egress, reach host.docker.internal
#                                         (e.g. a Nuxt dev server on :3000).
#   allow_lan           = false | true  — under restricted egress, reach RFC1918 LAN HTTP(S).
#   lan_cidrs           = 10.0.0.0/8, 192.168.0.0/16   — optional narrowing for allow_lan.
# Link-local / cloud metadata (169.254.0.0/16) is always denied under restricted egress.
#
# KIB_CFG_* is the parsed config FILE; bare KIB_* are the env overrides. The two namespaces
# must stay apart — they once shared the name KIB_BROKER and silently clobbered each other.
# shellcheck disable=SC2034
KIB_CONFIG="${KIB_CONFIG:-$HOME/.keep-it-in-your-box/config}"
KIB_CFG_BROKER=on
KIB_CFG_EGRESS=open
KIB_CFG_ALLOW_HOST=false
KIB_CFG_ALLOW_LAN=false
KIB_CFG_LAN_CIDRS=""

# How the agent reaches the broker. "bridge" (container→container on a user net) is verified
# against Portmaster; "hostgw" — broker publishes a host-loopback port, agent reaches it via
# host.docker.internal — is the swappable fallback if a host firewall blocks that hop.
# shellcheck disable=SC2034
KIB_BROKER_ENDPOINT_MODE="${KIB_BROKER_ENDPOINT_MODE:-bridge}"

read_kib_config() {
    [ -f "$KIB_CONFIG" ] || return 0
    local line key val
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"                      # strip comment
        line="${line#"${line%%[![:space:]]*}"}" # ltrim
        line="${line%"${line##*[![:space:]]}"}" # rtrim
        [ -z "$line" ] && continue
        case "$line" in *=*) ;; *) continue ;; esac
        key="${line%%=*}"
        val="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}" # rtrim key
        val="${val#"${val%%[![:space:]]*}"}" # ltrim val
        val="${val%"${val##*[![:space:]]}"}" # rtrim val
        case "$key" in
            broker) KIB_CFG_BROKER="$(printf '%s' "$val" | tr 'A-Z' 'a-z')" ;;
            egress) KIB_CFG_EGRESS="$(printf '%s' "$val" | tr 'A-Z' 'a-z')" ;;
            allow_host_services) KIB_CFG_ALLOW_HOST="$(printf '%s' "$val" | tr 'A-Z' 'a-z')" ;;
            allow_lan) KIB_CFG_ALLOW_LAN="$(printf '%s' "$val" | tr 'A-Z' 'a-z')" ;;
            lan_cidrs) KIB_CFG_LAN_CIDRS="$val" ;;
        esac
    done <"$KIB_CONFIG"
}
read_kib_config
