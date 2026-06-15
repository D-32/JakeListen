#!/usr/bin/env bash
# Build JakeListen.app and package it into a drag-to-Applications .dmg.
# Output: build/JakeListen.dmg
#
# Note: the .dmg installs the *app*. The app still needs the jakelisten CLI +
# Node + ffmpeg — use install.command for the full no-terminal setup, or run
# the app once and it will tell you what's missing.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$DIR/build/JakeListen.app"
DMG="$DIR/build/JakeListen.dmg"

"$DIR/build.sh"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag-to-install target

rm -f "$DMG"
hdiutil create -volname "JakeListen" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "✓ Built $DMG"
