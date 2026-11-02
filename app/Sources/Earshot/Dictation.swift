import AppKit
import AVFoundation
import CoreAudio
import Speech

/// Speech to text anywhere: hold the shortcut and talk (or tap to start, tap
/// to stop), then the words are typed into the focused field. Transcribed by
/// Parakeet in the local engine (~0.1 s), with Apple's recognizer as fallback.
@MainActor
final class Dictation: ObservableObject {
    enum State { case idle, listening, transcribing }

    @Published private(set) var state: State = .idle
    var onStateChange: ((State) -> Void)?

    private let settings: Settings
    private let kokoro: KokoroEngine
    private let reader: Reader
    private var engine: AVAudioEngine?
    private let collector = Collector()
    private var pressedAt = Date.distantPast
    private var maxTimer: Timer?

    /// Gathers 16 kHz mono samples from the audio thread.
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []
        func reset() { lock.withLock { samples = [] } }
        func append(_ s: UnsafeBufferPointer<Float>) { lock.withLock { samples.append(contentsOf: s) } }
        func take() -> [Float] { lock.withLock { let s = samples; samples = []; return s } }
    }

    init(settings: Settings, kokoro: KokoroEngine, reader: Reader) {
        self.settings = settings
        self.kokoro = kokoro
        self.reader = reader
    }

    /// Shortcut pressed: start, or finish if already listening (tap mode).
    func pressed() {
        switch state {
        case .idle: start()
        case .listening: finish()
        case .transcribing: break
        }
    }

    /// Shortcut released: a long press means hold-to-talk, so finish now.
    func released() {
        if state == .listening, Date().timeIntervalSince(pressedAt) > 0.45 { finish() }
    }

    func cancel() {
        guard state == .listening else { return }
        stopRecording()
        _ = collector.take()
        reader.clearNotice()
        setState(.idle)
        Log.write("dictation: cancelled")
    }

    private func start() {
        guard settings.dictationEnabled else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            reader.flash("Allow the microphone, then try again")
            return
        default:
            reader.flash("Earshot needs microphone access (System Settings → Privacy)")
            return
        }
        if reader.isActive { reader.stop() }
        pressedAt = Date()
        collector.reset()
        do {
            try startRecording()
        } catch {
            reader.flash("Couldn't start the microphone")
            Log.write("dictation: mic failed: \(error.localizedDescription)")
            return
        }
        if settings.dictationSounds { NSSound(named: "Tink")?.play() }
        let key = settings.shortcuts[.dictate].map(HotKeys.describe) ?? "the shortcut"
        reader.hold("Listening… release or press \(key) to finish, Esc to cancel")
        setState(.listening)
        maxTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    private func finish() {
        guard state == .listening else { return }
        stopRecording()
        if settings.dictationSounds { NSSound(named: "Pop")?.play() }
        let samples = collector.take()
        guard samples.count > 16_000 / 4 else {
            reader.clearNotice()
            setState(.idle)
            return
        }
        setState(.transcribing)
        reader.hold("Transcribing…")
        let started = Date()
        Task {
            var text = await kokoro.transcribe(samples, model: settings.dictationModel, language: settings.dictationLanguage)
            if text == nil { text = await Self.appleTranscribe(samples) }
            reader.clearNotice()
            setState(.idle)
            let seconds = Double(samples.count) / 16_000
            Log.write("dictation: \(String(format: "%.1f", seconds)) s of speech → \(text?.count ?? 0) chars in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            guard let text, !text.isEmpty else { reader.flash("Didn't catch that"); return }
            Self.type(text)
        }
    }

    private func startRecording() throws {
        let engine = AVAudioEngine()
        if settings.dictationBuiltInMic, let mic = Self.builtInMicrophone(), let unit = engine.inputNode.audioUnit {
            var id = mic
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "Earshot", code: 1)
        }
        let collector = self.collector
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / inFormat.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var fed = false
            converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if let ch = out.floatChannelData { collector.append(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength))) }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    private func stopRecording() {
        maxTimer?.invalidate()
        maxTimer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func setState(_ s: State) {
        state = s
        onStateChange?(s)
    }

    /// Pastes `text` into the focused field, then puts the clipboard back.
    static func type(_ text: String) {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } })
        } ?? []
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Clipboard managers skip transient items.
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down)  // V
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pb.clearContents()
            let items = saved.map { types -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (t, data) in types { item.setData(data, forType: t) }
                return item
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
    }

    /// Fallback when the engine isn't running: Apple's on-device recognizer.
    static func appleTranscribe(_ samples: [Float]) async -> String? {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-IN")) ?? SFSpeechRecognizer(),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.append(buffer)
        request.endAudio()
        return await withCheckedContinuation { c in
            var done = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !done else { return }
                if let result, result.isFinal { done = true; c.resume(returning: result.bestTranscription.formattedString) }
                else if error != nil { done = true; c.resume(returning: nil) }
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
