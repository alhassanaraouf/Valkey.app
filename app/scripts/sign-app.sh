#!/bin/bash
# Re-signs Valkey.app with a stable identity (the release workflow's self-signed certificate), so every
# release has the same designated requirement and Keychain's "Always Allow" survives updates. Ad-hoc
# signatures identify each build by its hash, so macOS asked for the Keychain password after every update.
# Signs nested code inside-out, keeping each part's entitlements and flags (--deep drops them).
# Usage: app/scripts/sign-app.sh Valkey.app "Valkey.app Self-Signed" [keychain]
set -euo pipefail
APP="$1"; IDENTITY="$2"; KEYCHAIN="${3:-}"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign() { codesign --force --timestamp=none --preserve-metadata=identifier,entitlements,flags \
  ${KEYCHAIN:+--keychain "$KEYCHAIN"} --sign "$IDENTITY" "$1"; }
for xpc in "$SPARKLE"/XPCServices/*.xpc; do sign "$xpc"; done
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP"
codesign --verify --deep --strict "$APP"
codesign --display --requirements - "$APP" 2>&1 | grep designated
