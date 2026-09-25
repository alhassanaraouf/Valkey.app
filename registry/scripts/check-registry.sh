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

PUBLIC_KEY=$(swift "$ROOT/registry/scripts/registry.swift" keygen "$TMP/key")
swift "$ROOT/registry/scripts/registry.swift" add "$TMP/site/registry.json" 9.9.9 \
    "http://127.0.0.1:$PORT/valkey-9.9.9.tar.gz" "$TMP/site/valkey-9.9.9.tar.gz" >/dev/null
VALKEY_REGISTRY_PRIVATE_KEY=$(cat "$TMP/key") swift "$ROOT/registry/scripts/registry.swift" sign "$TMP/site/registry.json" >/dev/null

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$TMP/site" >/dev/null 2>&1 &
SERVER_PID=$!
disown
sleep 1

swiftc -parse-as-library -o "$TMP/check" "$ROOT/app/Valkey/VersionStore.swift" "$ROOT/registry/scripts/RegistryCheck.swift"
"$TMP/check" "http://127.0.0.1:$PORT/registry.json" "$PUBLIC_KEY" "$TMP/installed" "$TMP/site"
echo "registry check passed"
