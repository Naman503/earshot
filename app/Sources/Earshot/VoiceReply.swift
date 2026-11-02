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

    /// true = yes, false = no, nil = no clear answer before the timeout.
    func listen(timeout: TimeInterval = 6) async -> Bool? {
        guard Self.authorized, let recognizer, recognizer.isAvailable else { return nil }
        let engine = AVAudioEngine()
        if let mic = Self.builtInMicrophone(), let unit = engine.inputNode.audioUnit {
            var id = mic
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.shouldReportPartialResults = true
        request.contextualStrings = Array(Self.yes.union(Self.no))
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            Log.write("voice: mic failed: \(error.localizedDescription)")
            return nil
        }
        defer {
            engine.stop()
            input.removeTap(onBus: 0)
            request.endAudio()
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

    private static func builtInMicrophone() -> AudioDeviceID? {
        CoreAudioQuery.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, of: AudioDeviceID.self).first { id in
            let transport: UInt32 = CoreAudioQuery.get(id, kAudioDevicePropertyTransportType, 0) ?? 0
            let inputs = CoreAudioQuery.array(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, of: AudioStreamID.self)
            return transport == kAudioDeviceTransportTypeBuiltIn && !inputs.isEmpty
        }
    }
}
