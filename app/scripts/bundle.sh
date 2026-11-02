#!/bin/bash
# Builds the SwiftPM executable and wraps it into build/Earshot.app.
# Usage: scripts/bundle.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/Earshot.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Earshot" "$APP/Contents/MacOS/Earshot"
cp Support/Info.plist "$APP/Contents/Info.plist"
[ -f Support/AppIcon.icns ] && cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# SIGN_IDENTITY (e.g. an "Apple Development: …" certificate) keeps the signature
# stable across builds, so Accessibility / Screen Recording grants survive rebuilds.
# Without it the app is ad-hoc signed.
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
