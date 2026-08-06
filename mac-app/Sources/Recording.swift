// Recording — one meeting on disk, plus the store that scans/creates them.
//
// Layout:  ~/Library/Application Support/JakeListen/Recordings/<id>/
//   me.m4a          your microphone
//   others.m4a      the meeting / system audio
//   meta.json       title, createdAt, duration, lastError
//   transcript.txt  written once transcription succeeds
//   summary.txt     written once summarising succeeds
//   title.txt       a short AI-generated meeting title (best-effort)
//
// A recording exists the moment capture stops — before any transcription — so a
// failed or never-run transcription is always visible with a Retry button. The
// display status is derived from what's on disk, so it survives app restarts.

import Foundation

enum RecordingStatus {
    case recording        // capture in progress (in-memory only)
    case notTranscribed   // audio captured, no transcript yet
    case transcribing     // in-flight (in-memory only)
    case done             // transcript present
    case failed           // a transcription attempt errored

    var label: String {
        switch self {
        case .recording:      return "Recording…"
        case .notTranscribed: return "Not transcribed"
        case .transcribing:   return "Transcribing…"
        case .done:           return "Done"
        case .failed:         return "Failed"
        }
    }
}

struct Recording: Identifiable, Equatable {
    let id: String          // the folder name / timestamp key
    let dir: URL
    var title: String       // the date-based fallback title ("6 Aug 2026 at 14:03")
    var meetingTitle: String?   // short AI-generated title, once transcribed
    var createdAt: Date
    var duration: TimeInterval
    var lastError: String?

    var meURL: URL         { dir.appendingPathComponent("me.m4a") }
    var othersURL: URL     { dir.appendingPathComponent("others.m4a") }
    var transcriptURL: URL { dir.appendingPathComponent("transcript.txt") }
    var summaryURL: URL    { dir.appendingPathComponent("summary.txt") }
    var titleURL: URL      { dir.appendingPathComponent("title.txt") }
    var metaURL: URL       { dir.appendingPathComponent("meta.json") }

    /// What the sidebar and the detail header show: the meeting title if Gemini
    /// gave us one, otherwise the date.
    var displayTitle: String { meetingTitle?.isEmpty == false ? meetingTitle! : title }

    /// "6 Aug 2026 at 14:03" — always shown, even when a meeting title exists.
    var dateText: String { RecordingStore.dateText(for: createdAt) }

    /// "2026-08-06" — the date as it appears in an exported file name.
    var fileDateText: String { RecordingStore.fileDateText(for: createdAt) }

    /// Default name for "Save transcript…": date + title, no extension.
    var exportBaseName: String {
        let t = meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? fileDateText : "\(fileDateText) - \(t)"
    }

    var hasTranscript: Bool {
        (try? String(contentsOf: transcriptURL, encoding: .utf8))?.isEmpty == false
    }
    var transcript: String? { try? String(contentsOf: transcriptURL, encoding: .utf8) }
    var summary: String?    { try? String(contentsOf: summaryURL, encoding: .utf8) }

    /// Status from disk alone (the store/model overlays `.transcribing` while in flight).
    var baseStatus: RecordingStatus {
        if hasTranscript { return .done }
        if lastError != nil { return .failed }
        return .notTranscribed
    }

    var durationText: String {
        let s = Int(duration.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func == (a: Recording, b: Recording) -> Bool {
        a.id == b.id && a.lastError == b.lastError && a.duration == b.duration
            && a.title == b.title && a.meetingTitle == b.meetingTitle
    }
}

// meta.json shape.
private struct Meta: Codable {
    var title: String
    var createdAt: Date
    var duration: TimeInterval
    var lastError: String?
}

enum RecordingStore {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JakeListen/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static let idFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// "2026-08-06" — used in exported file names.
    private static let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dateText(for date: Date) -> String { titleFormatter.string(from: date) }
    static func fileDateText(for date: Date) -> String { fileDateFormatter.string(from: date) }

    /// Create a fresh, empty recording folder + initial meta, ready to record into.
    static func create(now: Date = Date()) -> Recording {
        let id = idFormatter.string(from: now)
        let dir = directory.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rec = Recording(id: id, dir: dir, title: titleFormatter.string(from: now),
                            meetingTitle: nil, createdAt: now, duration: 0, lastError: nil)
        save(rec)
        return rec
    }

    static func save(_ rec: Recording) {
        let meta = Meta(title: rec.title, createdAt: rec.createdAt,
                        duration: rec.duration, lastError: rec.lastError)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(meta) { try? data.write(to: rec.metaURL) }
    }

    static func scan() -> [Recording] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var out: [Recording] = []
        for dir in dirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let id = dir.lastPathComponent
            let metaURL = dir.appendingPathComponent("meta.json")
            let meta = (try? Data(contentsOf: metaURL)).flatMap { try? dec.decode(Meta.self, from: $0) }
            // Tolerate a missing/garbled meta.json — still surface the recording.
            let created = meta?.createdAt ?? (idFormatter.date(from: id) ?? Date())
            let meetingTitle = (try? String(contentsOf: dir.appendingPathComponent("title.txt"),
                                            encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(Recording(
                id: id, dir: dir,
                title: meta?.title ?? titleFormatter.string(from: created),
                meetingTitle: (meetingTitle?.isEmpty == false) ? meetingTitle : nil,
                createdAt: created,
                duration: meta?.duration ?? 0,
                lastError: meta?.lastError))
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    static func delete(_ rec: Recording) {
        try? FileManager.default.trashItem(at: rec.dir, resultingItemURL: nil)
    }
}
