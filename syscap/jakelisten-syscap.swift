// jakelisten-syscap — capture macOS system audio output (the "other side" of a
// call) using Core Audio process taps (macOS 14.2+). No BlackHole, no Multi-Output
// device. Writes a CAF file; JakeListen post-processes it to 16 kHz mono.
//
// Usage:  jakelisten-syscap <output.caf>
// Stops on: SIGINT, SIGTERM, a "q" on stdin, or stdin EOF.
//
// Exit codes: 0 ok · 2 bad args · 3 permission denied · 4 capture setup failed

import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

extension String: @retroactive Error {}

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// ---------- TCC permission (private SPI, same approach as insidegui/AudioCap) ----------
// kTCCServiceAudioCapture is the service gating system-audio recording.
typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

let tccHandle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

// Returns the TCC preflight status: 0 authorized, 1 denied, 2 undetermined, -1 unknown.
func audioCapturePreflight() -> Int {
	guard let h = tccHandle, let psym = dlsym(h, "TCCAccessPreflight") else { return -1 }
	let preflight = unsafeBitCast(psym, to: PreflightFn.self)
	return preflight("kTCCServiceAudioCapture" as CFString, nil)
}

// Fire the TCC request so the system prompt appears (interactive sessions only).
// Returns whether it was granted; callers may still proceed and let the tap be the
// real gate, since the prompt can't appear in a non-interactive context.
@discardableResult
func requestAudioCapturePermission() -> Bool {
	guard let h = tccHandle, let rsym = dlsym(h, "TCCAccessRequest") else { return true }
	let request = unsafeBitCast(rsym, to: RequestFn.self)
	let sem = DispatchSemaphore(value: 0)
	var granted = false
	DispatchQueue.global().async {
		request("kTCCServiceAudioCapture" as CFString, nil) { ok in granted = ok; sem.signal() }
	}
	sem.wait()
	return granted
}

// ---------- Core Audio property helpers ----------
func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
	var addr = AudioObjectPropertyAddress(
		mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
		mScope: kAudioObjectPropertyScopeGlobal,
		mElement: kAudioObjectPropertyElementMain)
	var dev = AudioDeviceID(kAudioObjectUnknown)
	var size = UInt32(MemoryLayout<AudioDeviceID>.size)
	let e = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
	guard e == noErr else { throw "default output read failed: \(e)" }
	return dev
}

func readDeviceUID(_ dev: AudioDeviceID) throws -> String {
	var addr = AudioObjectPropertyAddress(
		mSelector: kAudioDevicePropertyDeviceUID,
		mScope: kAudioObjectPropertyScopeGlobal,
		mElement: kAudioObjectPropertyElementMain)
	var uid = "" as CFString
	var size = UInt32(MemoryLayout<CFString>.size)
	let e = withUnsafeMutablePointer(to: &uid) {
		AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0)
	}
	guard e == noErr else { throw "device UID read failed: \(e)" }
	return uid as String
}

func readTapStreamFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
	var addr = AudioObjectPropertyAddress(
		mSelector: kAudioTapPropertyFormat,
		mScope: kAudioObjectPropertyScopeGlobal,
		mElement: kAudioObjectPropertyElementMain)
	var asbd = AudioStreamBasicDescription()
	var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
	let e = withUnsafeMutablePointer(to: &asbd) {
		AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, $0)
	}
	guard e == noErr else { throw "tap format read failed: \(e)" }
	return asbd
}

// ---------- main ----------
let argv = CommandLine.arguments
guard argv.count >= 2 else {
	err("usage: jakelisten-syscap <output.caf>  |  jakelisten-syscap --check-permission")
	exit(2)
}

// Permission-check / grant mode: triggers the system prompt when run interactively.
if argv[1] == "--check-permission" {
	let pre = audioCapturePreflight()
	if pre == 0 { print("authorized"); exit(0) }
	let granted = requestAudioCapturePermission()
	if granted || audioCapturePreflight() == 0 { print("authorized"); exit(0) }
	print("denied")
	exit(3)
}

let outURL = URL(fileURLWithPath: argv[1])

// Best-effort: if not already authorized, fire the request so the prompt appears.
// We don't hard-fail on a negative result — the tap below is the real gate, and the
// SPI can report a spurious denial in non-interactive contexts.
if audioCapturePreflight() != 0 {
	if !requestAudioCapturePermission() && audioCapturePreflight() != 0 {
		err("warning: system audio recording not granted yet; capture may be silent. " +
			"Run `jakelisten permission` once in your Terminal and click Allow.")
	}
}

var tapID = AudioObjectID(kAudioObjectUnknown)
var aggID = AudioObjectID(kAudioObjectUnknown)
var procID: AudioDeviceIOProcID?

do {
	// Global tap of all output, excluding nothing → the whole system mix (the call).
	let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
	tapDesc.uuid = UUID()
	tapDesc.muteBehavior = .unmuted // keep playing the call through the speakers

	var e = AudioHardwareCreateProcessTap(tapDesc, &tapID)
	guard e == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
		err("capture-failed: could not create process tap (\(e)).")
		exit(4)
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
	guard let format = AVAudioFormat(streamDescription: &asbd) else { throw "could not build AVAudioFormat" }

	e = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
	guard e == noErr, aggID != AudioObjectID(kAudioObjectUnknown) else {
		err("capture-failed: could not create aggregate device (\(e)).")
		exit(4)
	}

	let settings: [String: Any] = [
		AVFormatIDKey: asbd.mFormatID,
		AVSampleRateKey: format.sampleRate,
		AVNumberOfChannelsKey: format.channelCount,
	]
	let file = try AVAudioFile(forWriting: outURL, settings: settings,
		commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)

	let ioQueue = DispatchQueue(label: "jakelisten.syscap.io", qos: .userInitiated)
	e = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, ioQueue) {
		_, inInputData, _, _, _ in
		guard let buf = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil)
		else { return }
		try? file.write(from: buf)
	}
	guard e == noErr else { err("capture-failed: could not create I/O proc (\(e))."); exit(4) }

	e = AudioDeviceStart(aggID, procID)
	guard e == noErr else { err("capture-failed: could not start device (\(e))."); exit(4) }

	err("syscap: recording system audio → \(outURL.lastPathComponent) " +
		"(\(Int(format.sampleRate)) Hz, \(format.channelCount)ch)")

	// ---------- wait for a stop signal ----------
	let stop = DispatchSemaphore(value: 0)
	signal(SIGINT, SIG_IGN)
	signal(SIGTERM, SIG_IGN)
	let sigQ = DispatchQueue(label: "jakelisten.syscap.sig")
	let sigInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: sigQ)
	let sigTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: sigQ)
	sigInt.setEventHandler { stop.signal() }
	sigTerm.setEventHandler { stop.signal() }
	sigInt.resume()
	sigTerm.resume()

	// Also stop on "q" or EOF from stdin (lets the parent stop us cleanly).
	FileHandle.standardInput.readabilityHandler = { h in
		let d = h.availableData
		if d.isEmpty || d.contains(UInt8(ascii: "q")) { stop.signal() }
	}

	stop.wait()
	err("syscap: stopping…")
} catch {
	err("capture-failed: \(error)")
	exit(4)
}

// ---------- teardown (flushes the file) ----------
if let procID {
	AudioDeviceStop(aggID, procID)
	AudioDeviceDestroyIOProcID(aggID, procID)
}
if aggID != AudioObjectID(kAudioObjectUnknown) { AudioHardwareDestroyAggregateDevice(aggID) }
if tapID != AudioObjectID(kAudioObjectUnknown) { AudioHardwareDestroyProcessTap(tapID) }
err("syscap: done")
exit(0)
