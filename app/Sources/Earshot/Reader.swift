import AVFoundation
import EarshotCore
import Foundation

/// Reads text aloud: splits it into chunks, synthesizes a few ahead, plays them
/// back to back, and handles pause / skip / speed / headphone changes.
@MainActor
final class Reader: ObservableObject {
    enum State: Equatable { case idle, preparing, speaking, paused }

    @Published private(set) var state: State = .idle
    @Published private(set) var currentText = ""
    @Published private(set) var position = 0
    @Published private(set) var total = 0
    /// One-off status for the HUD ("Connect headphones…").
    @Published var notice: String?
    var onStateChange: ((State) -> Void)?

    private let settings: Settings
    private let audio: AudioOutput
    private let kokoro: KokoroEngine
    private let apple = AppleEngine()
    private let media = MediaControl()

    private var chunks: [String] = []
    private var index = 0
    private var readID = 0
    private var playToken = 0
    private var cache: [Int: AVAudioPCMBuffer] = [:]
    private var failed = Set<Int>()
    private var requested = Set<Int>()
    private var scheduled: [Int] = []
    private var modelSpeed = 1.0
    private var deviceID: AudioDeviceID = 0
    private var pausedByRoute = false
    private let lookahead = 4

    init(settings: Settings, audio: AudioOutput, kokoro: KokoroEngine) {
        self.settings = settings
        self.audio = audio
        self.kokoro = kokoro
        audio.onRouteChange = { [weak self] in self?.routeChanged() }
    }

    var isActive: Bool { state != .idle }

    // MARK: Start / stop

    func read(_ raw: String, source: String) {
        stop(resumeMedia: false)
        let text = TextPrep.clean(raw, options: settings.textOptions)
        let parts = TextPrep.chunks(text)
        guard !parts.isEmpty else { flash("Nothing to read here"); return }
        guard let device = audio.target(settings: settings) else {
            flash(settings.outputPolicy == .headphonesOnly ? "Connect headphones to listen" : "No allowed output device connected")
            media.resumeOthers()
            return
        }
        Log.write("read: \(parts.count) chunks from \(source), \(text.count) chars")

        if settings.mediaPolicy == .pauseAndResume, !media.hasPaused { media.pauseOthers() }
        do {
            try audio.prepare(device: device)
        } catch {
            flash("Couldn't start audio: \(error.localizedDescription)")
            return
        }
        deviceID = device.id
        readID += 1
        chunks = parts
        total = parts.count
        index = 0
        position = 0
        currentText = parts[0]
        let useKokoro = settings.engine == .kokoro && kokoro.status == .ready
        modelSpeed = useKokoro ? speedSplit(settings.speed).model : 1
        applyAudioSettings()
        audio.player.play()
        setState(.preparing)
        fill()
    }

    func stop(resumeMedia: Bool = true) {
        readID += 1
        playToken += 1
        audio.player.stop()
        kokoro.cancelPending()
        chunks = []
        cache = [:]
        failed = []
        requested = []
        scheduled = []
        pausedByRoute = false
        total = 0
        if resumeMedia { media.resumeOthers() }
        setState(.idle)
    }

    func togglePause() {
        switch state {
        case .speaking, .preparing:
            audio.player.pause()
            setState(.paused)
        case .paused:
            guard let device = audio.target(settings: settings) else {
                flash("Connect headphones to keep listening")
                return
            }
            if device.id != deviceID { restartAt(index, on: device) } else { audio.player.play() }
            pausedByRoute = false
            setState(scheduled.isEmpty ? .preparing : .speaking)
        case .idle:
            break
        }
    }

    func skip(_ delta: Int) {
        guard isActive, !chunks.isEmpty else { return }
        restartAt(max(0, min(chunks.count - 1, index + delta)), on: nil)
    }

    func changeSpeed(by delta: Double) {
        settings.speed = (max(0.7, min(4.0, settings.speed + delta)) * 20).rounded() / 20
        applyAudioSettings()
        flash(String(format: "Speed %.2g×", settings.speed))
    }

    func applyAudioSettings() {
        audio.apply(speedStretch: settings.speed / modelSpeed, volume: settings.volume)
    }

    // MARK: Pipeline

    private func fill() {
        let end = min(index + lookahead, chunks.count)
        guard index < end else { return }
        for i in index..<end where !requested.contains(i) {
            requested.insert(i)
            synthesize(i)
        }
    }

    private func synthesize(_ i: Int) {
        let id = readID
        let text = chunks[i]
        let speed = modelSpeed
        Task {
            let result: SpeechAudio?
            if settings.engine == .kokoro, kokoro.status == .ready {
                result = await kokoro.synthesize(text, voice: settings.voice, speed: speed).result.value
            } else {
                result = await apple.synthesize(text, voiceID: settings.appleVoiceID, speed: speed)
            }
            guard id == readID else { return }
            if let result, let buffer = audio.buffer(for: result) {
                cache[i] = buffer
            } else {
                failed.insert(i)
                Log.write("read: chunk \(i) produced no audio")
            }
            scheduleReady()
        }
    }

    private func scheduleReady() {
        let token = playToken
        var next = (scheduled.last ?? index - 1) + 1
        while next < chunks.count, next < index + lookahead {
            if failed.contains(next), scheduled.isEmpty, next == index {
                index += 1  // skip a chunk that could not be synthesized
                next += 1
                continue
            }
            guard let buffer = cache[next] else { break }
            let i = next
            scheduled.append(i)
            audio.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.finished(i, token: token) } }
            }
            next += 1
        }
        if index >= chunks.count, scheduled.isEmpty, !chunks.isEmpty {
            stop()
            return
        }
        if state == .preparing, !scheduled.isEmpty { setState(.speaking) }
        if let first = scheduled.first { show(first) }
    }

    private func finished(_ i: Int, token: Int) {
        guard token == playToken, scheduled.first == i else { return }
        scheduled.removeFirst()
        cache[i] = nil
        index = i + 1
        if index >= chunks.count {
            stop()
            return
        }
        if let next = scheduled.first { show(next) } else if state == .speaking { setState(.preparing) }
        fill()
        scheduleReady()
    }

    private func show(_ i: Int) {
        position = i + 1
        currentText = chunks[i]
    }

    /// Drops the player queue and continues from chunk `i` (skip, device switch).
    private func restartAt(_ i: Int, on device: OutputDevice?) {
        playToken += 1
        audio.player.stop()
        if let device {
            try? audio.prepare(device: device)
            deviceID = device.id
        }
        scheduled = []
        index = i
        show(i)
        let wasPaused = state == .paused
        if !wasPaused { audio.player.play() }
        fill()
        scheduleReady()
        if !wasPaused, scheduled.isEmpty { setState(.preparing) }
    }

    // MARK: Headphones

    private func routeChanged() {
        guard isActive else { return }
        let target = audio.target(settings: settings)
        if target == nil {
            guard state != .paused else { return }
            if settings.pauseOnDisconnect {
                audio.player.pause()
                pausedByRoute = true
                setState(.paused)
                flash("Headphones disconnected — paused")
            } else {
                stop()
                flash("Headphones disconnected — stopped")
            }
        } else if let target, target.id != deviceID {
            if pausedByRoute {
                pausedByRoute = false
                restartAt(index, on: target)
                setState(scheduled.isEmpty ? .preparing : .speaking)
                flash("Resumed on \(target.name)")
            } else if state != .paused {
                restartAt(index, on: target)
            }
        }
    }

    // MARK: Helpers

    private func setState(_ s: State) {
        guard s != state else { return }
        state = s
        onStateChange?(s)
    }

    func flash(_ message: String) {
        notice = message
        Log.write("notice: \(message)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            if self?.notice == message { self?.notice = nil }
        }
    }
}
