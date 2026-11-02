import AppKit
import ApplicationServices
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
    private var mic: MicCapture?
    private let collector = Collector()
    private var pressedAt = Date.distantPast
    private var maxTimer: Timer?
    private var liveTimer: Timer?
    private var liveBusy = false

    /// Gathers 16 kHz mono samples from the audio thread.
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []
        func reset() { lock.withLock { samples = [] } }
        func append(_ s: UnsafeBufferPointer<Float>) { lock.withLock { samples.append(contentsOf: s) } }
        func take() -> [Float] { lock.withLock { let s = samples; samples = []; return s } }
        func peek() -> [Float] { lock.withLock { samples } }
    }

    init(settings: Settings, kokoro: KokoroEngine, reader: Reader) {
        self.settings = settings
        self.kokoro = kokoro
        self.reader = reader
    }

    /// Shortcut pressed: start, or finish if already listening (tap mode).
    func pressed() {
        Log.write("dictation: key down (state \(state), mic \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue))")
        if state == .idle { pressedAt = Date() }
        switch state {
        case .idle: start()
        case .listening: finish()
        case .transcribing: break
        }
    }

    /// Shortcut released: a long press means hold-to-talk, so finish now.
    func released() {
        Log.write("dictation: key up after \(Int(Date().timeIntervalSince(pressedAt) * 1000)) ms")
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
            // The prompt takes the key press; by the time it's answered the keys are up.
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let key = self.settings.shortcuts[.dictate].map(HotKeys.describe) ?? "the shortcut"
                    self.reader.flash(ok ? "Microphone allowed — hold \(key) and talk" : "Dictation needs the microphone")
                    Log.write("dictation: microphone \(ok ? "allowed" : "denied")")
                }
            }
            return
        default:
            reader.flash("Earshot needs microphone access (System Settings → Privacy)")
            return
        }
        if reader.isActive { reader.stop() }
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
        Log.write("dictation: listening on \(settings.dictationBuiltInMic ? "built-in mic" : "default input")")
        maxTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
        // Live preview: re-transcribe what's been said so far (~0.1 s each on Parakeet).
        liveTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateLive() }
        }
    }

    private func finish() {
        guard state == .listening else { return }
        stopRecording()
        if settings.dictationSounds { NSSound(named: "Pop")?.play() }
        let samples = collector.take()
        let peak = samples.reduce(0) { max($0, abs($1)) }
        Log.write("dictation: recorded \(String(format: "%.1f", Double(samples.count) / 16_000)) s, peak \(String(format: "%.3f", peak))")
        guard samples.count > 16_000 / 4 else {
            reader.clearNotice()
            reader.flash("No audio from the microphone")
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

    /// Records through AVCaptureSession, which asks Core Audio for 16 kHz mono
    /// float and leaves the system's default input alone. (AVAudioEngine with
    /// a switched input device delivered only fragments.)
    private func startRecording() throws {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
        let builtIn = devices.first { $0.transportType == Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn) }
        guard let device = (settings.dictationBuiltInMic ? builtIn : nil) ?? AVCaptureDevice.default(for: .audio) else {
            throw NSError(domain: "Earshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone"])
        }
        let mic = MicCapture(collector: collector)
        try mic.start(device: device)
        self.mic = mic
        Log.write("dictation: recording from \(device.localizedName)")
    }

    /// Debug: records `seconds` from the mic and logs what came in (types nothing).
    func micTest(seconds: Double) {
        collector.reset()
        do { try startRecording() } catch { Log.write("mic-test: start failed \(error)"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            self.stopRecording()
            let s = self.collector.take()
            let peak = s.reduce(0) { max($0, abs($1)) }
            Log.write("mic-test: \(s.count) samples at 16 kHz, peak \(peak)")
            Task {
                let t = await self.kokoro.transcribe(s, model: "parakeet", language: "en")
                Log.write("mic-test: heard \"\(t ?? "nil")\"")
            }
        }
    }

    private func updateLive() {
        guard state == .listening, !liveBusy, settings.dictationModel == "parakeet" else { return }
        let samples = collector.peek()
        guard samples.count > 16_000 / 2 else { return }
        liveBusy = true
        Task {
            let text = await kokoro.transcribe(samples, model: "parakeet", language: "en")
            liveBusy = false
            guard state == .listening, let text, !text.isEmpty else { return }
            reader.hold("🎙 " + (text.count > 140 ? "…" + text.suffix(140) : text))
        }
    }

    private func stopRecording() {
        liveTimer?.invalidate()
        liveTimer = nil
        maxTimer?.invalidate()
        maxTimer = nil
        mic?.stop()
        mic = nil
    }

    private func setState(_ s: State) {
        state = s
        onStateChange?(s)
    }

    /// Puts `text` where the cursor is, trying the most reliable way first and
    /// checking it worked before falling back:
    ///   1. Accessibility: insert into the focused field directly (no clipboard).
    ///   2. ⌘V with the text on the clipboard (restored afterwards).
    ///   3. Typing the characters as keystrokes (works in any app).
    static func type(_ raw: String) {
        let text = raw.hasSuffix(" ") ? raw : raw + " "
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        let focused = focusedRef.map { $0 as! AXUIElement }
        func value() -> String? {
            var v: CFTypeRef?
            guard let focused, AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &v) == .success else { return nil }
            return v as? String
        }
        let before = value()

        // 1. Direct insert. Chromium and Electron fields often report success
        //    without changing anything, so check the value moved.
        if let focused, before != nil,
           AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, text as CFString) == .success,
           let after = value(), after != before, after.contains(raw.trimmingCharacters(in: .whitespaces)) {
            Log.write("dictation: inserted via accessibility")
            return
        }

        // 2. Paste, then confirm when the field's value is readable.
        paste(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard let before, let after = value() else {
                Log.write("dictation: pasted (field value not readable, assuming it landed)")
                return
            }
            if after != before {
                Log.write("dictation: pasted")
            } else {
                // 3. Keystrokes.
                Log.write("dictation: paste didn't land, typing instead")
                typeKeystrokes(text)
            }
        }
    }

    private static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } })
        } ?? []
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Clipboard managers skip transient items.
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        // A private source so modifier keys still physically held (⌃⌥ from the
        // shortcut) don't mix into the ⌘V.
        let src = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down)  // V
            e?.flags = .maskCommand
            e?.post(tap: .cgSessionEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            pb.clearContents()
            let items = saved.map { types -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (t, data) in types { item.setData(data, forType: t) }
                return item
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
    }

    /// Types text as Unicode keystrokes, 20 characters per event.
    static func typeKeystrokes(_ text: String) {
        let src = CGEventSource(stateID: .privateState)
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 20, units.count)])
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                e?.flags = []
                chunk.withUnsafeBufferPointer { e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                e?.post(tap: .cgSessionEventTap)
            }
            i += 20
            usleep(2_000)
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

/// Microphone capture delivering 16 kHz mono float samples to a collector.
final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "earshot.mic")
    private let collector: Dictation.Collector

    init(collector: Dictation.Collector) {
        self.collector = collector
    }

    func start(device: AVCaptureDevice) throws {
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw NSError(domain: "Earshot", code: 2, userInfo: [NSLocalizedDescriptionKey: "Can't use \(device.localizedName)"])
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
    }

    func stop() {
        session.stopRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let bytes = CMBlockBufferGetDataLength(block)
        var floats = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
        floats.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: raw.baseAddress!)
        }
        floats.withUnsafeBufferPointer { collector.append($0) }
    }
}
