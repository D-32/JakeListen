#!/usr/bin/env bash
# JakeListen installer — run with:  ./install.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOLD=$'\e[1m'; DIM=$'\e[2m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'; CYAN=$'\e[36m'; RST=$'\e[0m'

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$GREEN" "$RST" "$*"; }
warn() { printf '%s!%s %s\n' "$YELLOW" "$RST" "$*"; }
err()  { printf '%s✗%s %s\n' "$RED" "$RST" "$*"; }
step() { printf '\n%s── %s ──%s\n' "$BOLD" "$*" "$RST"; }

say "${BOLD}🐕 JakeListen installer${RST}"
say "${DIM}Records video calls, transcribes + summarises with Gemini, posts to Slack.${RST}"

# ---------- prerequisites ----------
step "Checking prerequisites"

if ! command -v brew >/dev/null 2>&1; then
  err "Homebrew not found. Install from https://brew.sh then re-run ./install.sh"
  exit 1
fi
ok "Homebrew found"

BREW_PREFIX="$(brew --prefix)"
BIN_DIR="$BREW_PREFIX/bin"

if ! command -v node >/dev/null 2>&1; then
  err "Node.js not found. Install with: brew install node"
  exit 1
fi
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
if [ "$NODE_MAJOR" -lt 20 ]; then
  err "Node $(node -v) is too old (need v20+). Upgrade with: brew upgrade node"
  exit 1
fi
ok "Node $(node -v)"

# ---------- ffmpeg ----------
step "ffmpeg"
if command -v ffmpeg >/dev/null 2>&1; then
  ok "ffmpeg already installed"
else
  warn "ffmpeg not found — installing via Homebrew..."
  brew install ffmpeg && ok "ffmpeg installed" || { err "ffmpeg install failed"; exit 1; }
fi

# ---------- system-audio capture helper (replaces BlackHole) ----------
step "System-audio capture helper (Core Audio taps — no BlackHole)"
if command -v swiftc >/dev/null 2>&1; then
  if "$SCRIPT_DIR/syscap/build.sh"; then
    ok "Built jakelisten-syscap (captures the call audio natively)"
  else
    err "Helper build failed. JakeListen will still work, but mic-only until it's built."
  fi
else
  warn "swiftc not found — can't build the system-audio helper."
  warn "Install Xcode Command Line Tools, then re-run:  xcode-select --install"
  say "${DIM}  Without it JakeListen records your mic only (won't capture the other side).${RST}"
fi

# ---------- link the command ----------
step "Installing the 'jakelisten' command"
chmod +x "$SCRIPT_DIR/jakelisten.js"
if ln -sf "$SCRIPT_DIR/jakelisten.js" "$BIN_DIR/jakelisten" 2>/dev/null; then
  ok "linked: $BIN_DIR/jakelisten"
else
  warn "Could not write to $BIN_DIR (permissions). Trying with sudo..."
  sudo ln -sf "$SCRIPT_DIR/jakelisten.js" "$BIN_DIR/jakelisten" && ok "linked: $BIN_DIR/jakelisten" || err "Linking failed."
fi

# ---------- slackcli (optional) ----------
step "Slack (optional)"
if command -v slackcli >/dev/null 2>&1; then
  ok "slackcli found — Slack posting available"
else
  warn "slackcli not found. JakeListen works without it; you just won't be able to auto-post to Slack."
  say "${DIM}  Install and authenticate slackcli separately if you want this.${RST}"
fi

# ---------- Gemini key ----------
step "Gemini API key"
say "Get a key at ${CYAN}https://aistudio.google.com/apikey${RST} (click 'Create API key')."
say "${DIM}It should start with 'AIza'. Note: a brand-new key can take a couple of minutes to activate.${RST}"
say ""
read -r -p "Configure your Gemini key now? [Y/n] " ans
if [ "${ans:-y}" != "n" ] && [ "${ans:-y}" != "N" ]; then
  jakelisten config
else
  warn "Skipped. Run 'jakelisten config' later to set it."
fi

# ---------- one-time permission ----------
step "IMPORTANT: one-time permission (no BlackHole, no Multi-Output Device)"
cat <<'GUIDE'
JakeListen captures the call audio directly with macOS Core Audio taps — there is
NO virtual audio driver and NO Multi-Output Device to set up. Just grant permission once.

⚠ Grant it from the built-in Terminal.app — third-party terminals (Ghostty, Warp, iTerm)
  often don't show the prompt. The double-click launcher uses Terminal.app, so granting
  it here is exactly what the launcher needs.

  - A dialogue will ask to allow audio recording — click Allow.
  - If you miss it: System Settings → Privacy & Security → "Screen & System Audio
    Recording" → scroll to "System Audio Recording Only" → enable Terminal.

The first time you record, macOS will also ask to allow the microphone — click Allow.
GUIDE

say ""
read -r -p "Grant system-audio permission now? [Y/n] " pans
if [ "${pans:-y}" != "n" ] && [ "${pans:-y}" != "N" ]; then
  jakelisten permission || true
else
  warn "Skipped. Run 'jakelisten permission' later (once) before your first call."
fi

# ---------- desktop launcher ----------
step "Double-click launcher (for non-technical users)"
say ""
read -r -p "Put a 'Record Call' launcher on the Desktop? [Y/n] " lans
if [ "${lans:-y}" != "n" ] && [ "${lans:-y}" != "N" ]; then
  if cp "$SCRIPT_DIR/Record Call.command" "$HOME/Desktop/" 2>/dev/null; then
    chmod +x "$HOME/Desktop/Record Call.command"
    ok "Added 'Record Call' to the Desktop — double-click it to record."
  else
    warn "Couldn't copy the launcher to the Desktop."
  fi
else
  warn "Skipped. Copy \"Record Call.command\" to the Desktop later if you want it."
fi

# ---------- done ----------
step "Done"
say "Run a health check any time:   ${BOLD}jakelisten setup${RST}"
say "Record a call:                 ${BOLD}jakelisten${RST}   ${DIM}(press Enter to stop)${RST}"
say "Or just double-click:          ${BOLD}Record Call${RST}   ${DIM}(on the Desktop)${RST}"
say ""
jakelisten setup || true
