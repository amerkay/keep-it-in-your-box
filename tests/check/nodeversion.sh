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

# The list form is what a monorepo uses; it must be stripped just as thoroughly.
out="$(_nv_kib --node-version=18,20 badverb)"
case "$out" in
    *"unknown verb badverb"*) pass "the --node-version=NN,NN list form is stripped too" ;;
    *) fail "the list form was not stripped" "got: $(printf %s "$out" | head -1)" ;;
esac

# The guest resolver takes ONE version, so the list must collapse to its first entry there while
# every entry still gets cached. Source-level: the split has no observable effect without docker.
# shellcheck disable=SC2016  # these are literal source patterns; expansion would break them
if grep -q "NODE_VERSION=\"\${NODE_VERSION_LIST%% \*}\"" "$KIB_ROOT/bin/kib" \
    && grep -q 'for want in \$NODE_VERSION_LIST' "$KIB_ROOT/host/node.sh"; then
    pass "the list caches every version and runs on the first"
else
    fail "the version list is not split into cache-all + run-first" \
        "either the extra versions are never fetched, or the guest is handed a list it rejects"
fi

out="$(_nv_kib --node-version)"
case "$out" in
    *"needs a value"*) pass "--node-version with no value is refused" ;;
    *) fail "bare --node-version was not refused" "got: $(printf %s "$out" | head -1)" ;;
esac

case "$(_nv_kib help)" in
    *--node-version*) pass "the flag is in the usage table" ;;
    *) fail "kib help does not mention --node-version" "an undiscoverable flag" ;;
esac

# The usage line advertises a set of majors; the cache can hold any of them, so the only thing
# that must hold is that the flag is described in terms of a fetch, not a rebuild.
case "$(_nv_kib help)" in
    *NN*) pass "the usage line names a version placeholder" ;;
    *) fail "kib help does not show --node-version=NN" "the flag's argument is undiscoverable" ;;
esac

# Nothing may be baked: the whole point is that the image carries no Node lines. A NODE_LTS_LINES
# ARG creeping back means /opt/nvm-versions has image content under the cache's mountpoint, which
# the :ro bind would then hide — silently, and differently on a fresh vs an existing container.
if grep -q '^ARG NODE_LTS_LINES=' "$KIB_ROOT/Dockerfile"; then
    fail "the Dockerfile bakes Node lines again" \
        "image content under /opt/nvm-versions is hidden by the cache bind"
else
    pass "the image bakes no Node lines"
fi

# All three sides must name the same path, or the bind lands where nothing reads it.
_nv_store=/opt/nvm-versions
if grep -q "$_nv_store" "$KIB_ROOT/Dockerfile" \
    && grep -q "$_nv_store" "$KIB_ROOT/guest/entrypoint/docker-entrypoint.sh" \
    && grep -q "$_nv_store" "$KIB_ROOT/host/node.sh"; then
    pass "Dockerfile, entrypoint and host/node.sh agree on $_nv_store"
else
    fail "the store path differs between the Dockerfile, entrypoint and host/node.sh" \
        "the cache would be mounted where nothing resolves it"
fi

# ── The cache mount and the fetch ────────────────────────────────
# Unconditional, and NOT gated on --node-version: the bind is a live view, so a version cached
# later by another terminal or project has to appear in containers that already exist. Gating it
# would silently reintroduce "recreate the container to switch Node".
if grep -q 'add_node_cache_args' "$KIB_ROOT/host/lifecycle.sh" \
    && ! grep -B3 'add_node_cache_args' "$KIB_ROOT/host/lifecycle.sh" | grep -q 'NODE_VERSION'; then
    pass "the cache is mounted unconditionally, not gated on --node-version"
else
    fail "the cache mount is missing or gated on \$NODE_VERSION" \
        "a version cached later would not appear in a running container"
fi

# The mount every project gets must be read-only. The populate container is the only writer, and
# a writable shared store is executable content one project hands to another.
if grep -q 'KIB_NODE_CACHE:/opt/nvm-versions:ro' "$KIB_ROOT/host/node.sh"; then
    pass "project containers get the cache :ro"
else
    fail "the project cache mount is not :ro" \
        "one project's box could plant a node binary every other project then executes"
fi

# The populate container must carry no project, no credentials and no broker network.
_nv_fetch="$(sed -n '/^ensure_node_cached()/,/^}/p' "$KIB_ROOT/host/node.sh")"
_nv_leak=""
# shellcheck disable=SC2016  # literal patterns to find in the source, not expansions
for _p in '\$PWD' 'SESSION_BASE' 'SHARED_BASE' 'ANTHROPIC' 'BROKER' '--network'; do
    printf '%s\n' "$_nv_fetch" | grep -q -- "$_p" && _nv_leak="$_nv_leak $_p"
done
if [ -z "$_nv_leak" ]; then
    pass "the populate container mounts no project, credential or broker wiring"
else
    fail "the populate container is not sterile:$_nv_leak" \
        "it runs registry code; it must not be able to reach the project or a credential"
fi

# The image's ENTRYPOINT is docker-entrypoint.sh. Without --entrypoint the fetch script becomes
# an ARGUMENT to it, so the container runs the root session setup and dies on the HOST_UID this
# run deliberately withholds ("Failed to resolve home directory for UID 1000").
if printf '%s\n' "$_nv_fetch" | grep -q -- '--entrypoint'; then
    pass "the populate container bypasses the image entrypoint"
else
    fail "the populate run does not set --entrypoint" \
        "the fetch script becomes an argument to the session entrypoint and never runs"
fi

# Belt and braces, both halves of it: the script is executable like every sibling in guest/bin,
# AND the interpreter is named at the call site. A bind carries the HOST file's mode, so relying
# on the exec bit alone turns a checkout that lost it into "permission denied" at launch.
if [ -x "$KIB_ROOT/guest/bin/node-fetch.sh" ]; then
    pass "node-fetch.sh is executable, like its guest/bin siblings"
else
    fail "guest/bin/node-fetch.sh has lost its exec bit" "the populate container cannot run it"
fi
if printf '%s\n' "$_nv_fetch" | grep -q 'entrypoint bash'; then
    pass "the populate run names its interpreter rather than trusting the mode"
else
    fail "the populate run execs the script directly" \
        "a checkout without the exec bit fails the launch with permission denied"
fi

# Fetching must precede the session, and the image it runs must already exist.
_nv_kibsrc="$KIB_ROOT/bin/kib"
_nv_fetch_ln="$(grep -n '^ensure_node_cached' "$_nv_kibsrc" | head -1 | cut -d: -f1)"
_nv_img_ln="$(grep -n '^build_image_if_missing' "$_nv_kibsrc" | head -1 | cut -d: -f1)"
_nv_run_ln="$(grep -n '^kib_run_session' "$_nv_kibsrc" | head -1 | cut -d: -f1)"
if [ -n "$_nv_fetch_ln" ] && [ -n "$_nv_img_ln" ] && [ -n "$_nv_run_ln" ] \
    && [ "$_nv_fetch_ln" -gt "$_nv_img_ln" ] && [ "$_nv_fetch_ln" -lt "$_nv_run_ln" ]; then
    pass "the fetch runs after the image exists and before the session"
else
    fail "ensure_node_cached is not between build_image_if_missing and kib_run_session" \
        "either the populate image is missing, or the session starts without the version"
fi

# ── The fetch script ─────────────────────────────────────────────
_nv_fs="$KIB_ROOT/guest/bin/node-fetch.sh"
# A cached node runs in every project on this machine. Publishing a checksum is only useful if
# the download is actually compared against it.
if grep -q 'SHASUMS256.txt' "$_nv_fs" && grep -q 'sha256sum -c' "$_nv_fs"; then
    pass "the download is verified against the published checksum"
else
    fail "node-fetch.sh does not checksum what it caches" \
        "an intercepted download would be executed by every project on this machine"
fi

# Unpack in place and an interrupted fetch leaves a half-tree that resolves onto PATH.
# shellcheck disable=SC2016  # literal source patterns
if grep -q 'mktemp -d' "$_nv_fs" && grep -q '^mv "\$TREE"' "$_nv_fs"; then
    pass "the version is renamed in, never unpacked in place"
else
    fail "node-fetch.sh does not install atomically" \
        "an interrupted fetch would leave a partial version that still resolves"
fi

# shellcheck disable=SC2016  # a sed program, not a string to expand
case "$(sed -n 's/^PNPM_TAGS="\${PNPM_TAGS:-\([^}]*\)}".*/\1/p' "$_nv_fs")" in
    latest\ *) pass "PNPM_TAGS is tried newest-first" ;;
    "") fail "no PNPM_TAGS in node-fetch.sh" "a cached line could get no pnpm at all" ;;
    *) fail "PNPM_TAGS does not start with 'latest'" "the newest compatible pnpm would never win" ;;
esac

# Node ${NODE_MAJOR} has no cache entry, so its pnpm is the system-prefix one; newer lines reuse it.
if sed -n '/^RUN npm install -g/,/^$/p' "$KIB_ROOT/Dockerfile" \
    | grep -q '^[[:space:]]*pnpm[[:space:]]*\\\?[[:space:]]*$'; then
    pass "the system prefix still installs pnpm (the default node's copy)"
else
    fail "pnpm was dropped from the system npm install -g" \
        "the default node, and every line that could reuse it, would have no pnpm"
fi

# ── Per-project stickiness ───────────────────────────────────────
# The store/lookup pair, run for real against a throwaway table. Each call is a subshell: the
# prefix-assignment form (VAR=x func) does NOT survive the call, so the vars are set outright.
_nv_conf="$(mktemp -d)/node-versions"
_nv_sticky() { # <pwd> <flag list>  -> "list|default"
    (
        # shellcheck disable=SC2034  # both are read by the sourced host/node.sh
        KIB_CONFIG="${_nv_conf%/*}/config"
        # shellcheck disable=SC2034  # ditto
        KIB_NODE_CONF="$_nv_conf"
        # core.sh first: node.sh's per-project pin is the shared sticky_get/sticky_set table.
        # shellcheck source=/dev/null
        . "$KIB_ROOT/host/core.sh"
        # shellcheck source=/dev/null
        . "$KIB_ROOT/host/node.sh"
        PWD="$1"
        NODE_VERSION_LIST="$2"
        node_versions_resolve 2>/dev/null
        node_versions_remember
        printf '%s|%s' "$NODE_VERSION_LIST" "$NODE_VERSION"
    )
}

_nv_sticky /p/one "18 20" >/dev/null
_nv_sticky /p/two "22" >/dev/null
_nv_sticky /p/one "24" >/dev/null # re-pin: must replace the line, not append a second

if [ "$(grep -c '^/p/one=' "$_nv_conf" 2>/dev/null || echo 0)" = 1 ]; then
    pass "re-pinning a project rewrites its line instead of appending"
else
    fail "the sticky table gained a duplicate line for one project" \
        "which version wins would depend on read order"
fi

is "a later launch with no flag gets the project's remembered list" "24|24" "$(_nv_sticky /p/one "")"
is "stickiness is per project, not global" "22|22" "$(_nv_sticky /p/two "")"
is "a project that never pinned one stays on the system node" "|" "$(_nv_sticky /p/never-seen "")"
is "an explicit flag overrides what was remembered" "20|20" "$(_nv_sticky /p/one 20)"

# The bug this ordering exists for: the pin used to be written by node_versions_resolve, before
# the fetch ran. A failed fetch then pinned the project, so every later launch retried the same
# broken fetch and died — recoverable only by hand-editing the table.
(
    # shellcheck disable=SC2034  # both are read by the sourced host/node.sh
    KIB_CONFIG="${_nv_conf%/*}/config"
    # shellcheck disable=SC2034  # ditto
    KIB_NODE_CONF="$_nv_conf"
    # shellcheck source=/dev/null
    . "$KIB_ROOT/host/core.sh"
    # shellcheck source=/dev/null
    . "$KIB_ROOT/host/node.sh"
    PWD=/p/fetch-failed
    NODE_VERSION_LIST="99"
    node_versions_resolve 2>/dev/null # and then die, as ensure_node_cached would
) || true
if grep -q '^/p/fetch-failed=' "$_nv_conf" 2>/dev/null; then
    fail "a version was pinned before the fetch ran" \
        "a failed fetch bricks the project: every later launch retries it and dies"
else
    pass "resolving alone pins nothing — only a completed fetch does"
fi

# Same guarantee, structurally: the write must follow the fetch in bin/kib.
_nv_rem_ln="$(grep -n '^node_versions_remember' "$KIB_ROOT/bin/kib" | head -1 | cut -d: -f1)"
if [ -n "$_nv_rem_ln" ] && [ -n "$_nv_fetch_ln" ] && [ "$_nv_rem_ln" -gt "$_nv_fetch_ln" ]; then
    pass "the pin is written after ensure_node_cached, not before"
else
    fail "node_versions_remember does not follow ensure_node_cached" \
        "a failed fetch would pin the project and lock the user out of it"
fi

# It must live beside the host config, which is NOT mounted into any container: a box-writable
# file deciding the next session's interpreter would be a decision the box makes for the user.
if grep -q 'KIB_NODE_CONF=.*KIB_CONFIG' "$KIB_ROOT/host/node.sh"; then
    pass "the sticky table is derived from \$KIB_CONFIG (host-only, unmounted)"
else
    fail "the sticky table is not anchored to the host config dir" \
        "if it lands somewhere the box can write, a session picks its own interpreter"
fi

rm -rf "${_nv_conf%/*}"

# ── nvm inside a session ─────────────────────────────────────────
# `nvm` is a shell function, so it exists only in a shell that sourced it. Claude's tools run
# `bash -c` — non-interactive — where the only hook bash offers is $BASH_ENV. Without it the
# function is missing exactly where a session needs it, which is what "nvm: command not found"
# was. Persistence is then nvm's own (`nvm alias default N`); kib adds nothing.
if grep -q '^ENV BASH_ENV=/etc/kib-nvm.sh' "$KIB_ROOT/Dockerfile"; then
    pass "nvm reaches non-interactive shells via BASH_ENV"
else
    fail "BASH_ENV is not set to the nvm init file" \
        "nvm would exist in a terminal and be missing from every tool call"
fi

# One file for both kinds of shell, or the two drift and a terminal behaves unlike a tool call.
_nv_init="$(grep -c '/etc/kib-nvm.sh' "$KIB_ROOT/Dockerfile")"
if [ "$_nv_init" -ge 3 ]; then
    pass "interactive and non-interactive shells source the same nvm init file"
else
    fail "the nvm init file is not shared by bashrc and BASH_ENV" \
        "a terminal and a tool call would see different nvm state"
fi

# The only path that reaches Claude's own tool calls: they replay a snapshot captured from
# ~/.bashrc, not any rc file of their own. Without this seeding, `nvm` is missing from every tool
# call while node/npm work fine off PATH — which is exactly the bug this fixed.
if grep -q 'bashrc' "$KIB_ROOT/guest/entrypoint/docker-entrypoint.sh" \
    && grep -q '/etc/kib-nvm.sh' "$KIB_ROOT/guest/entrypoint/docker-entrypoint.sh"; then
    pass "the entrypoint seeds ~/.bashrc with the nvm init"
else
    # shellcheck disable=SC2088  # prose for the reader, not a path to expand
    fail "~/.bashrc is not seeded" \
        "Claude's shell snapshot is built from it, so nvm would be missing from every tool call"
fi

# Lazy, not a full source: Claude Code serialises every captured function into the snapshot as a
# base64 eval replayed on EVERY Bash call. nvm.sh defines 118 of them (measured).
if grep -q 'unset -f nvm' "$KIB_ROOT/Dockerfile"; then
    pass "the nvm init is a lazy wrapper, not a full source"
else
    fail "the nvm init sources nvm.sh eagerly" \
        "118 functions land in the shell snapshot and are replayed on every Bash tool call"
fi

# The seam that lets an in-session switch reach the NEXT command: a PATH entry whose TARGET can
# change, since the snapshot's PATH string itself is frozen at session start.
if grep -q 'KIB_NODE_CURRENT' "$KIB_ROOT/guest/entrypoint/docker-entrypoint.sh" \
    && grep -q 'KIB_NODE_CURRENT/bin' "$KIB_ROOT/guest/entrypoint/docker-entrypoint.sh"; then
    pass "the repointable current-version symlink is on PATH"
else
    fail "KIB_NODE_CURRENT is not on PATH" \
        "nvm use would apply to its own command and be gone by the next one"
fi

# Only `use` may repoint it. NVM_BIN is unset for ls/current, which would read as "system" and
# silently undo the selection.
if grep -q 'NVM_BIN' "$KIB_ROOT/Dockerfile" && grep -q "use)" "$KIB_ROOT/Dockerfile"; then
    pass "only nvm use repoints the symlink"
else
    fail "the nvm wrapper does not gate the repoint on \`use\`" \
        "nvm ls would clear the selected version"
fi

# Completion is interactive-only; in BASH_ENV it is dead weight on every bash the agent runs.
if grep -q "bash_completion" "$KIB_ROOT/Dockerfile" \
    && ! sed -n '/> \/etc\/kib-nvm.sh/q;/printf/,$p' "$KIB_ROOT/Dockerfile" \
    | grep -q 'bash_completion.*kib-nvm'; then
    pass "bash completion stays out of the non-interactive path"
else
    fail "nvm bash completion is loaded non-interactively" "it costs every bash call for nothing"
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

    # The resolver treats "the major we are already on" as a no-op, reading it from `node
    # --version`. Left ambient, this suite passes or fails depending on what Node the session
    # running it happens to be on — it broke the moment a session launched with 18. Pin it.
    mkdir -p "$_nv_dir/fakebin"
    printf '#!/bin/sh\necho v26.5.0\n' >"$_nv_dir/fakebin/node"
    chmod +x "$_nv_dir/fakebin/node"
    _nv_resolve() {
        PATH="$_nv_dir/fakebin:$PATH" sh -c '. "$1/fn.sh"; resolve_node_version "$2"' \
            _ "$_nv_dir" "$1" 2>/dev/null
    }

    is "a bare major resolves to the baked build" \
        "$_nv_dir/store/v18.20.8/bin" "$(_nv_resolve 18)"
    is "a full version resolves to the same dir" \
        "$_nv_dir/store/v20.20.2/bin" "$(_nv_resolve v20.20.2)"
    # Empty output = "leave PATH alone": the system node already is that major.
    is "system is a no-op" "" "$(_nv_resolve system)"
    # Same no-op, by number: asking for the version we are already on must not prepend anything.
    is "the ambient major is a no-op too" "" "$(_nv_resolve 26)"

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

    # ORDER: the in-session symlink must outrank the launch flag's fixed directory, or
    # `nvm use` repoints the link, reports success, and PATH still resolves the launch version.
    # Run for real — this is the one property that cannot be eyeballed from the source.
    _nv_order="$(
        HOME="$_nv_dir" USER_HOME="$_nv_dir" KIB_SESSION_TAG=t \
            KIB_NODE_VERSION=18 KIB_PREPEND_PATH="" \
            PATH="$_nv_dir/fakebin:$PATH" \
            sh -c '. "$1/fn.sh"; apply_node_version; printf "%s" "$KIB_PREPEND_PATH"' \
            _ "$_nv_dir" 2>/dev/null
    )"
    case "$_nv_order" in
        "$_nv_dir/.nvm/current.t/bin:"*"v18.20.8/bin"*)
            pass "the in-session symlink outranks the launch flag on PATH"
            ;;
        *)
            fail "PATH order puts the launch version ahead of the nvm-use symlink" \
                "got: $_nv_order"
            ;;
    esac

    # A version that is not baked must fail loudly: silently handing back the system node would
    # let a session believe it is on 22 while running 26.
    if _nv_resolve 99 >/dev/null 2>&1; then
        fail "an unbaked version resolved anyway" "the session would silently get the system node"
    else
        pass "an unbaked version fails instead of falling back to the system node"
    fi
fi

rm -rf "$_nv_dir"
unset _nv_order _nv_init _nv_conf _nv_rem_ln _nv_dir _nv_store _nv_bad _m _v _b out
unset _nv_fetch _nv_leak _p _nv_kibsrc _nv_fetch_ln _nv_img_ln _nv_run_ln _nv_fs
