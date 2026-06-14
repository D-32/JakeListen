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

# Ad-hoc sign so TCC can key the audio-capture grant to this binary.
codesign --force --sign - "$OUT" 2>/dev/null || true

echo "✓ Built $OUT"
