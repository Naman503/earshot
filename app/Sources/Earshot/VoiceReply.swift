import AVFoundation
import CoreAudio
import Speech

/// Listens briefly for "yes" / "no" with on-device speech recognition. Uses the
/// Mac's built-in microphone so Bluetooth earbuds stay in high-quality playback
/// mode (opening their mic would drop them to call quality).
@MainActor
final class VoiceReply {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-IN")) ?? SFSpeechRecognizer()
    private static let yes: Set<String> = ["yes", "yeah", "yep", "yup", "read", "sure", "okay", "ok", "haan", "han", "go"]
    private static let no: Set<String> = ["no", "nope", "skip", "later", "nahi", "stop", "cancel", "dismiss"]

    static var authorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        return speech && mic
    }

    /// The mic engine of one listen, handed between the setup queue and the main actor.
    private final class Mic: @unchecked Sendable {
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
    }
    /// Core Audio setup runs here, never on the main thread: when an audio device
    /// changes mid-setup (the ducking device going away as a notification is
    /// withdrawn), AVAudioEngine can block forever inside the input node — and
    /// on the main thread that froze all of Earshot.
    private static let setupQueue = DispatchQueue(label: "earshot.voice-reply")
    /// A setup that never came back still holds `setupQueue`; don't queue more behind it.
    nonisolated(unsafe) private static var setupStuck = false

    /// true = yes, false = no, nil = no clear answer before the timeout.
    func listen(timeout: TimeInterval = 6) async -> Bool? {
        guard Self.authorized, let recognizer, recognizer.isAvailable else { return nil }
        guard !Self.setupStuck else {
            Log.write("voice: microphone setup is still stuck from an earlier question — use a tap or the shortcut")
            return nil
        }
        let mic = Mic()
        mic.request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        mic.request.shouldReportPartialResults = true
        mic.request.contextualStrings = Array(Self.yes.union(Self.no))
        let started = await Self.startMic(mic, within: 2)
        guard started else { return nil }
        let engine = mic.engine, request = mic.request
        defer {
            Self.setupQueue.async {
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
                request.endAudio()
            }
        }

        return await withCheckedContinuation { c in
            var resolved = false
            func finish(_ answer: Bool?) {
                guard !resolved else { return }
                resolved = true
                c.resume(returning: answer)
            }
            let task = recognizer.recognitionTask(with: request) { result, error in
                guard let result else {
                    if error != nil { DispatchQueue.main.async { finish(nil) } }
                    return
                }
                let words = result.bestTranscription.formattedString.lowercased()
                    .components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
                let answer: Bool? = words.contains(where: Self.no.contains) ? false : words.contains(where: Self.yes.contains) ? true : nil
                if let answer {
                    Log.write("voice: heard \"\(words.joined(separator: " "))\" → \(answer ? "yes" : "no")")
                    DispatchQueue.main.async { finish(answer) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                task.cancel()
                finish(nil)
            }
        }
    }

    /// Opens the built-in mic on `setupQueue`; false if it failed or took longer
    /// than `limit` seconds (then the stuck setup is left to finish on its own).
    private static func startMic(_ mic: Mic, within limit: TimeInterval) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let lock = NSLock()
            var answered = false
            func answer(_ ok: Bool) {
                lock.lock(); defer { lock.unlock() }
                guard !answered else { return }
                answered = true
                c.resume(returning: ok)
            }
            setupQueue.async {
                let engine = mic.engine
                if let id = builtInMicrophone(), let unit = engine.inputNode.audioUnit {
                    var dev = id
                    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                         &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
                }
                let input = engine.inputNode
                let request = mic.request
                input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                    request.append(buffer)
                }
                var ok = true
                do {
                    engine.prepare()
                    try engine.start()
                } catch {
                    Log.write("voice: mic failed: \(error.localizedDescription)")
                    input.removeTap(onBus: 0)
                    ok = false
                }
                if setupStuck {
                    // Came back after all: free the queue for the next question.
                    setupStuck = false
                    Log.write("voice: microphone setup finished late — listening works again")
                    engine.stop()
                    input.removeTap(onBus: 0)
                }
                answer(ok)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + limit) {
                lock.lock()
                let late = !answered
                lock.unlock()
                guard late else { return }
                setupStuck = true
                Log.write("voice: microphone setup took over \(Int(limit)) s (audio devices changing?) — skipping voice reply")
                answer(false)
            }
        }
    }

    nonisolated private static func builtInMicrophone() -> AudioDeviceID? {
        CoreAudioQuery.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, of: AudioDeviceID.self).first { id in
            let transport: UInt32 = CoreAudioQuery.get(id, kAudioDevicePropertyTransportType, 0) ?? 0
            let inputs = CoreAudioQuery.array(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, of: AudioStreamID.self)
            return transport == kAudioDeviceTransportTypeBuiltIn && !inputs.isEmpty
        }
    }
}
