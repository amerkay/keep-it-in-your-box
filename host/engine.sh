#!/usr/bin/env bash
# Which engine runs the boxes, and the Linux first-launch menu that picks it. kib never runs sudo
# (CLAUDE.md): a pick that needs root prints the steps and quits; it works from the next launch.
# The VM measured ~2x the idle cost of gVisor without it (2026-11-13, `kib stats`, microvm.md).
#
# Reads:  KIB_CFG_VM KIB_CFG_DOCKER KIB_CONFIG GVISOR_VERSION GVISOR_RUNTIME XDG_RUNTIME_DIR
# Writes: ENGINE (vm | rootless | rootful | ask) DOCKER_HOST (exported, rootless socket)
#         _KIB_ROOTFUL _KIB_CONSENTED KIB_CFG_VM KIB_CFG_DOCKER MENU_*
# shellcheck disable=SC2034

# Colours on a terminal only, never under NO_COLOR (no-color.org); a copy drops them anyway.
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    C_B=$'\033[1m' C_D=$'\033[2m' C_G=$'\033[32m' C_Y=$'\033[33m' C_C=$'\033[36m' C_0=$'\033[0m'
else
    C_B='' C_D='' C_G='' C_Y='' C_C='' C_0=''
fi

FUSE_CONF=/etc/fuse.conf
ROOTFUL_SOCK=/var/run/docker.sock
ROOTLESS_DOCS=https://docs.docker.com/engine/security/rootless/

_docker_kind() { # rootless | rootful | nothing when no Docker answers
    local o
    o="$(docker info --format '{{.SecurityOptions}}' 2>/dev/null)" || return 0
    case "$o" in *rootless*) echo rootless ;; *) echo rootful ;; esac
}

# Aim docker at the engine asked for, whatever context the shell's docker uses. Unasked, rootless
# Docker's own socket wins over a rootful default: it is the safer engine.
_use_socket() { # <socket> <rootless|rootful>
    [ -S "$1" ] && [ "$(DOCKER_HOST="unix://$1" _docker_kind)" = "$2" ] || return 0
    export DOCKER_HOST="unix://$1"
}
_prefer_rootless_socket() {
    _use_socket "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock" rootless
}

# `vm = on` forces the VM; `vm = off` forbids it; `docker = rootless|rootful` names the engine.
# Unset on Linux: rootless Docker when it answers, else ask (the menu).
engine_choice() {
    local kind
    if is_macos; then # rootless_use refuses vm = off there, saying how to fix it
        if [ "$KIB_CFG_VM" = off ]; then ENGINE=rootless; else ENGINE=vm; fi
        return 0
    fi
    [ "$KIB_CFG_VM" != on ] || { ENGINE=vm && return 0; }
    if [ "$KIB_CFG_DOCKER" = rootful ]; then
        _use_socket "$ROOTFUL_SOCK" rootful
    else
        _prefer_rootless_socket
    fi
    kind="$(_docker_kind)"
    case "$KIB_CFG_DOCKER:$kind:$KIB_CFG_VM" in
        rootless:* | rootful:*) ENGINE=$KIB_CFG_DOCKER ;; # its _use says how to fix a missing one
        *:rootless:*) ENGINE=rootless ;;
        *:rootful:off) ENGINE=rootful ;;
        *:*:off) ENGINE=rootless ;;
        *) ENGINE=ask ;;
    esac
}

# Asks the system Docker, never whatever the shell's docker points at (often rootless).
_rootful() { DOCKER_HOST="unix://$ROOTFUL_SOCK" "$@"; }
_rootful_ready() {
    [ "$(_rootful _docker_kind)" = rootful ] && _rootful _vm_has_gvisor \
        && grep -qx user_allow_other "$FUSE_CONF" 2>/dev/null
}

# gVisor under the user's own rootful Docker: one barrier, and an escape lands as root.
rootful_use() {
    _rootful_ready || { _rootful_steps && exit 1; }
    export DOCKER_HOST="unix://$ROOTFUL_SOCK" # the menu may have aimed it at rootless first
    _KIB_ROOTFUL=1
    # Docker 29 writes `invalid IP` for host-gateway here too, so name the bridge's gateway.
    KIB_HOST_GATEWAY="$(docker network inspect bridge \
        --format '{{range .IPAM.Config}}{{.Gateway}} {{end}}' 2>/dev/null \
        | grep -oE '([0-9]+\.){3}[0-9]+' | head -1)"
    printf '%s\n' "ℹ️  kib: boxes run on gVisor under your Docker, which runs as root." \
        "   Rootless Docker is safer and just as fast: $ROOTLESS_DOCS (then: kib engine)" >&2
}

# A pasteable block, since kib never runs sudo. Notes are `#` comments, so pasting it whole works
# too, and a step whose predecessor failed fails harmlessly (nothing installs unverified).
_steps() { # <what it sets up> <line…>
    local l
    printf '\n%s\n\n%s\n%s\n\n' "🛠  ${C_B}kib · one-time setup: $1$C_0" \
        "  ${C_D}kib never runs sudo, so these steps are yours. Read each one, then paste it." \
        "  Lines starting with # are notes, so pasting the whole block works too.$C_0" >&2
    shift
    for l; do # notes cyan, what success looks like green, commands plain
        case "$l" in
            '') echo ;;
            *Expect:*) printf '  %s%s%s\n' "$C_G" "$l" "$C_0" ;;
            '#'*) printf '  %s%s%s\n' "$C_C" "$l" "$C_0" ;;
            *) printf '  %s\n' "$l" ;;
        esac
    done >&2
    printf '\n  %s\n\n' "${C_B}Then run kib again.$C_0" >&2
}

_rootful_steps() {
    local v="$GVISOR_VERSION" d="/opt/kib-gvisor/$GVISOR_VERSION" t=/tmp/kib-gvisor.tar.bz2
    [ "$(_rootful _docker_kind)" = rootful ] || printf '%s\n' "" \
        "⚠️  ${C_Y}${C_B}kib: your Docker is not answering at $ROOTFUL_SOCK.$C_0" \
        "   Start it first (sudo systemctl start docker) and be in group docker," \
        "   or install it: https://docs.docker.com/engine/install/" >&2
    _steps "gVisor for your Docker" \
        "# 1. Download gVisor $v, Google's release build." \
        "curl -fL --progress-bar -o $t \\" \
        "    https://storage.googleapis.com/gvisor/releases/release/$v/$(uname -m)/gvisor.tar.bz2" \
        "" \
        "# 2. Check its sha512, then unpack it into $d." \
        "#    Root-owned, so nothing you run without sudo can swap the binary." \
        "#    Expect: $t: OK" \
        "sha=$(_gvisor_sha)" \
        "echo \"\$sha  $t\" | sha512sum -c \\" \
        "    && sudo mkdir -p $d \\" \
        "    && sudo tar -xjf $t -C $d \\" \
        "    && rm $t" \
        "" \
        "# 3. Register it with Docker as runtime $GVISOR_RUNTIME (/etc/docker/daemon.json)." \
        "sudo $d/runsc install --runtime=$GVISOR_RUNTIME \\" \
        "    -- --oci-seccomp" \
        "" \
        "# 4. Let your Docker (root) read kib's redaction view: FUSE user_allow_other." \
        "grep -qx user_allow_other $FUSE_CONF \\" \
        "    || echo user_allow_other | sudo tee -a $FUSE_CONF" \
        "" \
        "# 5. Reload Docker. Running containers keep running." \
        "sudo systemctl reload docker"
}

_rootless_steps() {
    _steps "rootless Docker" \
        "# 1. Install its packages. This is Debian/Ubuntu with Docker's apt repo;" \
        "#    other systems: $ROOTLESS_DOCS" \
        "sudo apt-get install -y uidmap docker-ce-rootless-extras" \
        "" \
        "# 2. Set it up as you, without sudo: a Docker of your own, run by your user session." \
        "#    --force lets it run beside a rootful Docker." \
        "dockerd-rootless-setuptool.sh install --force"
}

_vm_steps() {
    _steps "kib's VM" \
        "# 1. Install QEMU and virtiofsd. kib installs Lima itself, into ~/.local, without sudo." \
        "sudo apt-get install -y qemu-system-x86 qemu-utils virtiofsd" \
        "" \
        "# 2. Check KVM. No /dev/kvm: turn on virtualization (VT-x / AMD-V) in the BIOS." \
        "#    Owned by root:kvm and you are not in group kvm: add yourself, then log in again." \
        "ls -l /dev/kvm" \
        "groups | grep -qw kvm || sudo usermod -aG kvm \"\$USER\""
}

_rootless_installable() {
    command -v dockerd-rootless-setuptool.sh >/dev/null 2>&1 && command -v newuidmap >/dev/null 2>&1
}

# No sudo: its packages are there, so this is the user's own systemd unit and ~/.config.
_rootless_setup() {
    echo "🛠  kib: setting up rootless Docker as you (no sudo)…" >&2
    dockerd-rootless-setuptool.sh install --force >&2 \
        || die "rootless Docker setup failed (output above)." "Docs: $ROOTLESS_DOCS"
    _prefer_rootless_socket
    _KIB_CONSENTED=1 # the menu's Enter already said yes to adding gVisor
}

# ── The menu ─────────────────────────────────────────────────────
# Tags say what Enter does on THIS machine: runs now, or prints the steps and quits.
_menu_rows() {
    MENU_L=("Rootless Docker + gVisor" "Your Docker + gVisor" "kib's VM")
    MENU_N=("fastest, safest" "fastest, as root" "slowest on Linux")
    if [ "$(_docker_kind)" = rootless ]; then
        MENU_T[0]="starts now" MENU_X[0]="use your rootless Docker with gVisor, then continue."
    elif _rootless_installable; then
        MENU_T[0]="sets up now" MENU_X[0]="set up rootless Docker as you (no sudo), add gVisor, continue."
    else
        MENU_T[0]="steps, then quits" MENU_X[0]="print the one-time sudo steps for rootless Docker, then quit."
    fi
    if _rootful_ready; then
        MENU_T[1]="starts now" MENU_X[1]="use your Docker with gVisor, then continue."
    else
        MENU_T[1]="steps, then quits" MENU_X[1]="print the one-time sudo steps for gVisor, then quit."
    fi
    if lima_host_ready; then
        MENU_T[2]="starts now" MENU_X[2]="start kib's VM (installs Lima to ~/.local, no sudo), continue."
    else
        MENU_T[2]="steps, then quits" MENU_X[2]="print the one-time sudo steps for QEMU and KVM, then quit."
    fi
}

_menu_draw() { # <row>: 9 lines, so a redraw moves up exactly that many
    local i m c t
    printf '\n %s\n %s\n\n' "${C_B}kib · how should boxes run on this machine?$C_0" \
        "${C_D}↑/↓ move · Enter choose · saved; change later: kib engine$C_0"
    for i in 0 1 2; do # colours sit outside the padded fields, so the columns stay aligned
        m=' ' c='' && [ "$i" != "$1" ] || m='▸' c="$C_B$C_C"
        case "${MENU_T[$i]}" in steps*) t=$C_Y ;; *) t=$C_G ;; esac
        printf ' %s%s %-26s %-18s%s %s[%s]%s\n' "$c" "$m" "${MENU_L[$i]}" "${MENU_N[$i]}" "$C_0" \
            "$t" "${MENU_T[$i]}" "$C_0"
    done
    printf '\n %sEnter will:%s %s\n' "$C_D" "$C_0" "${MENU_X[$1]}"
}

_menu_key() { # up | down | enter | 1-3 | quit | other, from stdin
    local k r
    IFS= read -rsn1 k || { echo quit && return 0; }
    case "$k" in
        $'\033')
            IFS= read -rsn2 r || true
            case "$r" in '[A') echo up ;; '[B') echo down ;; *) echo other ;; esac
            ;;
        '') echo enter ;;
        k) echo up ;;
        j) echo down ;;
        [123] | q) echo "$k" ;;
        *) echo other ;;
    esac
}

_menu_pick() { # → MENU_PICK (0-2). Keys on stdin, drawing on stderr.
    local i=0 k
    _menu_draw "$i" >&2
    while :; do
        k="$(_menu_key)"
        case "$k" in
            up) [ "$i" = 0 ] || i=$((i - 1)) ;;
            down) [ "$i" = 2 ] || i=$((i + 1)) ;;
            [123]) i=$((k - 1)) ;;
            enter) break ;;
            q | quit) die "no engine picked. Run kib again to choose, or: kib engine" ;;
            *) continue ;;
        esac
        printf '\033[9A\033[J' >&2
        _menu_draw "$i" >&2
    done
    MENU_PICK=$i
}

_save_engine() { # <vm: on|off> [<docker: rootless|rootful>]
    local tmp="$KIB_CONFIG.kib.$$"
    mkdir -p "${KIB_CONFIG%/*}"
    {
        grep -vE '^[[:space:]]*(vm|docker|engine)[[:space:]]*=' "$KIB_CONFIG" 2>/dev/null || true
        echo "vm = $1"
        [ -z "${2:-}" ] || echo "docker = $2"
    } >"$tmp" && mv "$tmp" "$KIB_CONFIG"
    KIB_CFG_VM=$1 KIB_CFG_DOCKER=${2:-}
    printf '\n%s\n' "💾 kib: saved in $KIB_CONFIG. Change it any time: kib engine" >&2
}

# Picks, saves, and sets ENGINE, or prints the steps and quits. No terminal: the config lines.
engine_menu() {
    _menu_rows
    if [ ! -t 0 ] || [ ! -t 2 ]; then
        printf '%s\n' "kib: how should boxes run here? Run kib in a terminal for a menu," \
            "or add one of these lines to $KIB_CONFIG:" \
            "  vm = off   gVisor on your Docker, no VM (fastest; rootless Docker is safest)" \
            "  vm = on    kib's VM (slowest on Linux)" >&2
        exit 2
    fi
    _menu_pick
    case "$MENU_PICK" in
        0)
            _save_engine off rootless
            case "${MENU_T[0]}" in
                steps*) _rootless_steps && exit 1 ;;
                sets*) _rootless_setup ;;
            esac
            ENGINE=rootless
            ;;
        1) _save_engine off rootful && ENGINE=rootful ;; # rootful_use prints the steps if needed
        2) _save_engine on && ENGINE=vm ;;
    esac
}

# `kib engine`: the menu again, set up what the pick needs, then stop.
engine_verb() {
    if is_macos; then
        echo "ℹ️  kib: on macOS boxes always run in kib's VM; there is nothing to pick." >&2
        return 0
    fi
    engine_menu
    case "$ENGINE" in
        rootless) rootless_use ;;
        rootful) rootful_use ;;
        vm) lima_host_ready || { _vm_steps && exit 1; } ;;
    esac
    echo "✅ kib: the next launch runs boxes with: ${MENU_L[$MENU_PICK]}." >&2
}
