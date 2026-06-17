# JakeListen for Mac (GUI)

A small native **menu-bar + window** front-end for the `jakelisten` command-line
tool. It doesn't re-implement anything — it drives the existing CLI, so the audio
capture, transcription, and summary pipeline are identical to the terminal
version.

![JakeListen for Mac — window showing a call summary and transcript](screenshot.png)

<p align="center">
  <img src="screenshot-menubar.png" alt="JakeListen menu-bar popover" width="320">
</p>

## What it gives you

- **A menu-bar icon** (🐕 → ⏺ while recording) to start/stop a recording with one
  click — no terminal needed.
- **A window** listing every past call with its **summary** and **transcript**.
- Live elapsed-time and status while recording and processing.
- **A live input meter** — a scrolling waveform of your microphone while
  recording, so you can see at a glance that audio is actually coming in. If the
  mic goes silent it turns amber ("No input detected") and the menu-bar icon
  shows a ⚠, so a dead mic never goes unnoticed.
- **Delete** recordings (right-click a call, or select it and press ⌫) — files
  go to the Trash, so it's recoverable.
- **Hideable menu-bar icon** — turn it off from the menu-bar popover, the window
  toolbar, or Settings (⌘,), and back on the same way.
- **In-app first-run setup** — paste your Google API key and set usual
  participants right in the app (no editing config files).
- **Speaker names** — tell JakeListen who's usually on your calls so it labels
  speakers by name instead of "Speaker 1/2."

## Getting a Google Gemini API key

JakeListen uses Google's Gemini AI to transcribe and summarize. The app's
first-run screen has this same guide with a button that opens the page:

1. Go to **https://aistudio.google.com/apikey**
2. Sign in with any Google account.
3. Click **Create API key** and accept the terms if prompted.
4. Choose **Create API key in a new project** (simplest).
5. Click **Copy**, then paste the key (it starts with `AIza`) into JakeListen.

**Cost:** Gemini has a **free tier** that's plenty for personal call summaries.
You don't need to pay to start. If you later need higher limits, enable billing
on the Google Cloud project tied to your key. Keep your key private.

## Build from source (developers)

Requirements: macOS 14.2+ and the **Xcode Command Line Tools**
(`xcode-select --install`). A full Xcode install is **not** required.

```bash
cd mac-app
./build.sh --run     # compiles build/JakeListen.app with swiftc and launches it
```

The CLI must be installed too (repo root `./install.sh`). Drag
`build/JakeListen.app` into `/Applications` to keep it.

## How it works

- **Start** spawns `jakelisten record` (which begins recording immediately).
- **Stop** writes a newline to the process's stdin — exactly what pressing
  **Enter** does in the terminal — which tells the CLI to stop and run
  transcription + summary.
- When the process finishes, the window refreshes from
  `~/JakeListen/recordings/` and selects the new call.

Because GUI apps don't inherit your shell's `PATH`, the app looks for the CLI at
`/opt/homebrew/bin/jakelisten` and `/usr/local/bin/jakelisten`, then falls back
to a login shell lookup. It also prepends Homebrew paths to the child process
environment so `node`, `ffmpeg`, and the Core Audio helper resolve.

## Permissions

The first time you record from the app, macOS will ask for **microphone** and
**system-audio recording** permission for *JakeListen.app* (separate from the
grant you gave Terminal). Click **Allow**. If you miss the system-audio prompt:
System Settings → Privacy & Security → *Screen & System Audio Recording* →
enable JakeListen.

## Slack

The app records with `jakelisten record --no-slack`, so the CLI never blocks on
its interactive Slack prompt. Instead, **if `slackcli` is installed**, the app
shows a small "Post summary to Slack?" sheet after each recording — enter a
channel (name or id) and **Post**, or **Skip**. Posting is routed through the
CLI's scriptable `jakelisten post <summary-file> <channel>` command, so channel
name → id resolution stays in one place.

If `slackcli` isn't installed, no prompt appears — the transcript/summary are
just saved locally.

## Notes / limitations

- This is a wrapper, not a reimplementation; CLI behavior is the source of truth.
