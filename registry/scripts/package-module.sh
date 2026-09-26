#!/bin/bash
# Builds a Valkey module for the registry. For each build variant it compiles a universal .dylib,
# tests it (check-module.sh) against the newest registry Valkey of every minor line it will be listed
# for, and packages it with its license:
#   registry/dist/modules/<id>.tar.gz   →  <module file>, LICENSE (+ notices)
#   registry/dist/modules/<id>.json     →  metadata for `registry.swift add-module`
#
#   registry/scripts/package-module.sh <json|bloom> <module-version>
#
# Needs cmake + ninja (json) or rustup with the x86_64-apple-darwin target (bloom).
# Adding a module: a recipe below, a build() case, and a check in check-module.sh.
# Modules publish no source hashes; the source is the official repo at the release tag, and the
# commit it resolved to is recorded in the metadata.
set -euo pipefail
NAME="${1:?usage: $0 <json|bloom> <module-version>}"
VERSION="${2:?module version}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || { echo "bad version: $VERSION"; exit 1; }
REGISTRY="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$REGISTRY/valkey-src/build/modules/$NAME-$VERSION"
OUT="$REGISTRY/dist/modules"
export MACOSX_DEPLOYMENT_TARGET=13.0
# Build only from what each module vendors, never from Homebrew or /usr/local.
export CMAKE_TOOLCHAIN_FILE="$REGISTRY/scripts/hermetic.cmake"
PATH=$(tr ':' '\n' <<<"$PATH" | grep -vE '^(/opt/homebrew|/usr/local)' | paste -sd: -)
ARCHS="arm64 x86_64"
mkdir -p "$WORK" "$OUT"

# Recipe: VARIANTS entries are "id|first Valkey line|last line (empty: newest)|build option".
case "$NAME" in
json)
    REPO=https://github.com/valkey-io/valkey-json.git
    FILE=libjson.dylib TITLE="JSON" LICENSES="LICENSE"
    SUMMARY="Native JSON documents with JSONPath queries (JSON.SET, JSON.GET, …)."
    VARIANTS=("json-$VERSION|8.0||") ;;
bloom)
    REPO=https://github.com/valkey-io/valkey-bloom.git
    FILE=libvalkey_bloom.dylib TITLE="Bloom" LICENSES="LICENSE"
    SUMMARY="Scalable Bloom filters for fast membership checks (BF.ADD, BF.EXISTS, …)."
    # The default build crashes Valkey 8.0 on first use; 8.0 needs its own build.
    VARIANTS=("bloom-$VERSION-valkey8.0|8.0|8.0|valkey_8_0" "bloom-$VERSION|8.1||") ;;
*)
    echo "unknown module: $NAME"; exit 1 ;;
esac

SRC="$WORK/src"
[ -d "$SRC" ] || git clone -q -c advice.detachedHead=false --depth 1 --branch "$VERSION" "$REPO" "$SRC"
COMMIT=$(git -C "$SRC" rev-parse HEAD)

# Builds one architecture of one variant; prints the path of the built module.
build() {
    local arch="$1" option="$2" dir
    case "$NAME" in
    json)
        dir="$WORK/json-$arch"
        [ -d "$dir" ] || cp -R "$SRC" "$dir"
        # rapidjson's x86 fast path needs SSE4.2, which every Intel Mac running macOS 13 has.
        (cd "$dir" && CMAKE_OSX_ARCHITECTURES=$arch CFLAGS="$([ "$arch" = x86_64 ] && echo -msse4.2)" \
            ./build.sh >"$WORK/build-$arch.log" 2>&1) || { tail -20 "$WORK/build-$arch.log" >&2; return 1; }
        echo "$dir/build/src/$FILE" ;;
    bloom)
        local triple; triple=$([ "$arch" = arm64 ] && echo aarch64-apple-darwin || echo x86_64-apple-darwin)
        (cd "$SRC" && cargo build -q --release --target "$triple" --target-dir "$WORK/target-${option:-default}" \
            ${option:+--features "$option"} >"$WORK/build-$arch-${option:-default}.log" 2>&1) \
            || { tail -20 "$WORK/build-$arch-${option:-default}.log" >&2; return 1; }
        echo "$WORK/target-${option:-default}/$triple/release/$FILE" ;;
    esac
}

# Newest registry version of a Valkey minor line, downloaded and checksum-verified; prints its bin dir.
valkey_bin() {
    local line="$1" info version url sha dir
    info=$(python3 - "$REGISTRY/registry.json" "$line" <<'EOF'
import json, sys
versions = [v for v in json.load(open(sys.argv[1]))["versions"] if v["version"].rsplit(".", 1)[0] == sys.argv[2]]
v = max(versions, key=lambda v: [int(x) for x in v["version"].split(".")])
print(v["version"], v["url"], v["sha256"])
EOF
    )
    read -r version url sha <<<"$info"
    dir="$REGISTRY/valkey-src/build/modules/valkey-$version"
    if [ ! -x "$dir/bin/valkey-server" ]; then
        mkdir -p "$dir"
        curl -fsSL -o "$dir.tar.gz" "$url"
        echo "$sha  $dir.tar.gz" | shasum -a 256 -c - >/dev/null
        tar xzf "$dir.tar.gz" -C "$dir" && rm "$dir.tar.gz"
    fi
    echo "$dir/bin"
}

# Valkey minor lines in the registry, oldest first.
LINES=$(python3 -c 'import json,sys; print(" ".join(sorted({v["version"].rsplit(".",1)[0] for v in json.load(open(sys.argv[1]))["versions"]}, key=lambda l: [int(x) for x in l.split(".")])))' "$REGISTRY/registry.json")
newer_or_same() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

for variant in "${VARIANTS[@]}"; do
    IFS='|' read -r ID FIRST LAST OPTION <<<"$variant"
    SELECTED=()
    for line in $LINES; do
        newer_or_same "$line" "$FIRST" || continue
        [ -n "$LAST" ] && ! newer_or_same "$LAST" "$line" && continue
        SELECTED+=("$line")
    done
    [ ${#SELECTED[@]} -gt 0 ] || { echo "$ID: no registry Valkey lines from $FIRST${LAST:+ to $LAST}"; exit 1; }
    echo "== $ID for Valkey ${SELECTED[*]}"

    STAGE="$WORK/stage-$ID"
    rm -rf "$STAGE" && mkdir -p "$STAGE"
    slices=()
    for arch in $ARCHS; do slices+=("$(build "$arch" "$OPTION")"); done
    lipo -create "${slices[@]}" -output "$STAGE/$FILE"
    codesign --force --sign - "$STAGE/$FILE"
    for license in $LICENSES; do cp "$SRC/$license" "$STAGE/"; done

    for line in "${SELECTED[@]}"; do
        "$REGISTRY/scripts/check-module.sh" "$NAME" "$STAGE/$FILE" "$(valkey_bin "$line")"
    done

    COPYFILE_DISABLE=1 tar -czf "$OUT/$ID.tar.gz" -C "$STAGE" "$FILE" $LICENSES
    python3 - "$OUT/$ID.json" <<EOF
import json, sys
json.dump({"id": "$ID", "name": "$NAME", "version": "$VERSION", "title": "$TITLE", "summary": "$SUMMARY",
           "file": "$FILE", "valkey": "${SELECTED[*]}".split(), "architectures": "$ARCHS".split(),
           "minimumMacOS": "$MACOSX_DEPLOYMENT_TARGET", "sourceCommit": "$COMMIT"}, open(sys.argv[1], "w"), indent=2)
EOF
    echo "   → $OUT/$ID.tar.gz"
done
