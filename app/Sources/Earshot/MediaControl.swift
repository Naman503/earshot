import AppKit
import CoreAudio
import Foundation

/// Finds apps that are playing audio (Core Audio process objects, macOS 14.2+)
/// and pauses / resumes them with the system play-pause media key.
@MainActor
final class MediaControl {
    private var pausedApps: [String] = []

    /// Bundle ids of other processes currently sending audio to an output.
    static func playingApps() -> [String] {
        let me = ProcessInfo.processInfo.processIdentifier
        return CoreAudioQuery.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
            .compactMap { obj -> String? in
                let running: UInt32 = CoreAudioQuery.get(obj, kAudioProcessPropertyIsRunningOutput, 0) ?? 0
                let pid: pid_t = CoreAudioQuery.get(obj, kAudioProcessPropertyPID, pid_t(0)) ?? 0
                guard running != 0, pid != me else { return nil }
                return CoreAudioQuery.string(obj, kAudioProcessPropertyBundleID) ?? "pid \(pid)"
            }
            .filter { !Self.ignored.contains($0) }
    }

    /// True when another app is recording from a microphone (a call, a voice note).
    static func onCall() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        return CoreAudioQuery.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
            .contains { obj in
                let input: UInt32 = CoreAudioQuery.get(obj, kAudioProcessPropertyIsRunningInput, 0) ?? 0
                let pid: pid_t = CoreAudioQuery.get(obj, kAudioProcessPropertyPID, pid_t(0)) ?? 0
                guard input != 0, pid != me else { return false }
                let bundle = CoreAudioQuery.string(obj, kAudioProcessPropertyBundleID) ?? ""
                // Siri, dictation and system services briefly open the mic; they aren't calls.
                return !bundle.hasPrefix("com.apple.") || bundle == "com.apple.FaceTime"
            }
    }

    /// System sound sources that never respond to play/pause.
    private static let ignored: Set<String> = [
        "com.apple.audio.coreaudiod", "com.apple.systemsoundserverd", "com.apple.CoreSpeech",
        "com.apple.SpeechSynthesisServerXPC", "com.apple.accessibility.heard", "com.apple.siri",
    ]

    /// Pauses whatever is playing. Returns true when something was paused.
    @discardableResult
    func pauseOthers() -> Bool {
        let playing = Self.playingApps()
        guard !playing.isEmpty else { return false }
        Log.write("media: pausing \(playing.joined(separator: ", "))")
        Self.postPlayPause()
        pausedApps = playing
        return true
    }

    /// Resumes what `pauseOthers` paused, unless the user already restarted it.
    func resumeOthers() {
        guard !pausedApps.isEmpty else { return }
        let apps = pausedApps
        pausedApps = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let nowPlaying = Set(Self.playingApps())
            guard nowPlaying.isDisjoint(with: apps) else { return }
            Log.write("media: resuming \(apps.joined(separator: ", "))")
            Self.postPlayPause()
        }
    }

    var hasPaused: Bool { !pausedApps.isEmpty }

    /// NX_KEYTYPE_PLAY down + up as system-defined events (needs Accessibility).
    static func postPlayPause() {
        let key = 16  // NX_KEYTYPE_PLAY
        for down in [true, false] {
            let flags = down ? 0xA00 : 0xB00
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                           modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                                           timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                           data1: (key << 16) | flags, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
