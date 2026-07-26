#!/usr/bin/env bash
# Sourced by tests/check.sh — the portability contract, in both host-side languages.
#
# Host-side scripts must be bash-3.2/BSD-clean (stock macOS, no brew). Two tiers:
#   FATAL    — bash-4isms, empty-array expansion, and shimmed tools with a drop-in
#              replacement (flock→lock_fd, sha256sum→hash8, grep -P).
#   ADVISORY — setsid / notify-send: shimmed too, but the Wayland and broker notifiers use them
#              raw BY DESIGN (structurally Linux-only), so these report rather than fail.
#
# Host-side python must import on the python3 stock macOS ships (3.9) — see the second section.
#
# Comments are stripped naively first; no flagged token appears inside a string in this repo.

# shellcheck source=SCRIPTDIR/_guard.sh
. "${BASH_SOURCE%/*}/_guard.sh" # sourced by tests/check.sh, never run directly

section "Portability contract (host-side scripts, bash-3.2/BSD-clean)"

# `flock` banned as a COMMAND (GNU-only); `flock(` is perl's builtin, which is the portable
# binding both the darwin shim and shims.sh's oracle are built on.
FATAL_RE='(declare[[:space:]]+-A|[[:space:]]mapfile[[:space:]]|[[:space:]]readarray[[:space:]]|\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^|,|\^)[}:/]|(^|[^_.])\bflock\b($|[^(])|\bsha256sum\b|grep[[:space:]]+-[a-zA-Z]*P)'
ADVISORY_RE='(\bsetsid\b|\bnotify-send\b)'

# bash 3.2 expands "${arr[@]}" of an EMPTY array as an *unbound variable* under `set -u`
# (fixed only in 4.4), so it aborts the launch. Every array ever assigned `()` must expand
# through the `${arr[@]+"${arr[@]}"}` idiom — including where it reads as provably non-empty,
# since the reader cannot verify that and one later edit makes it empty. Prints offenders.
unguarded_empty_arrays() {
    local code="$1" a out
    while read -r a; do
        [ -n "$a" ] || continue
        # Delete the safe idiom first — it contains the bare form as a substring.
        out="$(printf '%s\n' "$code" | sed "s/\${$a\[@\]+\"\${$a\[@\]}\"}//g" \
            | grep -c "\${$a\[@\]}" || true)"
        [ "${out:-0}" -gt 0 ] && printf ' %s' "$a"
    done <<EOF
$(printf '%s\n' "$code" \
        | sed -n 's/^\(.*[^A-Za-z0-9_]\)\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)=()[[:space:]]*.*$/\2/p' \
        | sort -u)
EOF
    true
}

for f in "${HOST_BASH[@]}" "${HOST_SH[@]}"; do
    [ -f "$f" ] || continue
    # host/portable.sh is the shim home. The rest of the check suite is a dev harness and is
    # exempt — EXCEPT shims.sh, which exists to prove the darwin paths and is therefore run on
    # macOS too. It used raw flock(1) as its oracle under this exemption; on a real Mac every
    # such call died "command not found", which the tests read as "the lock is held" — two
    # assertions became false passes and three false failures. Held to the contract now.
    case "$f" in tests/check/shims.sh) ;;
    host/portable.sh | tests/check.sh | tests/check/*.sh)
        pass "$f (shim home / dev tool — exempt)"
        continue
        ;;
    esac
    code="$(sed 's/#.*$//' "$f")"
    hits="$(printf '%s\n' "$code" | grep -nE "$FATAL_RE" || true)"
    arrays="$(unguarded_empty_arrays "$code")"
    if [ -n "$hits" ]; then
        fail "$f uses a non-portable construct" "$(printf '%s' "$hits" | head -4)"
    elif [ -n "$arrays" ]; then
        fail "$f expands a possibly-empty array bare (bash 3.2 + set -u aborts)" \
            "use \${arr[@]+\"\${arr[@]}\"} for:$arrays"
    else
        pass "$f is bash-3.2/BSD-clean"
    fi
    adv="$(printf '%s\n' "$code" | grep -nE "$ADVISORY_RE" || true)"
    [ -n "$adv" ] && warn "$f uses setsid/notify-send raw (OK only if Linux-only)" \
        "$(printf '%s' "$adv" | head -3)"
done

# All OS branching lives in host/portable.sh. A `uname` or a Darwin case anywhere else on a
# host path means a second, un-shimmed code path has appeared. Exempt: portable.sh itself,
# sleep-guard.sh's documented fallback probe (it must never hard-fail at startup), and this
# suite, whose own grep pattern would otherwise match itself.
stray_os="$(grep -ln 'uname -s\|Darwin)\|KIB_OS[^_]*=[[:space:]]*"\{0,1\}darwin' "${HOST_BASH[@]}" \
    2>/dev/null \
    | grep -vE '^(host/portable\.sh|host/sleep-guard\.sh|tests/check/.*\.sh)$' || true)"
if [ -n "$stray_os" ]; then
    fail "OS branching outside host/portable.sh" "$(printf '%s' "$stray_os" | tr '\n' ' ')"
else
    pass "all OS branching stays in host/portable.sh (sleep-guard's fallback probe excepted)"
fi

# The FUSE sidecar is the one topology on both platforms, and exactly these five functions are
# what differ. Each must exist and be defined HERE, so a platform fix cannot quietly grow a
# sixth branch somewhere else. (docs/design-notes/macos.md)
missing=""
for fn in fuse_root_path fuse_root_create fuse_root_destroy fuse_mounted unmount_fuse; do
    grep -q "^$fn() {" host/portable.sh || missing="$missing $fn"
done
if [ -n "$missing" ]; then
    fail "host/portable.sh is missing a FUSE platform shim:$missing" \
        "the sidecar's only OS-sensitive parts live here — a caller must never branch itself"
else
    pass "the five FUSE platform shims are all defined in host/portable.sh"
fi
unset missing fn

# A bind whose destination sits inside another bind aborts the whole `docker run` on Docker
# Desktop (runc resolves the mountpoint through the parent and finds it outside the rootfs).
# The two dir mounts are the ones with children; anything landing inside them must go through
# bind_via_link instead. The /run/host-resolve nest is Linux-only.
nested="$(grep -n -- '-v "[^"]*:\([$]SESSION_CDIR\|[$]SHARED_CDIR\|/home/hostuser/\.claude-[a-z]*\)/' \
    "${HOST_BASH[@]}" 2>/dev/null || true)"
if [ -n "$nested" ]; then
    fail "a bind mount nests inside the session/shared dir mount (Docker Desktop refuses it)" \
        "$(printf '%s' "$nested" | head -3)"
else
    pass "no bind mount nests inside the session/shared dir mounts"
fi

# ── Host-side python ────────────────────────────────────────────────────────
# `kib_py` runs whatever `python3` the host has, and stock macOS ships 3.9
# (`xcode-select --install`). ruff's per-file-target-version + FA102 cover annotations;
# these are the three things it cannot see. kib/guest is exempt — image python only.
section "Portability contract (host-side python, stock macOS python3.9)"

py_bad="$(
    python3 - <<'PY'
import ast
import pathlib

# 3.10+ APIs a modern-python habit reaches for that only fail when the line is *reached*,
# so an import smoke test would pass. Extend when one bites.
BAD_KWARG = {("zip", "strict"), ("dataclass", "slots"), ("dataclass", "kw_only")}
BAD_ATTR = {"pairwise"}


def problems(path: pathlib.Path) -> list[str]:
    src = path.read_text()
    try:
        tree = ast.parse(src, str(path), feature_version=(3, 9))
    except SyntaxError as e:
        return [f"line {e.lineno}: syntax newer than 3.9 ({e.msg})"]
    out = []
    defines = any(isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))
                  for n in tree.body)
    if defines and "from __future__ import annotations" not in src:
        out.append("missing `from __future__ import annotations` (PEP 604 is 3.10+)")
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            fn = node.func
            name = getattr(fn, "id", None) or getattr(fn, "attr", "")
            for kw in node.keywords:
                if (name, kw.arg) in BAD_KWARG:
                    out.append(f"line {node.lineno}: {name}({kw.arg}=…) is 3.10+")
        elif isinstance(node, ast.Attribute) and node.attr in BAD_ATTR:
            out.append(f"line {node.lineno}: {node.attr} is 3.10+")
    return out


for tree_dir in ("kib/host", "kib/shared", "kib/broker"):
    for path in sorted(pathlib.Path(tree_dir).glob("*.py")):
        for msg in problems(path):
            print(f"{path}: {msg}")
PY
)" || py_bad="python3 unavailable or the scan itself failed"

if [ -n "$py_bad" ]; then
    fail "host-side python is not 3.9-clean" "$(printf '%s' "$py_bad" | head -6)"
else
    pass "kib/host + kib/shared + kib/broker parse and import-check clean on python 3.9"
fi
