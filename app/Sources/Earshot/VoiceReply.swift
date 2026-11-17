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

    /// One listen's microphone: a capture session on the Mac's BUILT-IN mic only.
    /// Never AVAudioEngine's input node — that opens the system default input
    /// first, which is usually the earbuds: their mic switches them to phone-call
    /// mode (muffled 16 kHz voice), Core Audio then loops on the format change,
    /// and the earbuds stay claimed by the Mac (the phone can't take them over).
    private final class Mic: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
        let session = AVCaptureSession()
        let request = SFSpeechAudioBufferRecognitionRequest()
        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            request.appendAudioSampleBuffer(sampleBuffer)
        }
    }
    private static let setupQueue = DispatchQueue(label: "earshot.voice-reply")
    private static let bufferQueue = DispatchQueue(label: "earshot.voice-reply.buffers")
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
        let request = mic.request
        defer {
            Self.setupQueue.async {
                mic.session.stopRunning()
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

    /// Opens the built-in mic on `setupQueue`; false if there is none, it failed,
    /// or it took longer than `limit` seconds.
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
                var ok = false
                if let device = builtInCaptureDevice(), let input = try? AVCaptureDeviceInput(device: device),
                   mic.session.canAddInput(input) {
                    mic.session.addInput(input)
                    let output = AVCaptureAudioDataOutput()
                    output.setSampleBufferDelegate(mic, queue: bufferQueue)
                    if mic.session.canAddOutput(output) {
                        mic.session.addOutput(output)
                        mic.session.startRunning()
                        ok = mic.session.isRunning
                    }
                }
                if !ok { Log.write("voice: built-in microphone unavailable — answer with a tap or the shortcut") }
                if setupStuck {
                    setupStuck = false
                    Log.write("voice: microphone setup finished late — listening works again")
                    mic.session.stopRunning()
                }
                answer(ok)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + limit) {
                lock.lock()
                let late = !answered
                lock.unlock()
                guard late else { return }
                setupStuck = true
                Log.write("voice: microphone setup took over \(Int(limit)) s — skipping voice reply")
                answer(false)
            }
        }
    }

    /// The Mac's own microphone as a capture device (never Bluetooth or USB).
    nonisolated private static func builtInCaptureDevice() -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
        if let uid = builtInMicrophone().flatMap(deviceUID) { return devices.first { $0.uniqueID == uid } }
        return devices.first { $0.transportType == Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn) }
    }

    nonisolated private static func deviceUID(_ id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    nonisolated private static func builtInMicrophone() -> AudioDeviceID? {
        CoreAudioQuery.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, of: AudioDeviceID.self).first { id in
            let transport: UInt32 = CoreAudioQuery.get(id, kAudioDevicePropertyTransportType, 0) ?? 0
            let inputs = CoreAudioQuery.array(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, of: AudioStreamID.self)
            return transport == kAudioDeviceTransportTypeBuiltIn && !inputs.isEmpty
        }
    }
}
