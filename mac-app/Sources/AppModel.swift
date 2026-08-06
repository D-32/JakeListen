// AppModel — the app's brain: the recordings list, recording control, and
// transcription orchestration. Owns the AudioRecorder and AppSettings.

import Foundation
import SwiftUI
import AppKit

@MainActor
final class AppModel: ObservableObject {
    @Published var recordings: [Recording] = []
    @Published var selectedID: Recording.ID?
    @Published private(set) var transcribingIDs: Set<String> = []
    @Published var currentRecordingID: String?
    @Published var alert: AppAlert?
    @Published var showSettings = false

    let recorder = AudioRecorder()
    let settings = AppSettings()
    let updater = UpdateModel()

    init() {
        refresh()
        selectedID = recordings.first?.id
        // The updater restarts the app, so it must never fire mid-recording.
        updater.isBusyRecording = { [weak self] in self?.isRecording ?? false }
    }

    // MARK: - Derived status

    func status(for rec: Recording) -> RecordingStatus {
        if rec.id == currentRecordingID { return .recording }
        if transcribingIDs.contains(rec.id) { return .transcribing }
        return rec.baseStatus
    }

    var isRecording: Bool { recorder.state == .recording }
    var selected: Recording? { recordings.first { $0.id == selectedID } }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording { stopRecording() } else { Task { await startRecording() } }
    }

    func startRecording() async {
        guard !isRecording, currentRecordingID == nil else { return }

        // Microphone permission.
        if !AudioRecorder.micAuthorized() {
            let granted = await AudioRecorder.requestMic()
            if !granted {
                alert = .micDenied
                return
            }
        }

        // System-audio permission — never start a recording that would silently
        // miss the meeting audio. Request whenever we're not already authorized
        // (the OS shows its prompt the first time; a hard denial just falls through
        // to the guidance alert).
        var sysPerm = SystemAudioAuthorization.status()
        if sysPerm != .authorized { sysPerm = await SystemAudioAuthorization.request() }
        guard sysPerm == .authorized else {
            alert = .systemAudioDenied
            return
        }

        let rec = RecordingStore.create()
        currentRecordingID = rec.id
        refresh()
        selectedID = rec.id

        do {
            try recorder.start(meURL: rec.meURL, othersURL: rec.othersURL)
        } catch {
            currentRecordingID = nil
            RecordingStore.delete(rec)
            refresh()
            alert = AppAlert(title: "Couldn't start recording", message: "\(error)")
        }
    }

    func stopRecording() {
        guard isRecording, let id = currentRecordingID else { return }
        let duration = recorder.stop()
        currentRecordingID = nil

        if var rec = recordings.first(where: { $0.id == id }) {
            rec.duration = duration
            RecordingStore.save(rec)
        }
        refresh()
        selectedID = id

        // Auto-transcribe if we have a key; otherwise the recording just waits.
        if settings.hasAPIKey {
            if let rec = recordings.first(where: { $0.id == id }) { transcribe(rec) }
        } else {
            showSettings = true
        }
    }

    // MARK: - Transcription

    func transcribe(_ rec: Recording) {
        guard !transcribingIDs.contains(rec.id) else { return }
        guard settings.hasAPIKey else { showSettings = true; return }

        // Clear any prior error so the badge leaves the "Failed" state.
        if var r = recordings.first(where: { $0.id == rec.id }), r.lastError != nil {
            r.lastError = nil
            RecordingStore.save(r)
        }
        transcribingIDs.insert(rec.id)
        refresh()

        let apiKey = settings.apiKey
        let model = settings.effectiveModel
        let context = settings.context

        Task {
            do {
                try await Transcriber.run(rec, apiKey: apiKey, model: model, context: context)
            } catch {
                if var r = recordings.first(where: { $0.id == rec.id }) {
                    r.lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    RecordingStore.save(r)
                }
            }
            transcribingIDs.remove(rec.id)
            refresh()
        }
    }

    // MARK: - List management

    func refresh() {
        recordings = RecordingStore.scan()
        if let sel = selectedID, !recordings.contains(where: { $0.id == sel }) {
            selectedID = recordings.first?.id
        }
    }

    func revealInFinder(_ rec: Recording) {
        NSWorkspace.shared.activateFileViewerSelecting([rec.dir])
    }

    // MARK: - Export

    /// Write the transcript to ~/Downloads/<fileName>.txt and reveal it, so the
    /// user can see where it landed. Never overwrites: a clashing name gets " (2)".
    func saveTranscriptToDownloads(_ rec: Recording, fileName: String) {
        guard let transcript = rec.transcript, !transcript.isEmpty else {
            alert = AppAlert(title: "Nothing to save", message: "This recording has no transcript yet.")
            return
        }
        let fm = FileManager.default
        guard let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            alert = AppAlert(title: "Couldn't save", message: "Your Downloads folder couldn't be found.")
            return
        }

        // Strip the characters a file name can't contain.
        var base = fileName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix(".txt") { base = String(base.dropLast(4)) }
        if base.isEmpty { base = rec.fileDateText }

        var url = downloads.appendingPathComponent("\(base).txt")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = downloads.appendingPathComponent("\(base) (\(n)).txt")
            n += 1
        }

        do {
            try transcript.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            alert = AppAlert(
                title: "Couldn't save the transcript",
                message: "\(error.localizedDescription)\n\nIf macOS is blocking access to your Downloads folder, allow it under System Settings ▸ Privacy & Security ▸ Files and Folders.",
                openSystemSettings: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
        }
    }

    func delete(_ rec: Recording) {
        guard rec.id != currentRecordingID else { return }   // don't delete while recording
        RecordingStore.delete(rec)
        if selectedID == rec.id { selectedID = nil }
        refresh()
    }
}

// A simple alert payload; `openSystemSettings` deep-links to the right pane.
struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var openSystemSettings: String? = nil

    static let micDenied = AppAlert(
        title: "Microphone access needed",
        message: "JakeListen records your microphone to transcribe the meeting. Enable it under System Settings ▸ Privacy & Security ▸ Microphone, then try again.",
        openSystemSettings: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")

    static let systemAudioDenied = AppAlert(
        title: "System audio access needed",
        message: "Without it, only your microphone is captured — the other participants would be missing. Enable JakeListen under System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording, then hit record again.",
        openSystemSettings: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
}
