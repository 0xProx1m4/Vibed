#!/usr/bin/env bash
# Construit Tide.app (release) dans ./build
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/Tide.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Tide" "$APP/Contents/MacOS/Tide"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Signature ad-hoc (nécessaire pour la permission Apple Events / Spotify)
codesign --force --sign - "$APP"

echo "✅  $APP prêt. Lance-le avec : open $APP"
