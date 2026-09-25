#!/bin/bash
# Builds a universal (arm64 + x86_64) Valkey <version> and packages it for the registry as
#   registry/dist/valkey-<version>-macos-universal.tar.gz  →  bin/valkey-server, bin/valkey-cli, COPYING
# The source is verified against the hash Valkey publishes in valkey-io/valkey-hashes.
# CODESIGN_IDENTITY: signing identity (default "-", ad-hoc).
set -euo pipefail
VERSION="${1:?usage: $0 <version>}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || { echo "bad version: $VERSION"; exit 1; }
REGISTRY="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REGISTRY/valkey-src"
IDENTITY="${CODESIGN_IDENTITY:--}"

SHA=$(curl -fsSL https://raw.githubusercontent.com/valkey-io/valkey-hashes/main/README |
      awk -v f="valkey-$VERSION.tar.gz" '$1 == "hash" && $2 == f && $3 == "sha256" { print $4 }')
[ -n "$SHA" ] || { echo "Valkey $VERSION has no published hash in valkey-io/valkey-hashes"; exit 1; }

for arch in arm64 x86_64; do
    make -C "$SRC" VERSION="$VERSION" SOURCE_SHA256="$SHA" ARCH="$arch"
done

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/bin"
for bin in valkey-server valkey-cli; do
    lipo -create "$SRC/build/$VERSION/arm64/bin/$bin" "$SRC/build/$VERSION/x86_64/bin/$bin" -output "$STAGE/bin/$bin"
    if [ "$IDENTITY" = - ]; then
        codesign --force --sign - "$STAGE/bin/$bin"
    else
        codesign --force --sign "$IDENTITY" --options runtime --timestamp "$STAGE/bin/$bin"
    fi
done
# Valkey is BSD-3-licensed; binary redistribution must carry its license.
cp "$SRC/build/$VERSION/arm64/valkey-$VERSION/COPYING" "$STAGE/"

mkdir -p "$REGISTRY/dist"
OUT="$REGISTRY/dist/valkey-$VERSION-macos-universal.tar.gz"
COPYFILE_DISABLE=1 tar -czf "$OUT" -C "$STAGE" bin COPYING
echo "$OUT"
