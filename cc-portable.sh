#!/usr/bin/env bash
# Sourced by cc, cc-lib.sh and build-bg.sh before anything platform-specific runs.
# The ONE file that branches on OS: everywhere else calls the shims defined here.
#
# ── Portability contract (enforced by check.sh) ───────────────────
# Host-side cc scripts must run unmodified on stock macOS (bash 3.2 + BSD userland
# + system perl) AND on Linux. GNU-only tools (flock, setsid, sha256sum, grep -P,
# findmnt, notify-send) and bash-4isms (declare -A, ${var,,}, readarray/mapfile)
# are allowed ONLY inside this file's `linux` branches. Elsewhere use the shims.
#
# Shims are DETERMINISTIC per OS — darwin always takes the perl/BSD path, linux
# always the GNU path. No native-first fallback: exactly two code paths, and
# check.sh forces the perl paths on Linux so both are always exercised.

# Idempotent — cc sources this, then cc-lib.sh; tests may re-source.
[ -n "${CC_PORTABLE_SOURCED:-}" ] && return 0
CC_PORTABLE_SOURCED=1

case "$(uname -s)" in
    Darwin) CC_OS=darwin ;;
    *)      CC_OS=linux ;;
esac

is_macos() { [ "$CC_OS" = darwin ]; }

# Redaction topology: the verified cap-drop=ALL sidecar on Linux, single-container
# FUSE on macOS (no shared-mount propagation there). CC_SINGLE_CONTAINER=1 forces
# the macOS path on Linux — the test vehicle exercised by check.sh/security-test.
# (CC_FUSE_MODE is read across the source boundary in cc/cc-lib.sh.)
# shellcheck disable=SC2034
if is_macos || [ "${CC_SINGLE_CONTAINER:-0}" = 1 ]; then
    CC_FUSE_MODE=single
else
    CC_FUSE_MODE=sidecar
fi

_is_uint() { case "$1" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# ── flock(1) shim ─────────────────────────────────────────────────
# Linux: pass straight through. Darwin: perl flock() on the *inherited* fd. The
# redirection `<&FD` dups the shell's fd into perl's STDIN, so both share one open
# file description; the lock therefore persists after perl exits (the shell's fd
# keeps the description alive) and releases when the shell closes the fd or calls
# `lock_fd -u` — identical semantics to flock(1). Forms cc uses:
#   -w N -s FD | -x FD | -n -x FD | -n FD | -u FD | -n FILE CMD...
_CC_FLOCK_PL='
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
    if [ "$CC_OS" != darwin ]; then
        flock "$@"
        return
    fi
    local nb=0 mode="" to=0
    while [ $# -gt 0 ]; do
        case "$1" in
            -n | --nonblock)  nb=1 ;;
            -s | --shared)    mode=SH ;;
            -x | --exclusive) mode=EX ;;
            -u | --unlock)    mode=UN ;;
            -w | --timeout)   shift; to="$1" ;;
            -w*)              to="${1#-w}" ;;
            --)               shift; break ;;
            -*)               ;;      # ignore any flag we don't use
            *)                break ;;
        esac
        shift
    done
    [ -n "$mode" ] || mode=EX          # flock(1) defaults to exclusive
    if [ $# -eq 1 ] && _is_uint "$1"; then
        # $fd is a literal here so it can name the redirection; the perl program
        # and the other args stay escaped so they expand in the eval'd context.
        local fd="$1"
        eval "perl -e \"\$_CC_FLOCK_PL\" \"\$mode\" \"\$nb\" \"\$to\" <&$fd"
    else
        perl -e "$_CC_FLOCK_PL" "$mode" "$nb" "$to" "$@"
    fi
}

# ── sha256 (first 8 hex chars) ────────────────────────────────────
hash8() {
    if [ "$CC_OS" = darwin ]; then
        printf '%s' "$1" | shasum -a 256 | cut -c1-8
    else
        printf '%s' "$1" | sha256sum | cut -c1-8
    fi
}

# ── own-process-group launcher ────────────────────────────────────
# Backgrounds "$@" in its own process group so `kill -TERM -$!` (negative pid)
# signals the whole tree. Linux: setsid. Darwin: perl POSIX::setsid + exec — in a
# non-interactive script `&` leaves the child in the shell's process group, so
# setsid() succeeds and $! is the new group leader, exactly like setsid(1). $!
# survives the function return (it is shell-global), so callers read it as usual.
detach_pgrp() {
    if [ "$CC_OS" = darwin ]; then
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
    if [ "$CC_OS" = darwin ]; then
        command -v osascript >/dev/null 2>&1 || return 0
        # Escape for the AppleScript string literals.
        title=${title//\\/\\\\}; title=${title//\"/\\\"}
        body=${body//\\/\\\\};   body=${body//\"/\\\"}
        osascript -e "display notification \"$body\" with title \"$title\"" >/dev/null 2>&1 || true
    else
        local icon=dialog-information
        [ "$urgency" = critical ] && icon=dialog-error
        command -v notify-send >/dev/null 2>&1 || return 0
        notify-send -u "$urgency" -i "$icon" "$title" "$body" 2>/dev/null || true
    fi
}

# ── macOS launch preflight ────────────────────────────────────────
# Linux: no-op (its topology is the verified default). Darwin: fail fast and
# clearly on anything that would otherwise surface as a confusing mid-launch
# error. The SYS_ADMIN+/dev/fuse redaction mount itself is validated where it is
# actually created — entrypoint-fuse.sh aborts the container if it can't mount —
# so this stays cheap and engine-agnostic.
_preflight_die_no_engine() {
    die "no reachable Docker engine on this Mac." \
        "cc is engine-agnostic — install any one of:" \
        "  • Docker Desktop   https://www.docker.com/products/docker-desktop/" \
        "  • OrbStack         https://orbstack.dev" \
        "  • Colima           brew install colima docker && colima start" \
        "then start it and relaunch cc."
}

preflight_platform() {
    [ "$CC_OS" = darwin ] || return 0
    command -v docker >/dev/null 2>&1 || _preflight_die_no_engine
    docker info >/dev/null 2>&1 || _preflight_die_no_engine
    command -v perl >/dev/null 2>&1 || die \
        "perl was not found, but cc's macOS lock/setsid/notify shims need it." \
        "perl ships with macOS; restore it (or install via Homebrew: brew install perl)."

    # Bind-mount sanity: an engine not sharing $PWD would silently mount an empty
    # project. Only meaningful once the image exists (first run builds it, then the
    # in-container mount validates itself), so skip until then.
    if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        if ! docker run --rm --entrypoint true -v "$PWD:/cc-probe:ro" "$IMAGE_NAME" >/dev/null 2>&1; then
            die "this Docker engine did not share $PWD into a container." \
                "cc mounts your project by path, so the engine must expose it." \
                "Docker Desktop: Settings → Resources → File sharing must include" \
                "this path (or its parent). OrbStack/Colima share \$HOME by default."
        fi
    fi
}
