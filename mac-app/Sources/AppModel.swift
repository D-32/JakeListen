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

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var timer: Timer?
    private var startedAt: Date?

    init() {
        cliPath = Self.resolveCLI()
        if cliPath == nil {
            status = "jakelisten CLI not found — run install.sh first"
        }
        refresh()
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

    // MARK: - Recording control

    func toggle() {
        switch state {
        case .idle: start()
        case .recording: stop()
        case .processing: break
        }
    }

    func start() {
        guard state == .idle, let cli = cliPath else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cli)
        proc.arguments = ["record"]

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

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let started = self.startedAt else { return }
            self.elapsed = Date().timeIntervalSince(started)
        }
    }

    func stop() {
        guard state == .recording else { return }
        timer?.invalidate()
        timer = nil
        state = .processing
        status = "Transcribing & summarizing…"
        // A newline is what the CLI reads as "Enter" to stop and process.
        stdinHandle?.write(Data("\n".utf8))
    }

    private func finishProcessing() {
        process = nil
        stdinHandle = nil
        startedAt = nil
        state = .idle
        status = "Ready"
        refresh()
        // Auto-select the newest recording so the user sees the result.
        selectedID = recordings.first?.id
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
