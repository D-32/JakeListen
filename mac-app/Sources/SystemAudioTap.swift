// SystemAudioTap — captures the Mac's system audio output (the "other side" of a
// meeting: the participants coming out of your speakers) using Core Audio process
// taps. No BlackHole, no Multi-Output device, no third-party anything.
//
// This is the native-capture core lifted from the old `jakelisten-syscap` helper
// and folded straight into the app, so there's no separate binary to ship.
//
// Permission: system-audio recording is gated by the private TCC service
// `kTCCServiceAudioCapture` (the same one AudioCap / Audio Hijack use). We
// preflight it and, when undetermined, request it — which surfaces the one-time
// macOS prompt because the app runs in a real GUI session.

import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

enum SystemAudioPermission { case authorized, denied, undetermined }

enum SystemAudioTapError: Error, CustomStringConvertible {
    case createTap(OSStatus)
    case defaultDevice(OSStatus)
    case aggregate(OSStatus)
    case ioProc(OSStatus)
    case start(OSStatus)
    case format

    var description: String {
        switch self {
        case .createTap(let e):    return "Could not create the system-audio tap (\(e))."
        case .defaultDevice(let e): return "Could not read the default output device (\(e))."
        case .aggregate(let e):    return "Could not create the capture device (\(e))."
        case .ioProc(let e):       return "Could not attach the audio callback (\(e))."
        case .start(let e):        return "Could not start system-audio capture (\(e))."
        case .format:              return "Could not read the tap's audio format."
        }
    }
}

// ---------- TCC permission (private SPI) ----------
private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void
private let tccHandle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

enum SystemAudioAuthorization {
    /// 0 authorized · 1 denied · 2 undetermined · -1 unknown → our enum.
    static func status() -> SystemAudioPermission {
        guard let h = tccHandle, let sym = dlsym(h, "TCCAccessPreflight") else { return .undetermined }
        let preflight = unsafeBitCast(sym, to: PreflightFn.self)
        switch preflight("kTCCServiceAudioCapture" as CFString, nil) {
        case 0:  return .authorized
        case 1:  return .denied
        default: return .undetermined
        }
    }

    /// Fire the system prompt (when undetermined) and return the resolved status.
    static func request() async -> SystemAudioPermission {
        guard let h = tccHandle, let sym = dlsym(h, "TCCAccessRequest") else { return status() }
        let req = unsafeBitCast(sym, to: RequestFn.self)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            req("kTCCServiceAudioCapture" as CFString, nil) { _ in cont.resume() }
        }
        return status()
    }
}

final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "com.jakelisten.syscap.io", qos: .userInitiated)

    private let writer: AudioTrackWriter

    /// Most recent 0…1 level, for the "Meeting" visualiser.
    var level: Float { writer.level }

    init(writer: AudioTrackWriter) {
        self.writer = writer
    }

    func start() throws {
        // Global tap of all output, excluding nothing → the whole system mix.
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDesc.uuid = UUID()
        tapDesc.muteBehavior = .unmuted   // keep the meeting audible through the speakers

        var e = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard e == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
            throw SystemAudioTapError.createTap(e)
        }

        let outputDev = try readDefaultSystemOutputDevice()
        let outputUID = try readDeviceUID(outputDev)

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "JakeListen-SysCap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
            ]],
        ]

        var asbd = try readTapStreamFormat(tapID)
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw SystemAudioTapError.format
        }

        e = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
        guard e == noErr, aggID != AudioObjectID(kAudioObjectUnknown) else {
            throw SystemAudioTapError.aggregate(e)
        }

        let writer = self.writer
        e = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, ioQueue) { _, inInputData, _, _, _ in
            guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                             bufferListNoCopy: inInputData, deallocator: nil) else { return }
            writer.append(buf)
        }
        guard e == noErr else { throw SystemAudioTapError.ioProc(e) }

        e = AudioDeviceStart(aggID, procID)
        guard e == noErr else { throw SystemAudioTapError.start(e) }
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggID, procID)
            AudioDeviceDestroyIOProcID(aggID, procID)
            self.procID = nil
        }
        if aggID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggID); aggID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // ---------- Core Audio property helpers ----------
    private func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let e = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        guard e == noErr else { throw SystemAudioTapError.defaultDevice(e) }
        return dev
    }

    private func readDeviceUID(_ dev: AudioDeviceID) throws -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let e = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0)
        }
        guard e == noErr else { throw SystemAudioTapError.defaultDevice(e) }
        return uid as String
    }

    private func readTapStreamFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let e = withUnsafeMutablePointer(to: &asbd) {
            AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, $0)
        }
        guard e == noErr else { throw SystemAudioTapError.format }
        return asbd
    }
}
