#!/usr/bin/env bash
# Build JakeListen.app — a SwiftUI menu-bar + window front-end for the
# jakelisten CLI. Requires only the Xcode Command Line Tools (no full Xcode).
#
# Usage:
#   ./build.sh          build into ./build/JakeListen.app
#   ./build.sh --run    build, then launch it
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$DIR/build/JakeListen.app"
ARCH="$(uname -m)"
MIN_OS="14.0"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "✗ swiftc not found. Install the Xcode Command Line Tools:  xcode-select --install" >&2
    exit 1
fi

echo "Building JakeListen.app ($ARCH, macOS $MIN_OS+)…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
[ -f "$DIR/AppIcon.icns" ] && cp "$DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

swiftc -O \
    -target "${ARCH}-apple-macos${MIN_OS}" \
    -framework SwiftUI -framework AppKit -framework AVFoundation \
    $(find "$DIR/Sources" -name '*.swift') \
    -o "$APP/Contents/MacOS/JakeListen"

# Ad-hoc sign so TCC can attribute the microphone grant to the app.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "✓ Built $APP"

if [ "${1:-}" = "--run" ]; then
    echo "Launching…"
    open "$APP"
fi
