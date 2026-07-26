#!/usr/bin/env bash
# release.sh — build, Developer ID sign, notarize, staple, and package JakeListen
# into a distributable .dmg that coworkers can just double-click (no Gatekeeper
# warnings). Run this once per release.
#
# Prerequisites (one-time — see DISTRIBUTING.md):
#   1. A "Developer ID Application" certificate in your login keychain
#      (security find-identity -v -p codesigning  → shows it).
#   2. A stored notarization profile:
#        xcrun notarytool store-credentials JakeListen-Notary \
#          --apple-id "you@example.com" --team-id "YOURTEAMID" \
#          --password "app-specific-password"
#
# Usage:
#   ./release.sh                 # auto-detect the Developer ID identity
#   SIGN_ID="Developer ID Application: Name (TEAMID)" ./release.sh
#   NOTARY_PROFILE=MyProfile ./release.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$DIR/build/JakeListen.app"
DMG="$DIR/build/JakeListen.dmg"
STAGE="$DIR/build/dmg-stage"
NOTARY_PROFILE="${NOTARY_PROFILE:-JakeListen-Notary}"

step() { printf "\n\033[1;33m▸ %s\033[0m\n" "$1"; }
die()  { printf "\033[1;31m✗ %s\033[0m\n" "$1" >&2; exit 1; }

# ---------- resolve the Developer ID signing identity ----------
if [ -z "${SIGN_ID:-}" ]; then
    SIGN_ID="$(security find-identity -v -p codesigning \
        | grep "Developer ID Application" | head -1 \
        | sed -E 's/.*"(.*)"/\1/')"
fi
[ -n "$SIGN_ID" ] || die "No 'Developer ID Application' identity found. Create the certificate first (see DISTRIBUTING.md), then re-run."
echo "Signing identity: $SIGN_ID"

# ---------- 1) build ----------
step "Building"
"$DIR/build.sh"

# ---------- 2) re-sign with Developer ID + hardened runtime + secure timestamp ----------
step "Signing with Developer ID (hardened runtime)"
codesign --force --deep --options runtime --timestamp --sign "$SIGN_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP" || die "codesign verification failed"

# ---------- 3) package a .dmg (with an Applications shortcut for drag-install) ----------
step "Building disk image"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "JakeListen" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

# ---------- 4) notarize the .dmg (Apple scans it; ~1–5 min) ----------
step "Notarizing (this waits for Apple)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait \
    || die "Notarization failed. Check the profile name ($NOTARY_PROFILE) and your credentials."

# ---------- 5) staple so it's trusted even offline ----------
step "Stapling"
xcrun stapler staple "$DMG"

# ---------- 6) verify the end result ----------
step "Verifying"
spctl -a -t open --context context:primary-signature -vv "$DMG" || true
echo
printf "\033[1;32m✓ Done → %s\033[0m\n" "$DMG"
echo "Share this .dmg (Slack / Drive / a GitHub Release). Coworkers double-click, drag to Applications."
