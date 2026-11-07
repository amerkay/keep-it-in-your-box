#!/usr/bin/env bash
# Loaded second by host/_load.sh, and directly by tools/build-image.sh and host/sleep-guard.sh.
# The ONE file that branches on OS: everywhere else calls the shims defined here.
#
# ── Portability contract (enforced by tests/check/portability.sh) ─
# Host-side scripts must run unmodified on stock macOS (bash 3.2 + BSD userland + system perl)
# AND on Linux. GNU-only tools (flock, setsid, sha256sum, grep -P, notify-send) and
# bash-4isms (declare -A, ${var,,}, readarray) are allowed ONLY in this file's `linux` branches.
# Shims are DETERMINISTIC per OS — no native-first fallback, exactly two paths, and the check
# suite forces the perl paths on Linux so both stay exercised.
#
# Reads:  KIB_CONFIG, and (FUSE shims only) KIB_STATE_ROOT IMAGE_NAME from core.sh / bin/kib
# Writes: KIB_OS, KIB_CFG_* (from ~/.keep-it-in-your-box/config) — all read across the source
#         boundary by the other host units
# shellcheck disable=SC2034

# Idempotent — bin/kib sources this through _load.sh; tests may re-source.
[ -n "${KIB_PORTABLE_SOURCED:-}" ] && return 0
KIB_PORTABLE_SOURCED=1

case "$(uname -s)" in
    Darwin) KIB_OS=darwin ;;
    *) KIB_OS=linux ;;
esac

is_macos() { [ "$KIB_OS" = darwin ]; }

# The engine runs in kib's Lima VM (host/vm.sh; always on macOS). Set here, never from the
# environment — an inherited 1 would aim engine_ns_exec's privileged nsenter at THIS host.
_KIB_ENGINE_VM=0
engine_lima() { [ "$_KIB_ENGINE_VM" = 1 ]; }

# virtiofs on both: 9p writes ~6x slower. Never reverse-sshfs: it can reach host paths no mount
# names.
LIMA_MOUNT_TYPE=virtiofs
if is_macos; then LIMA_VM_TYPE=vz; else LIMA_VM_TYPE=qemu; fi
# Lima on Linux needs QEMU, KVM and virtiofsd, which take root to set up (docs/vm.md). macOS has
# its own. virtiofsd: where Lima looks for it.
lima_host_ready() {
    is_macos && return 0
    command -v "qemu-system-$(uname -m)" >/dev/null && command -v qemu-img >/dev/null \
        && [ -w /dev/kvm ] && {
        command -v virtiofsd >/dev/null || [ -x /usr/libexec/virtiofsd ] \
            || [ -x /usr/lib/qemu/virtiofsd ]
    }
}

_is_uint() { case "$1" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac }

# ── flock(1) shim ─────────────────────────────────────────────────
# Linux: pass through. Darwin: perl flock() on the *inherited* fd — `<&FD` dups the shell's fd
# into perl's STDIN so both share one open file description, which is what makes the lock
# outlive perl and release only on close or `lock_fd -u`, exactly like flock(1). Forms used:
#   -w N -s FD | -x FD | -n -x FD | -n FD | -u FD | -n FILE CMD...
# shellcheck disable=SC2016  # perl source, not shell — $sigils belong to perl
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

sha256_file() {
    if [ "$KIB_OS" = darwin ]; then shasum -a 256 <"$1"; else sha256sum <"$1"; fi | cut -d' ' -f1
}

# ── own-process-group launcher ────────────────────────────────────
# Backgrounds "$@" in its own process group so `kill -TERM -$!` signals the whole tree. Darwin
# uses perl POSIX::setsid + exec: in a non-interactive script `&` leaves the child in the
# shell's process group, so setsid() succeeds and $! is the new group leader, as with setsid(1).
detach_pgrp() {
    if [ "$KIB_OS" = darwin ]; then
        # Close EVERY inherited descriptor above stderr before exec — closing 200/201 by number
        # at the call site is not enough on macOS. bash 3.2 implements a redirection applied to a
        # function call by saving the original fd to a dup ≥10 for the post-call restore, and does
        # not set close-on-exec on it; the detached child then inherits the project lock as fd 10.
        # A daemon that outlives kib holding that lock blocks teardown forever — and because
        # teardown is what would kill it, it never gets killed. (`container-lifecycle.md`)
        perl -MPOSIX -e 'POSIX::setsid() or exit 127;
            POSIX::close($_) for 3 .. 255;
            exec @ARGV or exit 127' "$@" &
    else
        setsid "$@" &
    fi
}

# Kill the process group recorded in <pidfile>, and drop the file. The only sanctioned way to
# undo detach_pgrp: a bare `kill -TERM -$pid` is a loaded gun, because a detached child that
# already exited frees its pid, the number is recycled — near-sequentially on Linux, so often
# by the very next launch — and the group it now names can be kib's OWN. That shipped once: it
# SIGTERMed bin/kib right after the banner, with no message and no container. Hence both
# guards: never our group, and the pid must still LEAD its group (a recycled number is almost
# never a group leader).
kill_pgrp() { # <pidfile>
    local pid ours
    [ -n "${1:-}" ] || return 0
    pid="$(cat "$1" 2>/dev/null || true)"
    rm -f "$1" 2>/dev/null || true
    case "$pid" in '' | *[!0-9]*) return 0 ;; esac
    ours="$(ps -p $$ -o pgid= 2>/dev/null | tr -d ' ')"
    [ "$pid" = "$ours" ] && return 0
    [ "$(ps -p "$pid" -o pgid= 2>/dev/null | tr -d ' ')" = "$pid" ] || return 0
    kill -TERM "-$pid" 2>/dev/null || true
    return 0
}

# ── desktop notification ──────────────────────────────────────────
# <urgency: normal|critical> <title> <body>. Best-effort no-op with no notifier
# or no desktop session (ssh, `-p`).
#
# The one launch channel that survives claude's TUI clearing the screen milliseconds after kib
# writes to stderr. For PROBLEMS ONLY — a working launch notifies nothing, so any popup means
# something needs the user. Never add a launch-succeeded notification.
# urgency: normal (degraded) | critical (sticky).
notify_desktop() {
    local urgency="$1" title="$2" body="$3"
    if [ "$KIB_OS" = darwin ]; then
        # terminal-notifier first: `display notification` from a DETACHED osascript is attributed
        # to Script Editor and dropped silently without that grant — and the loudest caller,
        # clipboard-bridge.sh, is exactly that (detach_pgrp). Same order as it uses itself.
        if command -v terminal-notifier >/dev/null 2>&1; then
            terminal-notifier -title "$title" -message "$body" >/dev/null 2>&1 || true
            return 0
        fi
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

# ── Is there a `claude` on the HOST? ──────────────────────────────
# Prints its path, or nothing. The shared ~/.claude trees load in every project's box AND in a
# native host `claude` — and only that second reader is unsandboxed, so it is the difference
# between "another box runs this" and "this runs as you on your machine". kib's warning about
# those trees is gated on it.
#
# Deliberately NOT `npm prefix -g`: that spawns node on a launch path to earn one line of prose.
# A `claude` that exists only as a shell alias or function is a false negative; the cost is a
# warning we do not print, so failing open here is the cheap direction. Memoised for the launch.
host_claude_path() {
    if [ -z "${KIB_HOST_CLAUDE+x}" ]; then
        KIB_HOST_CLAUDE="$(command -v claude 2>/dev/null || true)"
        if [ -z "$KIB_HOST_CLAUDE" ]; then
            local _c
            for _c in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" \
                "$HOME/.npm-global/bin/claude" "${npm_config_prefix:-/nonexistent}/bin/claude" \
                /opt/homebrew/bin/claude /usr/local/bin/claude /usr/bin/claude; do
                if [ -x "$_c" ]; then
                    KIB_HOST_CLAUDE="$_c"
                    break
                fi
            done
        fi
    fi
    printf '%s\n' "$KIB_HOST_CLAUDE"
}

# The ids everything in the box runs as: ours. Every --user, HOST_UID and FUSE id goes through
# these (tests/check/regressions.sh).
box_uid() { id -u; }
box_gid() { id -g; }

# ── The FUSE redaction root ───────────────────────────────────────
# The sidecar mounts the redacted view under this root and the agent's container consumes it by
# mount propagation, so both containers must see the same directory AND the mount *event* must
# be able to travel between them.
#
# That rules out any path the engine serves as a file share: a share has no mount namespace for
# the event to land in. The root is a VM-local dir, never a Lima mount; not /run, which
# Ubuntu's fusermount3 AppArmor profile denies. (docs/design-notes/macos.md)
fuse_root_path() { printf '/mnt/kib/fuse.%s\n' "$1"; } # <per-project key>

# Root in the VM, over Lima's own ssh. Its ssh master may outlive kib: no lock fd.
vm_root() {
    limactl shell --workdir / "$KIB_VM_NAME" sudo -n -- "$@" </dev/null \
        200>&- 201>&- 202>&- 205>&- 206>&-
}
engine_ns_exec() { vm_root "$@" >/dev/null 2>&1; }

# ── Mount state ───────────────────────────────────────────────────
# Ask the kernel directly. `mountpoint -q` is NOT usable: after the server dies the mount stays
# in the table but stat() returns ENOTCONN, so mountpoint calls a directory that still IS one
# "not a mountpoint" — and the unmount gets skipped.
# shellcheck disable=SC2016  # $1 is the inner sh's argument, not ours
fuse_mounted() {
    engine_ns_exec sh -c '
        while read -r _d _m _r; do [ "$_m" = "$1" ] && exit 0; done </proc/self/mounts
        exit 1' _ "$1"
}

# `umount -l` only: the VM has no fusermount3, and the server is in a container we are about to
# remove — there is nobody to answer a clean unmount.
unmount_fuse() {
    fuse_mounted "$1" || return 0
    engine_ns_exec umount -l "$1" || true
    ! fuse_mounted "$1"
}

# ── Root lifecycle ────────────────────────────────────────────────
# Create <root>/mnt owned by <uid>:<gid>, propagating shared. Called once per cold start, before
# the sidecar. A plain directory cannot be a propagation peer until it is a mount in its own
# right: bind it to itself, then mark it rshared — idempotent, since the second call finds it
# already mounted. `chown`: fusermount3 refuses a mountpoint its caller does not own.
fuse_root_create() { # <root> <uid> <gid>
    # shellcheck disable=SC2016  # $1..$3 are the inner sh's arguments, not ours
    engine_ns_exec sh -c '
        mkdir -p "$1/mnt" || exit 1
        chmod 755 "$1" "$1/mnt"
        chown "$2:$3" "$1/mnt" || exit 1
        grep -q " $1 " /proc/self/mounts || mount --bind "$1" "$1" || exit 1
        mount --make-rshared "$1"' _ "$1" "$2" "$3" \
        || die "could not prepare the redaction root inside the VM ($1)." \
            "kib cannot serve the .kibignore redaction without it, and will not run" \
            "unprotected. Restart the VM (limactl stop $KIB_VM_NAME) and try again."
}

# The bind-to-self must go before the rm, or the next launch inherits a stacked mount.
fuse_root_destroy() { # <root>
    # shellcheck disable=SC2016  # $1 is the inner sh's argument, not ours
    engine_ns_exec sh -c 'umount -l "$1" 2>/dev/null; rm -rf "$1"' _ "$1" || true
}

# ── macOS launch preflight ────────────────────────────────────────
# Darwin only: fail fast on what would otherwise surface as a confusing mid-launch error. The
# redaction mount validates itself in host/redaction.sh, so this stays cheap.

# The direct .dmg for THIS Mac's cpu. The landing page makes you pick, and picking wrong is a
# multi-GB download that will not launch.
# macOS: the engine is kib's Lima VM (vm_use), so only the shims' own dependency is left to check.
preflight_platform() {
    [ "$KIB_OS" = darwin ] || return 0
    command -v perl >/dev/null 2>&1 || die \
        "perl was not found, but kib's macOS lock/setsid/notify shims need it." \
        "perl ships with macOS; restore it (or install via Homebrew: brew install perl)."
}

# ── ~/.keep-it-in-your-box/config (host-only user prefs) ──────────────────────
# HOST-ONLY, never bind-mounted in: what governs the agent's credentials and egress must live
# where the agent cannot rewrite it. Simple `key = value`, no shell eval; unknown keys ignored.
#
# Keys (all optional; the assignments below are the defaults):
#   broker              = on | off    — start the credential broker. ON by default; disable
#                                       here or with KIB_BROKER=0. See broker_wanted().
#
# `broker` is the ONLY key. This parser also used to accept egress/allow_host_services/
# allow_lan/lan_cidrs for a filtering proxy that was never built (README: "deliberately
# unscheduled"), so `egress = restricted` was accepted in silence and restricted nothing —
# a dead knob that read as an armed security control. Unknown keys are ignored, so anyone
# who already has those lines is unaffected. Re-add the parse WITH the implementation.
#
# KIB_CFG_* is the parsed config FILE; bare KIB_* are the env overrides. The two namespaces
# must stay apart — they once shared the name KIB_BROKER and silently clobbered each other.
# shellcheck disable=SC2034
KIB_CONFIG="${KIB_CONFIG:-$HOME/.keep-it-in-your-box/config}"
KIB_CFG_BROKER=on

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
            broker) KIB_CFG_BROKER="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')" ;;
        esac
    done <"$KIB_CONFIG"
}
read_kib_config
