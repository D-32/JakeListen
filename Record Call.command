#!/bin/bash
# JakeListen — double-click this to record a call. No typing needed.
# (A .command file opens in Terminal.app, which is where the system-audio
#  permission is granted, so capture works without any extra setup.)

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
clear

echo "🐕  JakeListen — Record a Call"
echo "----------------------------------------"

if ! command -v jakelisten >/dev/null 2>&1; then
	echo
	echo "JakeListen isn't set up on this Mac yet."
	echo "Run ./install.sh from the JakeListen folder first."
	echo
	read -r -p "Press Return to close…" _
	exit 1
fi

echo
echo "Press Return to start recording (or type 2 to re-process a recent recording)."
echo "When your call is over, come back here and press Return."
echo

jakelisten

echo
echo "----------------------------------------"
echo "✅  Done. You can close this window (Cmd-W)."
read -r -p "Press Return to close…" _
