#!/usr/bin/env bash
# Builds Tide.app (release) into ./build
set -euo pipefail
cd "$(dirname "$0")"

# Use the full Xcode if it's installed (the Command Line Tools alone
# don't include every SwiftUI plugin).
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/Tide.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Tide" "$APP/Contents/MacOS/Tide"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signing (required for the Apple Events / Spotify permission)
codesign --force --sign - "$APP"

echo "✅  $APP is ready. Launch it with: open $APP"
