// AudioMeter — a live microphone input meter for the GUI.
//
// The CLI does the real recording (ffmpeg for the mic, the Core Audio tap for
// the call). This class taps the default input device *in parallel*, purely to
// measure how loud the mic is right now. Core Audio lets several clients read
// the same input device, so running alongside the CLI's ffmpeg is fine — we
// never write any audio anywhere, we only compute levels for the meter.
//
// Why: without this, the only feedback while recording is an elapsed timer,
// which keeps ticking even if the mic is muted, unplugged, or grabbing silence.
// A flat meter tells you *immediately* that nothing is being recorded.

import AVFoundation
import Combine
import SwiftUI

final class AudioMeter: ObservableObject {
    /// Smoothed current level, 0 (silence) … 1 (loud). Drives the level read-out.
    @Published var level: Float = 0
    /// Recent level history (oldest → newest) for the scrolling waveform bars.
    @Published private(set) var history: [Float] = Array(repeating: 0, count: barCount)
    /// True after a sustained stretch of near-silence — surfaces the warning.
    @Published private(set) var noSignal = false
    /// Set if the meter couldn't start (no device, permission denied, …).
    @Published private(set) var error: String?

    static let barCount = 56

    private let engine = AVAudioEngine()
    private var running = false
    private var silentBuffers = 0

    // ~21 buffers/sec at 44.1 kHz with a 2048-frame buffer, so these are
    // roughly: anything below -36 dBFS counts as silence, and ~2s of it warns.
    private let silenceThreshold: Float = 0.05
    private let silenceLimit = 40

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        error = nil
        noSignal = false
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginTap()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.beginTap() }
                    else { self?.fail("Microphone access denied") }
                }
            }
        default:
            fail("Microphone access denied — enable it in System Settings ▸ Privacy")
        }
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        level = 0
        noSignal = false
        history = Array(repeating: 0, count: Self.barCount)
    }

    // MARK: - Internals

    private func fail(_ message: String) {
        error = message
        noSignal = false
    }

    private func beginTap() {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        // A zero sample rate / channel count means there's no usable input.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail("No microphone input available")
            return
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        do {
            try engine.start()
            running = true
        } catch {
            fail("Couldn't start audio meter: \(error.localizedDescription)")
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        var sum: Float = 0
        for i in 0..<frames {
            let s = channel[i]
            sum += s * s
        }
        let rms = sqrtf(sum / Float(frames))
        // Map RMS to a friendly 0…1 scale with a -60 dBFS noise floor.
        let db = 20 * log10f(max(rms, 1e-7))
        let norm = max(0, min(1, (db + 60) / 60))

        DispatchQueue.main.async {
            // VU-style ballistics: jump up instantly, ease back down.
            self.level = norm > self.level ? norm : self.level * 0.8 + norm * 0.2

            var h = self.history
            h.removeFirst()
            h.append(norm)
            self.history = h

            if norm >= self.silenceThreshold {
                self.silentBuffers = 0
                if self.noSignal { self.noSignal = false }
            } else {
                self.silentBuffers += 1
                if self.silentBuffers >= self.silenceLimit && !self.noSignal {
                    self.noSignal = true
                }
            }
        }
    }
}
