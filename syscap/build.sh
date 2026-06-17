#!/usr/bin/env bash
# Build the JakeListen system-audio capture helper (Core Audio taps).
# Output: ../jakelisten-syscap  (next to jakelisten.js, where the CLI looks for it)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$DIR/../jakelisten-syscap"

if ! command -v swiftc >/dev/null 2>&1; then
	echo "✗ swiftc not found. Install Xcode Command Line Tools:  xcode-select --install" >&2
	exit 1
fi

echo "Building jakelisten-syscap…"
swiftc -O \
	-framework CoreAudio -framework AudioToolbox -framework AVFoundation -framework Foundation \
	"$DIR/jakelisten-syscap.swift" \
	-o "$OUT" \
	-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$DIR/Info.plist"

# Sign with a stable self-signed identity so the TCC audio-capture grant
# survives rebuilds (falls back to ad-hoc if the identity can't be created).
"$DIR/../scripts/macos-sign.sh" "$OUT"

echo "✓ Built $OUT"
