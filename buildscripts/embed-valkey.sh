#!/bin/bash
# Xcode build phase: builds every Valkey version in valkey-src/Makefile for each target
# arch and embeds universal binaries in Valkey.app/Contents/Versions/<major.minor>/bin.
set -euo pipefail
SRC="$SRCROOT/valkey-src"
DEST="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Versions"
rm -rf "$DEST"

for version in $(make -s -C "$SRC" print-versions); do
    bindir="$DEST/${version%.*}/bin"
    mkdir -p "$bindir"
    for arch in $ARCHS; do
        make -C "$SRC" VERSION="$version" ARCH="$arch"
    done

    for bin in valkey-server valkey-cli; do
        slices=()
        for arch in $ARCHS; do slices+=("$SRC/build/$version/$arch/bin/$bin"); done
        lipo -create "${slices[@]}" -output "$bindir/$bin"

        # Nested executables must be signed before Xcode signs the app bundle.
        if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
            flags=()
            if [ "${ENABLE_HARDENED_RUNTIME:-NO}" = YES ] && [ "$EXPANDED_CODE_SIGN_IDENTITY" != - ]; then
                flags=(--options runtime --timestamp)
            fi
            codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" ${flags[@]+"${flags[@]}"} "$bindir/$bin"
        fi
    done
done
