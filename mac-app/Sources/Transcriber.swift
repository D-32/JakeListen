// Transcriber — turns a recording's two audio tracks into a merged, speaker-
// labelled transcript and a short summary, using Gemini.
//
// Both tracks are uploaded and sent in a single request so Gemini can label the
// mic track as "Me" and diarize the other participants, interleaving everything
// in the order it was said. The transcript is written to disk BEFORE summarising,
// so a summary failure never loses the transcript. The summary and the short
// meeting title (title.txt, shown in the sidebar) are both best-effort.

import Foundation

enum TranscriberError: LocalizedError {
    case noAudio
    case emptyTranscript
    var errorDescription: String? {
        switch self {
        case .noAudio: return "The recording's audio files are missing."
        case .emptyTranscript: return "No speech was detected in this recording."
        }
    }
}

enum Transcriber {
    /// Transcribe + summarise `rec`, writing transcript.txt (and summary.txt) into
    /// its folder. Throws on failure (leaving the recording intact for a retry).
    static func run(_ rec: Recording, apiKey: String, model: String, context: String) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rec.meURL.path) || fm.fileExists(atPath: rec.othersURL.path) else {
            throw TranscriberError.noAudio
        }

        let client = GeminiClient(apiKey: apiKey)

        // Upload both tracks concurrently.
        async let meUpload = client.upload(fileURL: rec.meURL)
        async let othersUpload = client.upload(fileURL: rec.othersURL)
        let (me, others) = try await (meUpload, othersUpload)

        let ctx = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let contextLine = ctx.isEmpty ? "" :
            "\n\nDomain context (use it to spell names and jargon correctly):\n\(ctx)"

        let prompt = """
        You are given two audio tracks recorded at the same time during one meeting.
        • Track A is MY microphone — everything in it is spoken by me; always label me as "Me".
        • Track B is the other participants (the meeting's system audio). Diarize it: give \
        each distinct voice a stable label, using a person's real name when it is spoken or \
        they are addressed by name, otherwise "Speaker 1", "Speaker 2", and so on.

        Produce ONE merged, chronological transcript of the whole meeting, interleaving both \
        tracks in the order things were actually said. Transcribe verbatim in the spoken \
        language. Output ONLY transcript lines, one utterance per line, in exactly this format:
        Name: what they said
        No timestamps, no commentary, no headers, no summary.\(contextLine)
        """

        let parts: [[String: Any]] = [
            GeminiClient.textPart(prompt),
            GeminiClient.textPart("Track A — my microphone:"),
            GeminiClient.filePart(me),
            GeminiClient.textPart("Track B — the other participants:"),
            GeminiClient.filePart(others),
        ]

        let transcript = try await client.generate(model: model, parts: parts, temperature: 0)
        guard !transcript.isEmpty else { throw TranscriberError.emptyTranscript }

        // Save immediately — a summarise failure must not lose the transcript.
        try transcript.write(to: rec.transcriptURL, atomically: true, encoding: .utf8)

        // A short title for the sidebar and for exported file names. Best-effort:
        // a separate, cheap call, so a bad title never costs us the transcript.
        let titlePrompt = """
        Below is a transcript of a meeting. Reply with a short title for it — what the \
        meeting was about, at most 6 words. Use the transcript's own language. Plain text \
        only: no quotes, no trailing period, no file-path characters (/ or :), no prefix \
        like "Title:". Reply with nothing but the title.

        Transcript:
        \(transcript)
        """
        if let raw = try? await client.generate(
            model: model, parts: [GeminiClient.textPart(titlePrompt)], temperature: 0.2) {
            let title = sanitizeTitle(raw)
            if !title.isEmpty {
                try? title.write(to: rec.titleURL, atomically: true, encoding: .utf8)
            }
        }

        // Summary is best-effort.
        let summaryPrompt = """
        Below is a transcript of a meeting. Write a concise summary for a teammate who missed it.
        Start with a one-sentence overview, then short bullet lists for Participants, Key points, \
        Decisions, and Action items (each as owner → task). Skip any section that has nothing. \
        Keep it tight.

        Transcript:
        \(transcript)
        """
        if let summary = try? await client.generate(
            model: model, parts: [GeminiClient.textPart(summaryPrompt)], temperature: 0.3),
           !summary.isEmpty {
            try? summary.write(to: rec.summaryURL, atomically: true, encoding: .utf8)
        }
    }

    /// Keep only the first line, strip quotes/stray punctuation, and drop the
    /// characters that can't live in a file name. Capped so a rambling model
    /// answer can't become a 500-character sidebar row.
    private static func sanitizeTitle(_ raw: String) -> String {
        var t = raw.components(separatedBy: .newlines).first ?? ""
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”.:-–— "))
        t = t.replacingOccurrences(of: "/", with: "-")
             .replacingOccurrences(of: ":", with: " -")
        if t.count > 80 { t = String(t.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return t
    }
}
