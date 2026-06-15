// Recording — a single saved call, identified by its base name
// (e.g. "call-2026-06-15_15-25-19"). The CLI writes several files per call:
//   <base>.me.wav        mic audio
//   <base>.others.wav    system / call audio
//   <base>.transcript.txt
//   <base>.summary.txt
// We group them by base name and surface the text files to the UI.

import Foundation

struct Recording: Identifiable, Hashable {
    let id: String          // base name, also the stable identity
    let dir: URL
    let date: Date

    var meURL: URL { dir.appendingPathComponent(id + ".me.wav") }
    var othersURL: URL { dir.appendingPathComponent(id + ".others.wav") }
    var transcriptURL: URL { dir.appendingPathComponent(id + ".transcript.txt") }
    var summaryURL: URL { dir.appendingPathComponent(id + ".summary.txt") }

    private var fm: FileManager { .default }
    var hasTranscript: Bool { fm.fileExists(atPath: transcriptURL.path) }
    var hasSummary: Bool { fm.fileExists(atPath: summaryURL.path) }

    var transcript: String {
        (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""
    }
    var summary: String {
        (try? String(contentsOf: summaryURL, encoding: .utf8)) ?? ""
    }

    /// Human-friendly title from the timestamp, e.g. "Jun 15, 2026 at 3:25 PM".
    var title: String {
        guard date != .distantPast else { return id }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// Short status used in the list row.
    var subtitle: String {
        if hasSummary { return "Summarized" }
        if hasTranscript { return "Transcribed" }
        return "Audio only"
    }

    // MARK: - Scanning

    /// The CLI's recordings directory: ~/JakeListen/recordings
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("JakeListen", isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)
    }

    private static let suffixes = [
        ".me.wav", ".others.wav", ".others.caf",
        ".transcript.txt", ".summary.txt",
    ]

    /// Parse the CLI's "call-yyyy-MM-dd_HH-mm-ss" base name into a Date.
    private static let dateParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "'call-'yyyy-MM-dd'_'HH-mm-ss"
        return f
    }()

    /// Scan the recordings directory and return one Recording per base name,
    /// newest first.
    static func scan() -> [Recording] {
        let dir = directory
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }

        var bases = Set<String>()
        for url in files {
            let name = url.lastPathComponent
            guard name.hasPrefix("call-") else { continue }
            for suffix in suffixes where name.hasSuffix(suffix) {
                bases.insert(String(name.dropLast(suffix.count)))
                break
            }
        }

        return bases
            .map { base in
                Recording(
                    id: base,
                    dir: dir,
                    date: dateParser.date(from: base) ?? .distantPast
                )
            }
            .sorted { $0.date > $1.date }
    }
}
