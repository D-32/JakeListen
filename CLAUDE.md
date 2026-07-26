# JakeListen — repo guide

A single self-contained macOS app (`mac-app/`) that records a meeting — your mic
**and** the other participants' system audio — and transcribes + summarises it with
Google Gemini. Native only: no CLI, no ffmpeg, no BlackHole. Plus a static marketing
site (`site/`) served at **jakelisten.com**.

## Layout

- `mac-app/Sources/` — the SwiftUI app (audio capture, Gemini client, UI).
- `mac-app/build.sh` — build the `.app` with `swiftc` (Xcode Command Line Tools only).
- `mac-app/release.sh` — signed + notarized `.dmg` for distribution (see below).
- `mac-app/DISTRIBUTING.md` — the full signing/notarization story.
- `site/` — the static website (`index.html` + a few images).
- `wrangler.toml` — Cloudflare deploy config for the website (see below).

## Build & run the app

```bash
cd mac-app
./build.sh --run          # build into build/JakeListen.app and launch it
```

Requires **macOS 26 (Tahoe)+**. First run asks for Microphone + System Audio
permission and a Gemini API key (stored in the login Keychain, never in the repo).

## Release a build for coworkers

One command, once your Apple Developer cert + notary profile exist:

```bash
./mac-app/release.sh      # build → Developer ID sign → .dmg → notarize → staple
```

Then attach `mac-app/build/JakeListen.dmg` to a GitHub Release (the website's
download button points at `releases/latest/download/JakeListen.dmg`):

```bash
gh release upload v3.0.1 mac-app/build/JakeListen.dmg --clobber
```

Full one-time setup (cert, app-specific password, `notarytool store-credentials`)
is in [mac-app/DISTRIBUTING.md](mac-app/DISTRIBUTING.md).

## Website deploy — jakelisten.com

**How it's hosted:** jakelisten.com is a Cloudflare **Worker** (the one named in
`wrangler.toml`) using **Workers Static Assets** — it just serves the files in
`site/`. It is **not** Cloudflare Pages, and it is **not** git-connected, so
**pushing to GitHub does _not_ deploy the site.** You deploy explicitly with
wrangler. The apex domain is attached to the worker as a custom domain (declared in
the `[[routes]]` block), and redeploying preserves it.

**One-time setup on a new machine:**

```bash
npm i -g wrangler         # the Cloudflare CLI
wrangler login            # opens a browser; approve access (interactive, once)
```

Pick the Cloudflare account that owns the `jakelisten.com` zone when prompted.

**Deploy (run from the repo root, where `wrangler.toml` lives):**

```bash
wrangler deploy --dry-run   # optional: validate config + list the assets
wrangler deploy             # upload site/ to the worker; keeps the custom domain
```

`wrangler.toml` is the whole config — no secrets in it:

```toml
name = "…"                  # the worker service serving the site
compatibility_date = "…"
[assets]
directory = "./site"        # everything in site/ is served statically
[[routes]]
pattern = "jakelisten.com"
custom_domain = true        # keeps the apex domain mapped on each deploy
```

**Verify it went live:**

```bash
curl -s https://jakelisten.com | grep -o "<title>[^<]*</title>"
```

**Notes / gotchas:**
- Auth is via `wrangler login` (browser OAuth) or a `CLOUDFLARE_API_TOKEN` env var —
  never commit a token. Credentials live outside the repo.
- If `wrangler pages project list` is empty, that's expected: this is a Worker, not
  a Pages project. Don't create a Pages project — just `wrangler deploy`.
- The `workers.dev` subdomain is intentionally disabled; the site is reached only via
  the custom domain.
- Editing `site/` and pushing to GitHub keeps the repo in sync, but you still have to
  run `wrangler deploy` to publish the change.
