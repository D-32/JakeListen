// AudioTrackWriter — writes one audio track to a compact .m4a (AAC) file and
// reports a live 0…1 level for the visualiser.
//
// Incoming buffers arrive in whatever format the source uses (the mic node's
// 48 kHz stereo, the system-tap's stereo float, …). We convert everything down
// to 16 kHz mono on the way to disk: the files stay tiny, and 16 kHz mono is
// exactly what Gemini downsamples audio to anyway — so nothing is lost.
//
// Each writer is fed from a single audio thread (its mic tap or the syscap IO
// queue), so no internal locking is needed.

import AVFoundation

final class AudioTrackWriter {
    /// The most recent normalized level (0…1), for the meter. Read from the UI.
    private(set) var level: Float = 0

    private let target: AVAudioFormat
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?

    init(url: URL) throws {
        // 16 kHz mono float — the format we hand to both the converter and file.
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 16_000, channels: 1, interleaved: false) else {
            throw NSError(domain: "JakeListen", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not build 16 kHz mono format"])
        }
        target = fmt

        // AAC in an .m4a container — small files that Gemini accepts directly.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Convert one source buffer to 16 kHz mono, append it, and update `level`.
    func append(_ source: AVAudioPCMBuffer) {
        guard let file else { return }

        // Lazily build the converter once we know the source format.
        if converter == nil || converter?.inputFormat != source.format {
            converter = AVAudioConverter(from: source.format, to: target)
        }
        guard let converter else { return }

        let ratio = target.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var fed = false
        var convError: NSError?
        converter.convert(to: out, error: &convError) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return source
        }
        guard convError == nil, out.frameLength > 0 else { return }

        level = Self.normalizedLevel(out)
        try? file.write(from: out)
    }

    /// Flush and close the file.
    func finish() {
        file = nil
        level = 0
    }

    // RMS → a friendly 0…1 meter value via a dB mapping (~-50 dB floor).
    private static func normalizedLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { let s = ch[i]; sum += s * s }
        let rms = (sum / Float(n)).squareRoot()
        if rms <= 0 { return 0 }
        let db = 20 * log10(rms)               // ~ -inf … 0
        let clamped = max(-50, min(0, db))
        return (clamped + 50) / 50             // 0 … 1
    }
}
