#!/bin/bash
# End-to-end check of the registry pipeline: scripts/registry.swift signs a registry for a fake
# Valkey package, served locally, and the app's VersionStore must install it and must reject a
# tampered registry and a corrupted download.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'kill "${SERVER_PID:-}" 2>/dev/null || true; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/pkg/bin" "$TMP/site"
PORT=$((20000 + RANDOM % 20000))

printf '#!/bin/sh\necho fake\n' > "$TMP/pkg/bin/valkey-server"
cp "$TMP/pkg/bin/valkey-server" "$TMP/pkg/bin/valkey-cli"
chmod +x "$TMP/pkg/bin/"*
tar -czf "$TMP/site/valkey-9.9.9.tar.gz" -C "$TMP/pkg" bin

# A fake module for this Mac's architecture, and one for the other architecture that mustn't be offered.
mkdir -p "$TMP/mod"
printf 'not really a dylib' > "$TMP/mod/libfake.dylib"; chmod +x "$TMP/mod/libfake.dylib"; echo license > "$TMP/mod/LICENSE"
tar -czf "$TMP/site/fake-1.0.tar.gz" -C "$TMP/mod" libfake.dylib LICENSE
ARCH=$(uname -m); OTHER=$([ "$ARCH" = arm64 ] && echo x86_64 || echo arm64)
meta() { printf '{"id":"%s","name":"fake","version":"%s","title":"Fake","summary":"s","file":"libfake.dylib","valkey":["9.9"],"architectures":["%s"],"minimumMacOS":"13.0"}' "$1" "$2" "$3"; }
meta fake-1.0 1.0 "$ARCH" > "$TMP/fake.json"; meta fake-2.0-other 2.0 "$OTHER" > "$TMP/other.json"

PUBLIC_KEY=$(swift "$ROOT/registry/scripts/registry.swift" keygen "$TMP/key")
swift "$ROOT/registry/scripts/registry.swift" add "$TMP/site/registry.json" 9.9.9 \
    "http://127.0.0.1:$PORT/valkey-9.9.9.tar.gz" "$TMP/site/valkey-9.9.9.tar.gz" >/dev/null
for m in fake other; do
    swift "$ROOT/registry/scripts/registry.swift" add-module "$TMP/site/registry.json" "$TMP/$m.json" \
        "http://127.0.0.1:$PORT/fake-1.0.tar.gz" "$TMP/site/fake-1.0.tar.gz" >/dev/null
done
VALKEY_REGISTRY_PRIVATE_KEY=$(cat "$TMP/key") swift "$ROOT/registry/scripts/registry.swift" sign "$TMP/site/registry.json" >/dev/null

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$TMP/site" >/dev/null 2>&1 &
SERVER_PID=$!
disown
sleep 1

swiftc -parse-as-library -o "$TMP/check" "$ROOT/app/Valkey/VersionStore.swift" "$ROOT/registry/scripts/RegistryCheck.swift"
"$TMP/check" "http://127.0.0.1:$PORT/registry.json" "$PUBLIC_KEY" "$TMP/installed" "$TMP/site"
echo "registry check passed"
