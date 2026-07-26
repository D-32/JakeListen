// AudioRecorder — captures both sides of a meeting to two .m4a files:
//   • me.m4a      → your microphone (AVAudioEngine input tap)
//   • others.m4a  → the meeting/system audio (SystemAudioTap, Core Audio taps)
//
// It exposes two live 0…1 levels so the UI can show a visualiser for each source
// and you can *see* both are being picked up. Nothing here talks to the network;
// transcription is a separate step so a recording is always saved first.

import Foundation
import AVFoundation
import Combine

@MainActor
final class AudioRecorder: ObservableObject {
    enum State: Equatable { case idle, recording }

    @Published private(set) var state: State = .idle
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var elapsed: TimeInterval = 0

    private let engine = AVAudioEngine()
    private var micWriter: AudioTrackWriter?
    private var sysWriter: AudioTrackWriter?
    private var systemTap: SystemAudioTap?
    private var meter: Timer?
    private var startedAt: Date?

    // MARK: - Permissions

    static func micAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMic() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: - Control

    /// Begin capturing to the two given file URLs. Throws if either source can't start.
    func start(meURL: URL, othersURL: URL) throws {
        guard state == .idle else { return }

        let mic = try AudioTrackWriter(url: meURL)
        let sys = try AudioTrackWriter(url: othersURL)
        micWriter = mic
        sysWriter = sys

        // System audio first — if it can't start, don't leave a half-open mic file.
        let tap = SystemAudioTap(writer: sys)
        do {
            try tap.start()
        } catch {
            mic.finish(); sys.finish()
            micWriter = nil; sysWriter = nil
            try? FileManager.default.removeItem(at: meURL)
            try? FileManager.default.removeItem(at: othersURL)
            throw error
        }
        systemTap = tap

        // Microphone via the engine's input node.
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            mic.append(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tap.stop()
            mic.finish(); sys.finish()
            micWriter = nil; sysWriter = nil; systemTap = nil
            try? FileManager.default.removeItem(at: meURL)
            try? FileManager.default.removeItem(at: othersURL)
            throw error
        }

        startedAt = Date()
        elapsed = 0
        state = .recording
        startMeter()
    }

    /// Stop capturing and flush both files. Returns the recording's duration.
    @discardableResult
    func stop() -> TimeInterval {
        guard state == .recording else { return 0 }
        meter?.invalidate(); meter = nil

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        systemTap?.stop(); systemTap = nil
        micWriter?.finish(); micWriter = nil
        sysWriter?.finish(); sysWriter = nil

        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? elapsed
        startedAt = nil
        micLevel = 0; systemLevel = 0
        state = .idle
        return duration
    }

    // MARK: - Meter

    private func startMeter() {
        // IMPORTANT: add to `.common` modes, not the default mode. A default-mode
        // timer stops firing while the main run loop is in event-tracking mode
        // (clicking, dragging, scrolling, resizing, sidebar selection), which made
        // the meters and timer freeze whenever you touched the window mid-recording.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            // Fires on the main run loop, so we're already on the main actor.
            MainActor.assumeIsolated {
                guard let self, self.state == .recording else { return }
                // Ease toward the raw level so the bars glide rather than flicker.
                self.micLevel += (( self.micWriter?.level ?? 0) - self.micLevel) * 0.4
                self.systemLevel += ((self.sysWriter?.level ?? 0) - self.systemLevel) * 0.4
                if let started = self.startedAt { self.elapsed = Date().timeIntervalSince(started) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meter = timer
    }
}
