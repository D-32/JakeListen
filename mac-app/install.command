#!/bin/bash
# JakeListen one-click installer for non-technical users.
# Double-click this file in Finder. It installs the prerequisites (Homebrew,
# Node, ffmpeg), sets up the `jakelisten` command, builds the Mac app, and puts
# it in your Applications folder. You may be asked for your Mac password once
# (that's macOS letting Homebrew install) — no typing of commands needed.
#
# Gatekeeper: the first time, right-click this file → Open → Open.

set -u
cd "$(dirname "$0")" || exit 1          # mac-app/
REPO="$(cd .. && pwd)"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$1"; }
info() { printf '\033[36m•\033[0m %s\n' "$1"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$1"; }

bold "🐕 Installing JakeListen…"
echo

# 1) Homebrew ----------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  info "Installing Homebrew (this is where macOS may ask for your password)…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
    || { fail "Homebrew install failed."; read -r -p "Press Return to close."; exit 1; }
fi
# Make brew available in this shell (Apple Silicon vs Intel paths)
if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)";
elif [ -x /usr/local/bin/brew ]; then eval "$(/usr/local/bin/brew shellenv)"; fi
ok "Homebrew ready"

# 2) Node + ffmpeg -----------------------------------------------------------
brew list node   >/dev/null 2>&1 || { info "Installing Node…";   brew install node; }
brew list ffmpeg >/dev/null 2>&1 || { info "Installing ffmpeg…"; brew install ffmpeg; }
ok "Node + ffmpeg ready"

# 3) The jakelisten command --------------------------------------------------
info "Setting up the jakelisten command…"
"$REPO/syscap/build.sh" || fail "System-audio helper didn't build — recordings will be mic-only until it does."
chmod +x "$REPO/jakelisten.js"
ln -sf "$REPO/jakelisten.js" "$(brew --prefix)/bin/jakelisten"
ok "jakelisten command installed"

# 4) Build + install the app -------------------------------------------------
info "Building the JakeListen app…"
./build.sh || { fail "App build failed."; read -r -p "Press Return to close."; exit 1; }
rm -rf "/Applications/JakeListen.app"
cp -R "build/JakeListen.app" "/Applications/" || { fail "Could not copy to /Applications."; read -r -p "Press Return to close."; exit 1; }
ok "JakeListen.app installed to /Applications"

# 5) Launch ------------------------------------------------------------------
echo
bold "All done! Opening JakeListen…"
echo "On first launch the app walks you through your Google API key."
open "/Applications/JakeListen.app"
echo
read -r -p "You can close this window now (press Return)."
