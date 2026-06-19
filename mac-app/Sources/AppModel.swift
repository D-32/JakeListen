// AppModel — drives the JakeListen CLI and exposes recording state to the UI.
//
// The GUI is a thin wrapper around the `jakelisten` command-line tool:
//   • Start  → spawn `jakelisten record` (begins recording immediately).
//   • Stop   → write a newline to its stdin, which the CLI treats as "Enter"
//              and uses to stop recording and run transcription + summary.
//   • The process then exits on its own; we refresh the recordings list.
//
// Nothing here re-implements audio capture — it reuses the exact pipeline the
// CLI already uses (ffmpeg for the mic, the Core Audio tap helper for the call).

import Foundation
import SwiftUI
import AppKit

enum RecState: Equatable {
    case idle
    case recording
    case processing
}

final class AppModel: ObservableObject {
    @Published var state: RecState = .idle
    @Published var status: String = "Ready"
    @Published var elapsed: TimeInterval = 0
    @Published var recordings: [Recording] = []
    @Published var selectedID: Recording.ID?
    @Published var cliPath: String?

    // Post-record Slack prompt (only when slackcli is installed).
    @Published var showPostPrompt = false
    @Published var postChannel = ""

    // Onboarding / API key (stored in the CLI's config so both share it).
    @Published var hasAPIKey = false
    @Published var showOnboarding = false

    // Live mic input meter (runs alongside the CLI; see AudioMeter).
    let meter = AudioMeter()

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var timer: Timer?
    private var startedAt: Date?
    private var lastFinished: Recording?
    private var starting = false  // guards the async permission pre-flight

    init() {
        cliPath = Self.resolveCLI()
        if cliPath == nil {
            status = "jakelisten CLI not found — run the installer first"
        }
        refreshConfigState()
        showOnboarding = !hasAPIKey
        refresh()
    }

    // MARK: - Config (~/.jakelisten/config.json — shared with the CLI)

    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jakelisten/config.json")
    }

    private func readConfig() -> [String: Any] {
        guard let data = try? Data(contentsOf: configURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    func refreshConfigState() {
        let key = (readConfig()["geminiApiKey"] as? String) ?? ""
        hasAPIKey = !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The mic the CLI is configured to record (cfg.micDevice), so the meter can
    /// watch the same device. nil → let the meter use the system default.
    private func configuredMicDevice() -> String? {
        let name = ((readConfig()["micDevice"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Persist the Gemini API key into the CLI's config (creating the dir/file).
    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var cfg = readConfig()
        cfg["geminiApiKey"] = trimmed
        let dir = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted]) {
            try? data.write(to: configURL)
        }
        refreshConfigState()
    }

    var selected: Recording? {
        recordings.first { $0.id == selectedID }
    }

    var elapsedText: String {
        let s = Int(elapsed)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: - CLI discovery

    /// Find the `jakelisten` binary. GUI apps don't inherit the shell PATH, so
    /// check the usual Homebrew locations first, then fall back to a login shell.
    private static func resolveCLI() -> String? {
        let candidates = ["/opt/homebrew/bin/jakelisten", "/usr/local/bin/jakelisten"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/zsh")
        probe.arguments = ["-lc", "command -v jakelisten"]
        let pipe = Pipe()
        probe.standardOutput = pipe
        probe.standardError = FileHandle.nullDevice
        try? probe.run()
        probe.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }

    // MARK: - System-audio permission (so we never silently record nothing)

    enum AudioPermission { case authorized, denied, noHelper }
    private enum PermissionIssue { case systemAudio, noHelper }

    /// The system-audio capture helper sits next to the resolved CLI script
    /// (the `jakelisten` command is a symlink into the install dir).
    private var syscapPath: String? {
        guard let cli = cliPath else { return nil }
        let real = URL(fileURLWithPath: cli).resolvingSymlinksInPath()
        let helper = real.deletingLastPathComponent().appendingPathComponent("jakelisten-syscap")
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper.path : nil
    }

    /// Ask the helper whether system-audio recording is authorized. When the
    /// status is undetermined this also triggers the one-time macOS prompt —
    /// the helper runs in our GUI session, so the dialog can actually appear.
    private func checkSystemAudioPermission() -> AudioPermission {
        guard let helper = syscapPath else { return .noHelper }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: helper)
        p.arguments = ["--check-permission"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return .denied }
        p.waitUntilExit()
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s == "authorized" ? .authorized : .denied
    }

    private func presentPermissionAlert(_ issue: PermissionIssue) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch issue {
        case .systemAudio:
            alert.messageText = "JakeListen can't record the call audio yet"
            alert.informativeText = """
                macOS hasn't granted system-audio recording, so only your microphone would be captured — the other side of the call would be missing.

                Enable JakeListen under System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording, then hit record again.
                """
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
        case .noHelper:
            alert.messageText = "System-audio helper not found"
            alert.informativeText = "JakeListen can record your microphone but not the call audio until the capture helper is installed. Reinstall JakeListen to restore call recording."
            alert.addButton(withTitle: "OK")
        }
        NSApp.activate(ignoringOtherApps: true)
        let resp = alert.runModal()
        if issue == .systemAudio, resp == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Recording control

    func toggle() {
        switch state {
        case .idle: start()
        case .recording: stop()
        case .processing: break
        }
    }

    func start() {
        guard state == .idle, !starting, cliPath != nil else { return }
        starting = true
        // Pre-flight: never begin a recording that would silently miss the call
        // audio. Verify system-audio permission first (this also surfaces the
        // one-time macOS prompt in our GUI session), and only record once it's
        // granted — otherwise guide the user instead of capturing nothing.
        status = "Checking audio permission…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let perm = self.checkSystemAudioPermission()
            DispatchQueue.main.async {
                self.starting = false
                switch perm {
                case .authorized:
                    self.beginRecording()
                case .denied:
                    self.status = "Ready"
                    self.presentPermissionAlert(.systemAudio)
                case .noHelper:
                    self.status = "Ready"
                    self.presentPermissionAlert(.noHelper)
                }
            }
        }
    }

    private func beginRecording() {
        guard state == .idle, let cli = cliPath else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cli)
        // --no-slack: the GUI can't answer the CLI's interactive Slack prompt,
        // so it would hang in "Processing…". We post separately via the sheet.
        var args = ["record", "--no-slack"]
        // Optional participant hint → better name guessing in the transcript.
        let people = UserDefaults.standard
            .string(forKey: PrefKey.participants)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !people.isEmpty { args += ["--speakers", people] }
        proc.arguments = args

        // Ensure node / ffmpeg / the syscap helper resolve from a GUI context.
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = extra + ":" + (env["PATH"] ?? "")
        proc.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = outPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            self?.ingest(text)
        }

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.finishProcessing()
            }
        }

        do {
            try proc.run()
        } catch {
            status = "Failed to start: \(error.localizedDescription)"
            return
        }

        process = proc
        stdinHandle = inPipe.fileHandleForWriting
        startedAt = Date()
        elapsed = 0
        state = .recording
        status = "Recording…"
        meter.start(preferredDeviceName: configuredMicDevice())

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let started = self.startedAt else { return }
            self.elapsed = Date().timeIntervalSince(started)
        }
    }

    func stop() {
        guard state == .recording else { return }
        timer?.invalidate()
        timer = nil
        meter.stop()
        state = .processing
        status = "Transcribing & summarizing…"
        // A newline is what the CLI reads as "Enter" to stop and process.
        stdinHandle?.write(Data("\n".utf8))
    }

    private func finishProcessing() {
        process = nil
        stdinHandle = nil
        startedAt = nil
        meter.stop()  // safety: the process may have exited without a stop()
        state = .idle
        status = "Ready"
        refresh()
        // Auto-select the newest recording so the user sees the result.
        selectedID = recordings.first?.id
        lastFinished = recordings.first
        // Offer to post to Slack only if it's installed and there's a summary.
        if Self.slackAvailable(), let rec = lastFinished, rec.hasSummary {
            postChannel = ""
            showPostPrompt = true
        }
    }

    /// Is the Slack CLI installed? Posting is routed through `jakelisten post`,
    /// but we only prompt when the user actually has slackcli.
    private static func slackAvailable() -> Bool {
        ["/opt/homebrew/bin/slackcli", "/usr/local/bin/slackcli"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Post the most recent recording's summary to a Slack channel via the CLI's
    /// scriptable `post` command (which resolves channel names → ids).
    func postSelectedToSlack(channel: String) {
        let ch = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ch.isEmpty, let rec = lastFinished, let cli = cliPath else { return }
        status = "Posting to \(ch)…"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cli)
        proc.arguments = ["post", rec.summaryURL.path, ch]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        proc.environment = env

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                self?.status = p.terminationStatus == 0
                    ? "Posted to \(ch)"
                    : "Slack post failed — see Terminal/CLI"
            }
        }
        do {
            try proc.run()
        } catch {
            status = "Slack post failed: \(error.localizedDescription)"
        }
    }

    /// Strip ANSI color codes and keep the last meaningful line as the status.
    private func ingest(_ text: String) {
        let cleaned = text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression
        )
        let lines = cleaned
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return }
        DispatchQueue.main.async {
            if self.state != .idle { self.status = last }
        }
    }

    // MARK: - Recordings

    func refresh() {
        recordings = Recording.scan()
        if selectedID == nil { selectedID = recordings.first?.id }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Recording.directory])
    }

    func reveal(_ recording: Recording) {
        let urls = [recording.transcriptURL, recording.meURL].filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Move every file belonging to a recording to the Trash (recoverable).
    func delete(_ recording: Recording) {
        let fm = FileManager.default
        let urls = [
            recording.meURL,
            recording.othersURL,
            recording.transcriptURL,
            recording.summaryURL,
            recording.dir.appendingPathComponent(recording.id + ".others.caf"),
        ]
        for url in urls where fm.fileExists(atPath: url.path) {
            try? fm.trashItem(at: url, resultingItemURL: nil)
        }
        if selectedID == recording.id { selectedID = nil }
        refresh()
    }
}
