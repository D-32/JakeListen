#!/usr/bin/env bash
# Build JakeListen.app — a self-contained SwiftUI app that records a meeting
# (mic + system audio) and transcribes it with Gemini. No third-party runtime:
# building needs only the Xcode Command Line Tools (swiftc); running needs nothing.
#
# Usage:
#   ./build.sh          build into ./build/JakeListen.app
#   ./build.sh --run    build, then launch it
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$DIR/build/JakeListen.app"
ARCH="$(uname -m)"
MIN_OS="26.0"

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
    -framework CoreAudio -framework AudioToolbox -framework Security \
    $(find "$DIR/Sources" -name '*.swift') \
    -o "$APP/Contents/MacOS/JakeListen"

# Sign with a stable self-signed identity so TCC microphone/system-audio grants
# survive rebuilds (falls back to ad-hoc if the identity can't be created).
"$DIR/sign.sh" "$APP"

echo "✓ Built $APP"

if [ "${1:-}" = "--run" ]; then
    echo "Launching…"
    open "$APP"
fi
