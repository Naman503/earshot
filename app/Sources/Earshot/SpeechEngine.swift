import AVFoundation
import Foundation

/// Mono float32 audio for one chunk of text.
struct SpeechAudio {
    var samples: [Float]
    var sampleRate: Double
    /// When each word is spoken (empty if the engine doesn't say).
    var words: [SpokenWord] = []
}

/// A word (or a short word plus the next one) and when it's spoken, in seconds
/// from the start of its chunk's audio. `range` is UTF-16 in the chunk text.
struct SpokenWord: Equatable {
    var range: NSRange
    var start: Double
    var end: Double

    /// Short words ("of", "a", "the") are shown together with the next word,
    /// so the highlight doesn't flicker over them.
    static func grouped(_ words: [SpokenWord]) -> [SpokenWord] {
        var out: [SpokenWord] = []
        var i = 0
        while i < words.count {
            var w = words[i]
            if w.range.length <= 3, i + 1 < words.count {
                let n = words[i + 1]
                w = SpokenWord(range: NSUnionRange(w.range, n.range), start: w.start, end: n.end)
                i += 1
            }
            out.append(w)
            i += 1
        }
        return out
    }

    /// No timings from the engine (Apple voice): spread the words over the
    /// audio by length, which is close enough to follow along.
    static func estimated(for text: String, duration: Double) -> [SpokenWord] {
        let ns = text as NSString
        var ranges: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { _, r, _, _ in ranges.append(r) }
        let weight = ranges.reduce(0) { $0 + $1.length + 2 }
        guard weight > 0, duration > 0 else { return [] }
        var t = 0.0
        return ranges.map { r in
            let d = duration * Double(r.length + 2) / Double(weight)
            defer { t += d }
            return SpokenWord(range: r, start: t, end: t + d)
        }
    }
}

/// The resident Kokoro process (engine/server.py) driven over stdio. Requests
/// are answered in order; stale ones are dropped with `cancel(before:)`.
@MainActor
final class KokoroEngine: ObservableObject {
    enum Status: Equatable { case notInstalled, starting, ready, failed(String) }

    @Published private(set) var status: Status = .starting
    @Published private(set) var voices: [String] = []

    static var engineDir: URL {
        if let custom = UserDefaults.standard.string(forKey: "enginePath"), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Earshot/engine")
    }

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<SpeechAudio?, Never>] = [:]
    private var restarts = 0
    private var floor = 0

    func start() {
        let dir = Self.engineDir
        let python = dir.appendingPathComponent(".venv/bin/python")
        let script = dir.appendingPathComponent("server.py")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: script.path) else {
            status = .notInstalled
            Log.write("engine: not installed at \(dir.path)")
            return
        }
        status = .starting
        let p = Process()
        p.executableURL = python
        p.arguments = [script.path]
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_OFFLINE"] = "1"  // the installer downloaded the model; skip network checks
        env["TOKENIZERS_PARALLELISM"] = "false"
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            Task { @MainActor in self?.receive(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            guard let s = String(data: h.availableData, encoding: .utf8) else { return }
            // Known, harmless library chatter stays out of the log.
            let lines = s.split(separator: "\n").filter { line in
                !line.contains("words count mismatch") && !line.contains("torch.jit.script") && !line.contains("warnings.warn")
                    && !line.contains("Creating new KokoroPipeline") && !line.trimmingCharacters(in: .whitespaces).isEmpty
            }
            if !lines.isEmpty { Log.write("engine stderr: \(lines.joined(separator: "\n").suffix(400))") }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.terminated(code: proc.terminationStatus) }
        }
        do {
            try p.run()
            process = p
            stdin = inPipe.fileHandleForWriting
            Log.write("engine: started pid \(p.processIdentifier)")
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        try? stdin?.close()
        process?.terminate()
        process = nil
    }

    private func terminated(code: Int32) {
        Log.write("engine: exited \(code)")
        process = nil
        for (_, c) in waiting { c.resume(returning: nil) }
        waiting.removeAll()
        guard restarts < 3 else { status = .failed("Engine keeps crashing; see ~/Library/Logs/Earshot"); return }
        restarts += 1
        status = .starting
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start() }
    }

    /// Asks for audio; the returned id can be cancelled.
    func synthesize(_ text: String, voice: String, speed: Double = 1, stretch: Double = 1) -> (id: Int, result: Task<SpeechAudio?, Never>) {
        let id = nextID
        nextID += 1
        let task = Task { @MainActor [weak self] () -> SpeechAudio? in
            guard let self, self.status == .ready, id >= self.floor else { return nil }
            return await withCheckedContinuation { c in
                self.waiting[id] = c
                self.send(["op": "synth", "id": id, "text": text, "voice": voice, "speed": speed, "stretch": stretch])
            }
        }
        return (id, task)
    }

    /// Drops every queued request older than `id` and resolves them as nil.
    func cancel(before id: Int) {
        floor = max(floor, id)
        send(["op": "cancel_before", "id": id])
        for key in waiting.keys where key < id {
            waiting.removeValue(forKey: key)?.resume(returning: nil)
        }
    }


    /// Abandons every request made so far.
    func cancelPending() { cancel(before: nextID) }

    private func send(_ msg: [String: Any]) {
        guard let stdin, let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        try? stdin.write(contentsOf: data + Data([0x0A]))
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let headerData = buffer[buffer.startIndex..<nl]
            guard let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
                buffer.removeSubrange(buffer.startIndex...nl)
                continue
            }
            let size = header["bytes"] as? Int ?? 0
            let bodyStart = buffer.index(after: nl)
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= size else { return }  // wait for the body
            let body = buffer[bodyStart..<buffer.index(bodyStart, offsetBy: size)]
            handle(header, body: Data(body))
            buffer = Data(buffer[buffer.index(bodyStart, offsetBy: size)...])
        }
    }

    private func handle(_ h: [String: Any], body: Data) {
        switch h["type"] as? String {
        case "ready":
            status = .ready
            restarts = 0
            send(["op": "voices"])
            Log.write("engine: ready")
        case "voices":
            voices = h["voices"] as? [String] ?? []
        case "audio":
            guard let id = h["id"] as? Int, let c = waiting.removeValue(forKey: id) else { return }
            let samples = body.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let words = (h["words"] as? [[Double]] ?? []).compactMap { w -> SpokenWord? in
                w.count == 4 ? SpokenWord(range: NSRange(location: Int(w[0]), length: Int(w[1])), start: w[2], end: w[3]) : nil
            }
            c.resume(returning: SpeechAudio(samples: samples, sampleRate: h["sr"] as? Double ?? 24000, words: words))
        case "error":
            Log.write("engine error: \(h["message"] ?? "")")
            if let id = h["id"] as? Int {
                waiting.removeValue(forKey: id)?.resume(returning: nil)
            }
        default:
            break
        }
    }
}

/// Apple's built-in voices rendered to buffers, used as a fallback while Kokoro
/// starts or when chosen in Settings.
@MainActor
final class AppleEngine {
    private let synth = AVSpeechSynthesizer()

    static var englishVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    func synthesize(_ text: String, voiceID: String, speed: Double) async -> SpeechAudio? {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceID) ?? Self.englishVoices.first
        // Speed is applied by the player's time-stretch, so render at normal rate.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        return await withCheckedContinuation { c in
            var samples: [Float] = []
            var rate = 22050.0
            var done = false
            synth.write(utterance) { buffer in
                guard !done else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    done = true
                    c.resume(returning: SpeechAudio(samples: samples, sampleRate: rate))
                    return
                }
                rate = pcm.format.sampleRate
                if let f = pcm.floatChannelData {
                    samples.append(contentsOf: UnsafeBufferPointer(start: f[0], count: Int(pcm.frameLength)))
                } else if let i = pcm.int16ChannelData {
                    samples.append(contentsOf: UnsafeBufferPointer(start: i[0], count: Int(pcm.frameLength)).map { Float($0) / 32768 })
                }
            }
        }
    }
}
