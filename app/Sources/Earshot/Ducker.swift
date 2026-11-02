import AudioToolbox
import CoreAudio
import Foundation

/// Turns every other app down while Earshot speaks, then back up.
///
/// A Core Audio process tap captures all audio except Earshot's own, muted at
/// the source while the tap is being read ("muted when tapped"); an aggregate
/// device re-plays it at a lower gain on the same output. Stopping the IO proc
/// hands the apps straight back to the hardware, so a crash can't leave them silent.
/// Needs the one-time "record this computer's audio" permission (macOS 14.2+).
@MainActor
final class Ducker {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let gain = Gain()
    private(set) var active = false
    /// Set after a failure (e.g. permission denied) so callers can fall back to pausing.
    private(set) var unavailable = false

    /// Shared with the real-time IO thread.
    final class Gain: @unchecked Sendable {
        var current: Float = 1
        var target: Float = 1
        /// Per-sample step: a ~150 ms ramp at 48 kHz.
        let step: Float = 1.0 / 7200
    }

    /// True while the tap and aggregate device exist (including the idle linger).
    private var built: Bool { aggregateID != kAudioObjectUnknown }

    /// Ducks other audio to `level` (0…1). Returns false when ducking isn't possible.
    /// `freshlyBuilt` tells the caller the output was just reconfigured, so it
    /// should give the device a moment before starting speech.
    @discardableResult
    func duck(to level: Double, freshlyBuilt: UnsafeMutablePointer<Bool>? = nil) -> Bool {
        gain.target = Float(max(0, min(level, 1)))
        if active { return true }
        if built {
            active = true  // reuse the lingering tap: no device reconfiguration
            return true
        }
        guard !unavailable else { return false }
        do {
            try build()
            freshlyBuilt?.pointee = true
            active = true
            Log.write("duck: other audio at \(Int(level * 100))%")
            return true
        } catch {
            Log.write("duck: unavailable (\(error)) — falling back to pausing")
            teardown()
            // A missing permission or API failure sticks; a timing problem doesn't.
            unavailable = (error as? Failure)?.retryable != true
            return false
        }
    }

    /// Fades other audio back up. The tap lingers (passing audio through at
    /// full volume) for a while, so the next reading doesn't reconfigure the
    /// output device — that reconfiguration is what swallowed first words.
    func release() {
        guard active else { return }
        gain.target = 1
        active = false
        releaseToken += 1
        let token = releaseToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, !self.active, token == self.releaseToken else { return }
            self.teardown()
            Log.write("duck: released")
        }
    }

    private var releaseToken = 0

    /// Built and idle, passing audio through at full volume.
    var isLingering: Bool { built && !active }

    /// Lets a later attempt try again (e.g. after the user grants permission).
    func resetAvailability() { unavailable = false }

    private struct Failure: Error, CustomStringConvertible {
        var description: String
        var retryable = false
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw Failure(description: "\(what) failed (\(status))") }
    }

    private func build() throws {
        // Everything except Earshot itself.
        var pid = ProcessInfo.processInfo.processIdentifier
        var me = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &me)
        // Without our own process object the tap would swallow Earshot's speech too.
        guard me != kAudioObjectUnknown else { throw Failure(description: "Earshot has no audio process yet", retryable: true) }
        let excluded = [me]

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.name = "Earshot ducking"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create tap")

        let outputID = CoreAudioQuery.defaultOutputID
        guard let outputUID = CoreAudioQuery.string(outputID, kAudioDevicePropertyDeviceUID) else {
            throw Failure(description: "no output device")
        }
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Earshot Duck",
            kAudioAggregateDeviceUIDKey: "dev.naman.earshot.duck.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID), "create aggregate")

        let gain = self.gain
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
            Self.mix(input, into: output, gain: gain)
        }
        try check(status, "create IO proc")
        try check(AudioDeviceStart(aggregateID, procID), "start")
    }

    /// Copies the tapped audio to the output at the ramped gain (real-time thread).
    nonisolated private static func mix(_ input: UnsafePointer<AudioBufferList>, into output: UnsafeMutablePointer<AudioBufferList>, gain: Gain) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outs = UnsafeMutableAudioBufferListPointer(output)
        guard ins.count > 0 else { return }
        var g = gain.current
        for (i, out) in outs.enumerated() {
            guard let dst = out.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let src = ins[min(i, ins.count - 1)]
            let n = Int(min(out.mDataByteSize, src.mDataByteSize)) / MemoryLayout<Float>.size
            let outN = Int(out.mDataByteSize) / MemoryLayout<Float>.size
            g = gain.current
            if let s = src.mData?.assumingMemoryBound(to: Float.self) {
                for k in 0..<n {
                    if g < gain.target { g = min(g + gain.step, gain.target) } else if g > gain.target { g = max(g - gain.step, gain.target) }
                    dst[k] = s[k] * g
                }
            }
            if outN > n { (dst + n).update(repeating: 0, count: outN - n) }
        }
        gain.current = g
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        gain.current = 1
    }
}
