#!/usr/bin/env bash
# repair-m4a.sh — rebuild a JakeListen .m4a that was never closed.
#
# When the app dies mid-recording the .m4a never gets its index (the `moov`
# atom), so nothing can open it — Gemini answers 400 INVALID_ARGUMENT. The audio
# itself is all still there: a run of raw AAC-LC frames with no frame lengths.
# This walks that run, asks libavcodec for each frame's exact length, re-wraps
# the frames as ADTS and muxes a fresh .m4a. The audio is byte-identical to what
# a clean stop would have produced, minus the ~0.1 s the encoder still held in
# its buffer when the process died.
#
# Needs: ffmpeg (brew install ffmpeg) and clang (Xcode Command Line Tools).
#
# Usage: ./repair-m4a.sh broken.m4a [fixed.m4a]

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
in="${1:?usage: repair-m4a.sh broken.m4a [fixed.m4a]}"
out="${2:-${in%.m4a}-repaired.m4a}"

command -v ffmpeg >/dev/null || { echo "✗ ffmpeg not found — brew install ffmpeg" >&2; exit 1; }
pkg-config --exists libavcodec libavutil 2>/dev/null || { echo "✗ libavcodec headers not found — brew install ffmpeg" >&2; exit 1; }

if afinfo "$in" >/dev/null 2>&1; then
    secs=$(afinfo "$in" | sed -n 's/estimated duration: \([0-9.]*\).*/\1/p')
    if [ "${secs%%.*}" = "0" ]; then
        echo "✗ $in opens fine but holds 0 s of audio — the track captured nothing. Nothing to recover."
        exit 1
    fi
    echo "✓ $in already opens fine (${secs} s) — nothing to repair."; exit 0
fi

size=$(stat -f%z "$in")
if [ "$size" -lt 2000 ]; then
    echo "✗ $in is only ${size} bytes — it holds no audio at all. Nothing to recover."; exit 1
fi

bin="$here/.aac_split"
if [ ! -x "$bin" ] || [ "$here/aac_split.c" -nt "$bin" ]; then
    clang -O2 "$here/aac_split.c" -o "$bin" $(pkg-config --cflags --libs libavcodec libavutil)
fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Find where the raw AAC run starts. AVAudioFile reserves a fixed block after
# ftyp and backfills the mdat header on close, so on a killed file that header
# is still zeros. The right offset is the one that parses end to end with no
# resyncs, so just try the candidates and keep the clean one.
best=""; bestframes=0
for off in 24576 24568 24560 24584 32776 16392 8200; do
    [ "$off" -ge "$size" ] && continue
    if log=$("$bin" "$in" "$tmp/f.aac" "$off" 2>&1) \
       && [[ "$log" == *"resync_bytes=0"* ]] \
       && frames=$(sed -n 's/.*frames=\([0-9]*\).*/\1/p' <<<"$log") \
       && [ "${frames:-0}" -gt "$bestframes" ]; then
        best="$off"; bestframes="$frames"; cp "$tmp/f.aac" "$tmp/best.aac"
    fi
done
[ -n "$best" ] || { echo "✗ Could not find the AAC data in $in." >&2; exit 1; }

# Stream-copy, so the AAC is bit-identical to what a clean stop would have
# written. The result starts 2112 samples (0.13 s) earlier than the original
# because the encoder priming is no longer declared — harmless for playback and
# transcription, and worth far more than a re-encode would cost in quality.
ffmpeg -v error -y -i "$tmp/best.aac" -c copy "$out"

dur=$(afinfo "$out" | sed -n 's/estimated duration: \([0-9.]*\).*/\1/p')
echo "✓ $out"
echo "  $bestframes frames recovered · ${dur:-?} s · AAC data started at byte $best"
