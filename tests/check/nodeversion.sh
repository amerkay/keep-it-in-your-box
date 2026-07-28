#!/usr/bin/env bash
# Sourced by tests/check.sh — the `kib --node-version=NN` path, host side.
#
# No docker here, so the two halves are checked where they live: the launcher's pre-verb flag
# parse (bin/kib), and the guest resolver (guest/entrypoint/docker-entrypoint.sh), which is
# extracted and run against a fake store. The resolver is the security-relevant half — its input
# crosses from host argv into a path lookup.

# shellcheck source=SCRIPTDIR/_guard.sh
. "${BASH_SOURCE%/*}/_guard.sh" # sourced by tests/check.sh, never run directly

section "Node version flag (bin/kib, entrypoint resolver)"

_nv_kib() { KIB_CONFIG="$(mktemp -u)" bash "$KIB_ROOT/bin/kib" "$@" 2>&1; }

# The verb table rejects any unknown first token, so a flag that is not stripped BEFORE it would
# be reported as the bad verb — and the real one would never be seen.
out="$(_nv_kib --node-version=18 badverb)"
case "$out" in
    *"unknown verb badverb"*) pass "--node-version is stripped before verb dispatch" ;;
    *) fail "--node-version=18 badverb did not report badverb" "got: $(printf %s "$out" | head -1)" ;;
esac

out="$(_nv_kib --node-version)"
case "$out" in
    *"needs a value"*) pass "--node-version with no value is refused" ;;
    *) fail "bare --node-version was not refused" "got: $(printf %s "$out" | head -1)" ;;
esac

case "$(_nv_kib help)" in
    *--node-version*) pass "the flag is in the usage table" ;;
    *) fail "kib help does not mention --node-version" "an undiscoverable flag" ;;
esac

# Drift: the majors the image bakes and the ones the usage line advertises must agree.
_nv_lines="$(sed -n 's/^ARG NODE_LTS_LINES="\([^"]*\)".*/\1/p' "$KIB_ROOT/Dockerfile")"
if [ -z "$_nv_lines" ]; then
    fail "no ARG NODE_LTS_LINES in the Dockerfile" "nothing is baked; the flag can only no-op"
else
    _nv_missing=""
    for _m in $_nv_lines; do
        grep -q -- "--node-version=NN.*$_m" "$KIB_ROOT/bin/kib" || _nv_missing="$_nv_missing $_m"
    done
    if [ -z "$_nv_missing" ]; then
        pass "baked majors ($_nv_lines) all appear in kib's usage line"
    else
        fail "baked but undocumented majors:$_nv_missing" "kib help would advertise the wrong set"
    fi
fi

# Both halves must name the same store, or the symlink points where nothing was baked.
_nv_store=/opt/nvm-versions
if grep -q "$_nv_store" "$KIB_ROOT/Dockerfile" \
    && grep -q "$_nv_store" "$KIB_ROOT/guest/entrypoint/docker-entrypoint.sh"; then
    pass "Dockerfile and entrypoint agree on $_nv_store"
else
    fail "the baked store path differs between Dockerfile and entrypoint" \
        "the seeded symlink would point at nothing"
fi

# ── Per-line pnpm ────────────────────────────────────────────────
# The only global with a hard node floor, so each baked line carries its own. It has to be
# installed while the store is still at $NVM_DIR/versions/node — after the mv, `npm install -g`
# would land in a prefix no session ever sees, and the breakage is silent until someone runs pnpm.
_nv_bake="$(sed -n '/^ARG NODE_LTS_LINES=/,/^$/p' "$KIB_ROOT/Dockerfile")"
_nv_pnpm_ln="$(printf '%s\n' "$_nv_bake" | grep -n -- '--engine-strict' | head -1 | cut -d: -f1)"
_nv_mv_ln="$(printf '%s\n' "$_nv_bake" | grep -n 'mv .*versions/node' | head -1 | cut -d: -f1)"
if [ -z "$_nv_pnpm_ln" ]; then
    fail "the baked lines get no pnpm of their own" \
        "nvm use 18 would fall through to the system pnpm, which crashes below node 22.13"
elif [ -n "$_nv_mv_ln" ] && [ "$_nv_pnpm_ln" -gt "$_nv_mv_ln" ]; then
    fail "pnpm is installed after the store moves out of \$NVM_DIR" \
        "it lands in a prefix no session sees; pnpm stays broken and nothing says so"
else
    pass "each baked line installs its own pnpm, before the store moves"
fi

# Newest-first, or every line silently gets the oldest pnpm that any of them can run.
case "$(sed -n 's/^ARG PNPM_TAGS="\([^"]*\)".*/\1/p' "$KIB_ROOT/Dockerfile")" in
    latest\ *) pass "PNPM_TAGS is tried newest-first" ;;
    "") fail "no ARG PNPM_TAGS in the Dockerfile" "the per-line pnpm install has no tag list" ;;
    *) fail "PNPM_TAGS does not start with 'latest'" "the newest compatible pnpm would never win" ;;
esac

# Node ${NODE_MAJOR} has no baked dir to hold a copy, so its pnpm is the system-prefix one.
if sed -n '/^RUN npm install -g/,/^$/p' "$KIB_ROOT/Dockerfile" \
    | grep -q '^[[:space:]]*pnpm[[:space:]]*\\\?[[:space:]]*$'; then
    pass "the system prefix still installs pnpm (the default node's copy)"
else
    fail "pnpm was dropped from the system npm install -g" \
        "the default node, and any unbaked version, would have no pnpm at all"
fi

# ── The resolver, run for real against a fake store ──────────────
# Extracted rather than sourced: the entrypoint executes on source. If the markers move, the
# extraction comes back empty and this fails loudly instead of silently testing nothing.
_nv_dir="$(mktemp -d)"
sed -n '/^resolve_node_version()/,/^}/p;/^apply_node_version()/,/^}/p' \
    "$KIB_ROOT/guest/entrypoint/docker-entrypoint.sh" \
    | sed "s#$_nv_store#$_nv_dir/store#g" >"$_nv_dir/fn.sh"

if ! grep -q 'rnv_major' "$_nv_dir/fn.sh"; then
    fail "could not extract resolve_node_version from the entrypoint" \
        "the section markers moved; this whole block tests nothing"
else
    for _v in 18.20.8 20.20.2; do
        mkdir -p "$_nv_dir/store/v$_v/bin"
        printf '#!/bin/sh\necho fake\n' >"$_nv_dir/store/v$_v/bin/node"
        chmod +x "$_nv_dir/store/v$_v/bin/node"
    done

    _nv_resolve() { sh -c '. "$1/fn.sh"; resolve_node_version "$2"' _ "$_nv_dir" "$1" 2>/dev/null; }

    is "a bare major resolves to the baked build" \
        "$_nv_dir/store/v18.20.8/bin" "$(_nv_resolve 18)"
    is "a full version resolves to the same dir" \
        "$_nv_dir/store/v20.20.2/bin" "$(_nv_resolve v20.20.2)"
    # Empty output = "leave PATH alone": the system node already is that major.
    is "system is a no-op" "" "$(_nv_resolve system)"

    # Anything that is not a version must be refused BEFORE it reaches a path lookup. These are
    # the shapes that would otherwise traverse out of the store or ride a command substitution.
    _nv_bad=0
    # shellcheck disable=SC2016  # the literal strings ARE the test — nothing should expand
    for _b in '../../etc' '18;id' '$(id)' 'lts/*' '' '18 20' '/absolute'; do
        if _nv_resolve "$_b" >/dev/null 2>&1; then _nv_bad=1; fi
    done
    if [ "$_nv_bad" = 0 ]; then
        pass "path-traversal and shell-metacharacter versions are all refused"
    else
        fail "resolve_node_version accepted a non-version" "argv reaches a path lookup unchecked"
    fi

    # A version that is not baked must fail loudly: silently handing back the system node would
    # let a session believe it is on 22 while running 26.
    if _nv_resolve 99 >/dev/null 2>&1; then
        fail "an unbaked version resolved anyway" "the session would silently get the system node"
    else
        pass "an unbaked version fails instead of falling back to the system node"
    fi
fi

rm -rf "$_nv_dir"
unset _nv_dir _nv_lines _nv_missing _nv_store _nv_bad _m _v _b out
unset _nv_bake _nv_pnpm_ln _nv_mv_ln
