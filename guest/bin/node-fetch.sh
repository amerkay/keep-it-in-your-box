#!/usr/bin/env bash
# Populate one Node version into the user-level cache. Runs in the STERILE container host/node.sh
# starts: no project, no credentials, no broker network — only the cache dir, rw.
#
# In a container rather than on the host because the pnpm step runs registry JS, which kib does
# not do host-side; it also makes `uname -m` the arch that will really run the binary.
#
# argv: <major|vX.Y.Z>   Writes /store/vX.Y.Z. Idempotent.
set -euo pipefail

DIST=https://nodejs.org/dist
STORE=/store
WANT="${1:?usage: node-fetch.sh <major|vX.Y.Z>}"
# Newest-first, so a future pnpm major needs no edit. Only consulted when the image's pnpm cannot
# run under the fetched node.
PNPM_TAGS="${PNPM_TAGS:-latest latest-11 latest-10 latest-9}"

die() {
    echo "✗ node-fetch: $*" >&2
    exit 1
}

# Shape-checked before it reaches a URL or a path: this argument originates in host argv.
case "$WANT" in
    v[0-9]* | [0-9]*) ;;
    *) die "'$WANT' is not a version." ;;
esac
case "$WANT" in
    *[!0-9.v]*) die "'$WANT' is not a version." ;;
esac

case "$WANT" in
    *.*) VERSION="v${WANT#v}" ;;
    *)
        # Bare major: index.json is newest-first, so the first hit on the line is that line's latest.
        VERSION="$(curl -fsSL "$DIST/index.json" \
            | node -e '
                let s = "";
                process.stdin.on("data", d => (s += d)).on("end", () => {
                    const want = Number(process.argv[1]);
                    const hit = JSON.parse(s).find(r => Number(r.version.slice(1).split(".")[0]) === want);
                    if (hit) console.log(hit.version);
                });' "${WANT#v}")" || die "could not reach $DIST/index.json"
        [ -n "$VERSION" ] || die "no Node release found on line ${WANT#v}."
        ;;
esac

[ ! -x "$STORE/$VERSION/bin/node" ] || {
    echo "node-fetch: $VERSION already cached."
    exit 0
}

case "$(uname -m)" in
    x86_64) ARCH=x64 ;;
    aarch64 | arm64) ARCH=arm64 ;;
    *) die "unsupported architecture $(uname -m)." ;;
esac
TARBALL="node-$VERSION-linux-$ARCH.tar.xz"

# Staged in a temp dir and renamed in at the end, so an interrupted fetch cannot leave a partial
# version that resolve_node_version would happily put on PATH.
TMP="$(mktemp -d "$STORE/.tmp.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

echo "node-fetch: downloading $TARBALL …"
curl -fsSL -o "$TMP/$TARBALL" "$DIST/$VERSION/$TARBALL" \
    || die "download failed for $VERSION ($ARCH). Is it a real release?"

# Every project on this machine will run this binary: prove it is the published one.
curl -fsSL "$DIST/$VERSION/SHASUMS256.txt" >"$TMP/SHASUMS256.txt" \
    || die "could not fetch checksums for $VERSION."
(cd "$TMP" && grep " $TARBALL\$" SHASUMS256.txt | sha256sum -c -) >/dev/null 2>&1 \
    || die "CHECKSUM MISMATCH for $TARBALL — refusing to cache it."

tar -xJf "$TMP/$TARBALL" -C "$TMP"
TREE="$TMP/node-$VERSION-linux-$ARCH"
[ -x "$TREE/bin/node" ] || die "the tarball for $VERSION has no bin/node."

# include/ is ~60 MB of v8 + openssl headers; node-gyp downloads its own and only reads a prefix
# include/ when passed --nodedir. Stripping costs native C++ frames in a profiler, nothing else.
rm -rf "$TREE/include" "$TREE/share/doc" "$TREE/share/man" "$TREE/CHANGELOG.md" "$TREE/README.md"
strip "$TREE/bin/node" 2>/dev/null || true

# pnpm declares a hard node floor (11.x needs >=22.13) and CRASHES below it, so an old line needs
# its own copy. yarn/tsx/ts-node do not — they follow whichever node PATH resolves.
if PATH="$TREE/bin:$PATH" pnpm --version >/dev/null 2>&1; then
    echo "node-fetch: the image's pnpm runs under $VERSION; not duplicating it."
else
    for t in $PNPM_TAGS; do
        PATH="$TREE/bin:$PATH" npm install -g --engine-strict --prefix "$TREE" "pnpm@$t" \
            >/dev/null 2>&1 && break
    done
    PATH="$TREE/bin:$PATH" pnpm --version >/dev/null 2>&1 \
        || die "no pnpm major runs under $VERSION (tried: $PNPM_TAGS)."
    echo "node-fetch: bundled pnpm $(PATH="$TREE/bin:$PATH" pnpm --version) for $VERSION."
fi

chmod -R a+rX "$TREE"
mv "$TREE" "$STORE/$VERSION" 2>/dev/null || [ -x "$STORE/$VERSION/bin/node" ] \
    || die "could not install $VERSION into the cache."

echo "node-fetch: cached $VERSION ($(du -sh "$STORE/$VERSION" | cut -f1))."
