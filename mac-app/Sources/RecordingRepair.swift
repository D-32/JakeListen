// RecordingRepair — turns the raw capture files into the .m4a files the rest of
// the app expects, and rescues the ones left behind when the app dies.
//
// WHY THIS EXISTS
//
// Capture writes uncompressed WAV, not AAC. AAC in an .m4a only becomes readable
// when the file is *closed* — that is when the sample index (the `moov` atom) is
// written. Kill the app mid-recording and you get a file full of perfectly good
// audio that nothing on earth can open, and Gemini answers 400 INVALID_ARGUMENT.
// We lost whole meetings that way.
//
// A WAV that is never closed loses nothing but two length fields in its header.
// The samples are already on disk, byte for byte. So we capture to WAV, repair
// the header if the app didn't get to close it, and compress to .m4a afterwards —
// at the end of a recording, or on the next launch if there wasn't one.
//
// The cost is disk while recording: 16 kHz mono 16-bit is ~115 MB per hour per
// track, ~230 MB for both, deleted as soon as the .m4a exists.

import AVFoundation

enum RecordingRepair {

    enum RepairError: LocalizedError {
        case notAWave(URL)
        case noData(URL)
        case emptyAudio(URL)
        var errorDescription: String? {
            switch self {
            case .notAWave(let u):   return "\(u.lastPathComponent) is not a WAVE file."
            case .noData(let u):     return "\(u.lastPathComponent) has no audio chunk."
            case .emptyAudio(let u): return "\(u.lastPathComponent) contains no audio."
            }
        }
    }

    // MARK: - Finalizing a recording

    /// Compress whatever raw tracks `rec` still has into their .m4a counterparts
    /// and delete the raw files. Safe to call twice: tracks that are already
    /// converted are skipped. Returns the longest track's duration in seconds, so
    /// a recording recovered after a crash can be given back its real length
    /// (the crash means `stop()` never ran and meta.json still says 0).
    @discardableResult
    static func finalize(_ rec: Recording) throws -> TimeInterval {
        var longest: TimeInterval = 0
        for (wav, m4a) in [(rec.meWavURL, rec.meURL), (rec.othersWavURL, rec.othersURL)] {
            guard FileManager.default.fileExists(atPath: wav.path) else { continue }
            do {
                try repairWaveHeaderIfNeeded(wav)
                longest = max(longest, try compress(wav: wav, to: m4a))
                try? FileManager.default.removeItem(at: wav)
            } catch RepairError.emptyAudio {
                // The track never captured anything. Drop the empty raw file so we
                // don't retry it on every launch; the other track may still be fine.
                try? FileManager.default.removeItem(at: wav)
            }
        }
        return longest
    }

    /// True when `rec` still has raw tracks waiting to be compressed — i.e. the
    /// app was killed mid-recording and never got to finish the job.
    static func needsFinalizing(_ rec: Recording) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: rec.meWavURL.path) || fm.fileExists(atPath: rec.othersWavURL.path)
    }

    // MARK: - WAV header repair

    /// A WAV written by AVAudioFile carries the RIFF and `data` lengths that were
    /// correct when the file was *closed*. If the process died first they are
    /// stale — usually 0 — and every decoder reports a 0-second file even though
    /// all the samples are there. Patch both lengths to match what's on disk.
    static func repairWaveHeaderIfNeeded(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        let fileSize = Int(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        guard let head = try handle.read(upToCount: min(fileSize, 64 * 1024)), head.count >= 44,
              head.prefix(4) == Data("RIFF".utf8), head[8..<12] == Data("WAVE".utf8) else {
            throw RepairError.notAWave(url)
        }

        func u32(_ at: Int) -> Int {
            Int(head[at]) | Int(head[at + 1]) << 8 | Int(head[at + 2]) << 16 | Int(head[at + 3]) << 24
        }

        // Walk the chunk list for `data`, noting the block alignment from `fmt `
        // so a file cut mid-sample is trimmed to a whole frame.
        var blockAlign = 2
        var dataStart = -1
        var declared = 0
        var i = 12
        while i + 8 <= head.count {
            let id = head[i..<(i + 4)]
            let size = u32(i + 4)
            if id == Data("fmt ".utf8), i + 8 + 16 <= head.count {
                let align = Int(head[i + 8 + 12]) | Int(head[i + 8 + 13]) << 8
                if align > 0 { blockAlign = align }
            }
            if id == Data("data".utf8) {
                dataStart = i + 8
                declared = size
                break
            }
            if size <= 0 { break }
            i += 8 + size + (size & 1)
        }
        guard dataStart >= 0 else { throw RepairError.noData(url) }

        let actual = ((fileSize - dataStart) / blockAlign) * blockAlign
        guard actual > 0 else { throw RepairError.emptyAudio(url) }
        // Already consistent — this file was closed properly, leave it alone.
        if declared == actual && u32(4) == fileSize - 8 { return }

        func le32(_ v: Int) -> Data {
            Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
        }
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: le32(fileSize - 8))
        try handle.seek(toOffset: UInt64(dataStart - 4))
        try handle.write(contentsOf: le32(actual))
        try handle.synchronize()
    }

    // MARK: - WAV → m4a

    /// Compress a raw track to AAC in an .m4a — the small, Gemini-friendly file
    /// the rest of the app works with. Returns its duration in seconds.
    @discardableResult
    static func compress(wav: URL, to m4a: URL) throws -> TimeInterval {
        let input = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard input.length > 0 else { throw RepairError.emptyAudio(wav) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: input.fileFormat.sampleRate,
            AVNumberOfChannelsKey: input.fileFormat.channelCount,
        ]
        // Write beside the target and move into place at the end, so an
        // interrupted compression can never leave a half-written .m4a behind.
        // Keep the .m4a extension — AVAudioFile picks the container from it.
        let temp = m4a.deletingLastPathComponent()
            .appendingPathComponent(".partial-\(m4a.lastPathComponent)")
        try? FileManager.default.removeItem(at: temp)

        var output: AVAudioFile? = try AVAudioFile(forWriting: temp, settings: settings,
                                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 32_768) else {
            throw RepairError.emptyAudio(wav)
        }
        // Drive the loop from framePosition: AVAudioFile.read throws at EOF rather
        // than returning an empty buffer, so "read until empty" never terminates
        // cleanly.
        while input.framePosition < input.length {
            let remaining = AVAudioFrameCount(input.length - input.framePosition)
            try input.read(into: buffer, frameCount: min(buffer.frameCapacity, remaining))
            guard buffer.frameLength > 0 else { break }
            try output?.write(from: buffer)
        }
        output = nil                       // closing is what writes the index

        try? FileManager.default.removeItem(at: m4a)
        try FileManager.default.moveItem(at: temp, to: m4a)
        return Double(input.length) / input.fileFormat.sampleRate
    }
}
