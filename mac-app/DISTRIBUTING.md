# Distributing JakeListen to coworkers

JakeListen is a single self-contained `.app` — no runtime, no installer, no
dependencies for the person receiving it. The only question is how to get macOS
Gatekeeper to trust it on their machine. Here are the three realistic options,
easiest-to-trust last.

> **Everyone needs macOS 26 (Tahoe) or newer.** JakeListen uses Core Audio process
> taps for system-audio capture, which require a current macOS.

---

## Option 1 — Share the app as-is (free, some friction)

The build script already signs the app with a stable self-signed identity. That's
enough to *run* it, but macOS doesn't *trust* a self-signed app, so the first open
shows a Gatekeeper warning.

**You:**
```bash
cd mac-app
./build.sh
# zip the app for sharing
ditto -c -k --keepParent build/JakeListen.app ~/Desktop/JakeListen.zip
```
Send `JakeListen.zip` (Slack, Drive, AirDrop, …).

**Each coworker, once:** unzip, then **right-click JakeListen → Open → Open** (a
plain double-click is blocked the first time; right-click → Open gives the
"Open anyway" button). If macOS still refuses, they can clear the quarantine flag:
```bash
xattr -dr com.apple.quarantine /Applications/JakeListen.app
```

Good for a handful of technical coworkers. Not great for a wider or less-technical
group — the warning looks scary and every update repeats the dance.

---

## Option 2 — Developer ID + notarization (recommended, $99/yr)

This is the real answer. Sign with an Apple **Developer ID Application** certificate,
notarize with Apple, staple the ticket, and coworkers just **double-click — no
warnings, ever**, now and for every future update. This is **not** the Mac App Store;
you distribute the file yourself (a link, Slack, GitHub Releases).

### One-time setup
1. Enroll in the **Apple Developer Program** ($99/yr): <https://developer.apple.com/programs/>
2. Create a **Developer ID Application** certificate. Without full Xcode installed,
   do it via the portal:
   - In **Keychain Access ▸ Certificate Assistant ▸ Request a Certificate from a
     Certificate Authority**, fill in your email + a name, choose **Saved to disk**,
     and save the `.certSigningRequest` file (this also creates the private key in
     your login keychain).
   - At <https://developer.apple.com/account/resources/certificates> click ➕, pick
     **Developer ID Application**, upload the CSR, and **download** the `.cer`.
   - Double-click the `.cer` to install it. Verify:
     ```bash
     security find-identity -v -p codesigning
     # → "Developer ID Application: Your Name (TEAMID)"   ← the (TEAMID) is your Team ID
     ```
3. Store a notarization credential once so the tool can log in non-interactively.
   Use an **app-specific password** from <https://account.apple.com> (Sign-In & Security):
   ```bash
   xcrun notarytool store-credentials JakeListen-Notary \
     --apple-id "you@example.com" \
     --team-id "YOURTEAMID" \
     --password "abcd-efgh-ijkl-mnop"   # app-specific password
   ```

### Each release — one command
```bash
cd mac-app
./release.sh
```
`release.sh` auto-detects your Developer ID identity, then builds → signs with the
hardened runtime → packages a drag-to-Applications **`.dmg`** → notarizes it with
Apple → staples the ticket → verifies. The result is `build/JakeListen.dmg`.

Share that `.dmg` (Slack / Drive / a **GitHub Release** linked from the website's
download button). Coworkers double-click and drag to Applications — no warnings, now
and for every future release.

> Overrides if needed: `SIGN_ID="Developer ID Application: … (TEAMID)" ./release.sh`
> or `NOTARY_PROFILE=MyProfile ./release.sh`.

**Note on the App Store:** the system-audio process tap relies on a private TCC
service, which is fine for Developer ID distribution but would be **rejected by Mac
App Store review**. That's the main reason to use Developer ID, not the store.

---

## Option 3 — Mac App Store (not recommended)

Sandboxing + review would reject the process-tap capture approach, and it's far more
overhead than an internal tool warrants. Skip it.

---

## Recommendation

Enroll in the Apple Developer Program and use **Option 2** — it's the only path where
coworkers just double-click and it works, updates included. Until the certificate
exists, **Option 1** unblocks technical coworkers today. Once you're enrolled, this
signing/notarization can be folded straight into `build.sh`.
