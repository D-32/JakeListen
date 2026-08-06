// Updater — keeps JakeListen current without anyone having to remember.
//
// On launch the app asks GitHub for the newest release and compares it with its
// own CFBundleShortVersionString. If there's a newer one, a sheet offers a
// one-button update: download the release's .dmg, mount it, and install it over
// this bundle.
//
// SECURITY: the downloaded app must satisfy a code requirement pinning Apple's
// root, our bundle ID and our Developer ID team before anything is installed.
// Without that check this would be a remote-code-execution hole — a hijacked
// release URL could hand us any binary and we'd run it. The check is not optional.
//
// An app can't overwrite itself while it's running, so the last step writes a
// small shell script that waits for us to quit, swaps the bundle, and relaunches.

import Foundation
import AppKit

enum UpdateConfig {
    static let owner = "D-32"
    static let repo = "JakeListen"

    /// The Developer ID team the release must be signed by. Hard-coded on
    /// purpose: derived-at-runtime values can be spoofed by whatever we just
    /// downloaded. If the signing certificate ever changes, this must change
    /// too — until it does, updates fail closed and people install by hand.
    static let teamID = "5EFBK52YD3"
    static let bundleID = "com.github.d-32.jakelisten"

    static let latestAPI = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!

    /// What the downloaded bundle has to satisfy to be allowed to replace us.
    static var codeRequirement: String {
        "anchor apple generic and identifier \"\(bundleID)\" "
        + "and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}

// MARK: - Versions

/// A dotted version ("3.1.0"). Missing components count as 0, so "3.1" < "3.1.1".
struct AppVersion: Comparable, CustomStringConvertible {
    let parts: [Int]
    let description: String

    init(_ raw: String) {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        description = cleaned
        parts = cleaned.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let l = i < a.parts.count ? a.parts[i] : 0
            let r = i < b.parts.count ? b.parts[i] : 0
            if l != r { return l < r }
        }
        return false
    }
}

struct UpdateInfo: Identifiable, Equatable {
    var id: String { version.description }
    let version: AppVersion
    let notes: String
    let dmgURL: URL
}

enum UpdateError: LocalizedError {
    case noAsset
    case badResponse(Int)
    case notMounted
    case appMissing
    case signatureRejected(String)
    case versionMismatch(String)
    case notWritable(String)
    case commandFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .noAsset:
            return "That release has no .dmg to download."
        case .badResponse(let code):
            return "GitHub returned \(code)."
        case .notMounted:
            return "The downloaded disk image couldn't be opened."
        case .appMissing:
            return "The disk image didn't contain JakeListen.app."
        case .signatureRejected(let detail):
            return "The downloaded app isn't signed by JakeListen's developer, so it was not installed.\n\n\(detail)"
        case .versionMismatch(let v):
            return "The downloaded app says it is version \(v), which isn't what the release promised."
        case .notWritable(let path):
            return "JakeListen can't update itself at \(path). Move it to your Applications folder and try again."
        case .commandFailed(let what, let out):
            return "\(what) failed.\n\n\(out.prefix(300))"
        }
    }
}

// MARK: - Model

@MainActor
final class UpdateModel: ObservableObject {
    enum Phase: Equatable {
        case idle, checking, downloading, verifying, installing
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .verifying, .installing: return true
            case .idle, .failed: return false
            }
        }

        var label: String {
            switch self {
            case .checking:   return "Checking…"
            case .downloading: return "Downloading…"
            case .verifying:  return "Checking the signature…"
            case .installing: return "Installing — JakeListen will restart."
            default:          return ""
            }
        }
    }

    /// The result of a manual "Check for Updates…" that produced no sheet —
    /// either good news or a broken check. A silent launch check never sets it.
    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Published var available: UpdateInfo?
    @Published var phase: Phase = .idle
    @Published var notice: Notice?

    /// Set while the app is recording — we never restart out from under a recording.
    var isBusyRecording: @MainActor () -> Bool = { false }

    private var didAutoCheck = false
    private let skippedKey = "skippedUpdateVersion"

    var currentVersion: AppVersion {
        AppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
    }

    // MARK: Checking

    /// Called once at launch. Silent: no news, no interruption.
    func checkOnLaunch() {
        guard !didAutoCheck else { return }
        didAutoCheck = true
        Task { await check(manual: false) }
    }

    func check(manual: Bool) async {
        guard !phase.isBusy else { return }
        phase = .checking
        do {
            let info = try await fetchLatest()
            phase = .idle
            guard let info, info.version > currentVersion else {
                if manual {
                    notice = Notice(title: "You're up to date",
                                    message: "JakeListen \(currentVersion) is the newest version.")
                }
                return
            }
            // A skipped version stays skipped until something newer appears.
            if !manual, let skipped = UserDefaults.standard.string(forKey: skippedKey),
               AppVersion(skipped) >= info.version { return }
            available = info
        } catch {
            // A silent check that fails stays silent — no network is not news.
            phase = .idle
            if manual {
                notice = Notice(title: "Couldn't check for updates", message: message(for: error))
            }
        }
    }

    func skip(_ info: UpdateInfo) {
        UserDefaults.standard.set(info.version.description, forKey: skippedKey)
        dismiss()
    }

    func dismiss() {
        available = nil
        phase = .idle
    }

    private func fetchLatest() async throws -> UpdateInfo? {
        var req = URLRequest(url: UpdateConfig.latestAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("JakeListen/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw UpdateError.badResponse(0) }
        guard http.statusCode == 200 else { throw UpdateError.badResponse(http.statusCode) }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        if (json["draft"] as? Bool) == true || (json["prerelease"] as? Bool) == true { return nil }

        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
              let urlString = dmg["browser_download_url"] as? String,
              let url = URL(string: urlString), url.scheme == "https" else {
            throw UpdateError.noAsset
        }
        let notes = (json["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return UpdateInfo(version: AppVersion(tag), notes: notes, dmgURL: url)
    }

    // MARK: Installing

    func install(_ info: UpdateInfo) {
        guard !phase.isBusy else { return }
        guard !isBusyRecording() else {
            phase = .failed("Stop the recording first — updating restarts the app.")
            return
        }
        Task {
            do {
                try await performInstall(info)   // only returns if it didn't restart us
            } catch {
                phase = .failed(message(for: error))
            }
        }
    }

    private func performInstall(_ info: UpdateInfo) async throws {
        let fm = FileManager.default
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        guard target.pathExtension == "app", fm.isWritableFile(atPath: parent.path) else {
            throw UpdateError.notWritable(parent.path)
        }

        let work = fm.temporaryDirectory
            .appendingPathComponent("JakeListenUpdate-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        // 1) Download the .dmg.
        phase = .downloading
        let dmg = work.appendingPathComponent("JakeListen.dmg")
        let (tmpFile, resp) = try await URLSession.shared.download(from: info.dmgURL)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.badResponse(http.statusCode)
        }
        try fm.moveItem(at: tmpFile, to: dmg)

        // 2) Mount it read-only, out of the way of Finder.
        phase = .verifying
        let mount = work.appendingPathComponent("mnt", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try Self.run("/usr/bin/hdiutil",
                     ["attach", dmg.path, "-nobrowse", "-readonly", "-noverify",
                      "-mountpoint", mount.path], what: "Opening the disk image")
        var detached = false
        func detach() {
            guard !detached else { return }
            detached = true
            _ = try? Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"], what: "Ejecting")
        }
        defer { detach() }

        let mounted = mount.appendingPathComponent("JakeListen.app")
        guard fm.fileExists(atPath: mounted.path) else { throw UpdateError.appMissing }

        // 3) Verify the signature BEFORE it gets anywhere near our bundle.
        try Self.verify(mounted)

        // 4) Copy it off the image, and verify the copy too — the copy is what
        //    actually gets installed, so it's what has to be trustworthy.
        let staged = work.appendingPathComponent("JakeListen.app")
        try Self.run("/usr/bin/ditto", [mounted.path, staged.path], what: "Copying the new app")
        detach()
        try Self.verify(staged)

        // The release said one version; make sure the bundle agrees.
        let staPlist = staged.appendingPathComponent("Contents/Info.plist")
        let staVersion = (NSDictionary(contentsOf: staPlist)?["CFBundleShortVersionString"] as? String) ?? ""
        guard AppVersion(staVersion) == info.version else {
            throw UpdateError.versionMismatch(staVersion.isEmpty ? "unknown" : staVersion)
        }

        // 5) Hand the swap to a helper that outlives us, then quit.
        phase = .installing
        let script = work.appendingPathComponent("install.sh")
        try Self.swapScript(staged: staged, target: target, work: work)
            .write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier)]
        try proc.run()

        // Give it a beat to start waiting on our PID, then get out of the way.
        try? await Task.sleep(for: .milliseconds(400))
        NSApp.terminate(nil)
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Shell helpers

    /// The gate. Throws unless the bundle is Apple-anchored, has our bundle ID,
    /// and was signed by our Developer ID team.
    private static func verify(_ app: URL) throws {
        do {
            try run("/usr/bin/codesign",
                    ["--verify", "--strict", "--deep",
                     "-R", "=\(UpdateConfig.codeRequirement)", app.path],
                    what: "Signature check")
        } catch let UpdateError.commandFailed(_, out) {
            throw UpdateError.signatureRejected(out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String], what: String) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw UpdateError.commandFailed(what, out) }
        return out
    }

    /// Wait for us to quit, swap the bundle, relaunch, clean up. Written to a
    /// file rather than run inline because the process doing the swap has to
    /// outlive the app it's replacing.
    private static func swapScript(staged: URL, target: URL, work: URL) -> String {
        func q(_ url: URL) -> String { "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return """
        #!/bin/bash
        # Installs a JakeListen update once the running copy has quit.
        set -e
        PID="$1"
        STAGED=\(q(staged))
        TARGET=\(q(target))
        WORK=\(q(work))

        # Refuse to touch anything that isn't an .app bundle.
        case "$TARGET" in *.app) ;; *) exit 1 ;; esac

        for _ in $(seq 1 100); do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.2
        done
        sleep 0.4

        # Stage beside the target first, so a failed copy never leaves a gap.
        rm -rf "$TARGET.new" "$TARGET.old"
        /usr/bin/ditto "$STAGED" "$TARGET.new"
        /usr/bin/xattr -dr com.apple.quarantine "$TARGET.new" 2>/dev/null || true
        mv "$TARGET" "$TARGET.old"
        mv "$TARGET.new" "$TARGET"
        rm -rf "$TARGET.old"

        /usr/bin/open "$TARGET"
        rm -rf "$WORK"
        """
    }
}
