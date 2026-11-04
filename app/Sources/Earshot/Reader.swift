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
    /// Recently read texts, newest first (for "Read again" and the menu).
    @Published private(set) var history: [String] = []
    var onStateChange: ((State) -> Void)?
    /// The word being spoken now, as a range in `currentText` (nil between words).
    @Published private(set) var spokenRange: NSRange?
    /// Called when the spoken word changes: its text and where to look for it.
    var onWord: ((String?, String, WordLocator?) -> Void)?

    private let settings: Settings
    private let audio: AudioOutput
    private let kokoro: KokoroEngine
    private let apple = AppleEngine()
    private let media = MediaControl()
    let ducker = Ducker()

    private var chunks: [String] = []
    private var index = 0
    private var readID = 0
    private var playToken = 0
    private var cache: [Int: AVAudioPCMBuffer] = [:]
    private var failed = Set<Int>()
    private var requested = Set<Int>()
    private var scheduled: [Int] = []
    /// Speed baked into this reading's audio by the engine (WSOLA); the player
    /// only covers the difference after a speed change, until chunks regenerate.
    private var bakedSpeed = 1.0
    /// Speed each prepared chunk was generated at (Kokoro bakes the speed in).
    private var bakedFor: [Int: Double] = [:]
    /// Boost shortcut on: reading at `settings.boostSpeed`.
    @Published private(set) var boosted = false
    private var rampTimer: Timer?
    /// The speed in use right now.
    var speed: Double { boosted ? settings.boostSpeed : settings.speed }
    private var usesKokoro = false
    /// First chunk of a reading gets a short silent lead-in.
    private var leadInIndex: Int?
    private var deviceID: AudioDeviceID = 0
    private var pausedByRoute = false
    private var onFinish: (() -> Void)?
    /// Paragraph number of each chunk (for paragraph skips).
    private var paragraphOf: [Int] = []
    private var callTimer: Timer?
    private var pausedForCall = false
    /// Runs when this reading is cut short (Esc, a new tap, headphones gone).
    private var onInterrupt: (() -> Void)?
    private let lookahead = 4
    /// Which chunks are code / commands, read at the fast speed.
    private var technical: [Bool] = []
    /// Word timings per chunk, in seconds from the start of its buffer.
    private var timings: [Int: [SpokenWord]] = [:]
    /// Where each scheduled chunk starts in the player's timeline (frames since play).
    private var chunkFrames: [Int: (start: AVAudioFramePosition, length: AVAudioFramePosition)] = [:]
    private var scheduledFrames: AVAudioFramePosition = 0
    private var wordTimer: Timer?
    private var spoken: (chunk: Int, word: Int)?
    /// Finds spoken words on the page this reading came from.
    private var locator: WordLocator?

    init(settings: Settings, audio: AudioOutput, kokoro: KokoroEngine) {
        self.settings = settings
        self.audio = audio
        self.kokoro = kokoro
        audio.onRouteChange = { [weak self] in self?.routeChanged() }
    }

    var isActive: Bool { state != .idle }

    // MARK: Start / stop

    /// Where a reading was when something interrupted it.
    struct Snapshot {
        var chunks: [String]
        var index: Int
        var paused: Bool
        var technical: [Bool] = []
    }

    /// Reads `raw` aloud. `quiet` skips the on-screen "connect headphones"
    /// reminder (for notifications). `onFinish` runs only when it reads to the end.
    @discardableResult
    func read(_ raw: String, source: String, quiet: Bool = false, locator: WordLocator? = nil,
              onFinish: (() -> Void)? = nil, onInterrupt: (() -> Void)? = nil) -> Bool {
        let text = TextPrep.apply(settings.pronunciations, to: TextPrep.clean(raw, options: settings.textOptions))
        let mapped = TextPrep.pieces(text, technical: settings.technicalText)
        technical = mapped.map(\.technical)
        let parts = mapped.map(\.text)
        guard !parts.isEmpty else {
            if !quiet { flash("Nothing to read here") }
            return false
        }
        Log.write("read: \(parts.count) chunks from \(source), \(text.count) chars")
        let started = start(parts, at: 0, quiet: quiet, onFinish: onFinish)
        if started {
            self.locator = locator
            startWordTracking()
            self.onInterrupt = onInterrupt
            paragraphOf = mapped.map(\.paragraph)
            if !source.hasPrefix("notification"), source != "sample", source != "read again" {
                history.removeAll { $0 == raw }
                history.insert(raw, at: 0)
                if history.count > 15 { history.removeLast() }
            }
        }
        return started
    }

    /// Captures the current reading so it can be resumed after an interruption.
    func snapshot() -> Snapshot? {
        guard isActive, !chunks.isEmpty else { return nil }
        return Snapshot(chunks: chunks, index: index, paused: state == .paused, technical: technical)
    }

    func restore(_ s: Snapshot) {
        technical = s.technical
        guard start(s.chunks, at: s.index, quiet: true, onFinish: nil) else { return }
        if s.paused { togglePause() }
    }

    @discardableResult
    private func start(_ parts: [String], at startIndex: Int, quiet: Bool, onFinish: (() -> Void)?) -> Bool {
        stop(resumeMedia: false)
        guard let device = audio.target(settings: settings) else {
            if !quiet {
                flash(settings.outputPolicy == .headphonesOnly ? "Connect headphones to listen" : "No allowed output device connected")
            }
            media.resumeOthers()
            return false
        }

        if settings.mediaPolicy == .pauseAndResume, !media.hasPaused { media.pauseOthers() }
        do {
            try audio.prepare(device: device)
        } catch {
            flash("Couldn't start audio: \(error.localizedDescription)")
            return false
        }
        let settleFirst = quietOthers()
        deviceID = device.id
        readID += 1
        chunks = parts
        total = parts.count
        index = min(startIndex, parts.count - 1)
        position = index
        currentText = parts[index]
        self.onFinish = onFinish
        usesKokoro = settings.engine == .kokoro && kokoro.status == .ready
        bakedSpeed = usesKokoro ? speed : 1
        bakedFor = [:]
        leadInIndex = index
        applyAudioSettings()
        startWordTracking()
        if settleFirst {
            // Ducking just reconfigured the output; let it settle before speaking.
            let id = readID
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.readID == id, self.state != .paused else { return }
                self.audio.player.play()
            }
        } else {
            audio.player.play()
        }
        setState(.preparing)
        fill()
        return true
    }

    func stop(resumeMedia: Bool = true) {
        readID += 1
        playToken += 1
        audio.player.stop()
        kokoro.cancelPending()
        resetTimeline()
        timings = [:]
        locator = nil
        wordTimer?.invalidate()
        wordTimer = nil
        chunks = []
        cache = [:]
        failed = []
        requested = []
        scheduled = []
        pausedByRoute = false
        onFinish = nil
        let interrupted = onInterrupt
        onInterrupt = nil
        total = 0
        if resumeMedia { restoreOthers() }
        setState(.idle)
        interrupted?()
    }

    func togglePause() {
        switch state {
        case .speaking, .preparing:
            audio.player.pause()
            ducker.release()
            setState(.paused)
        case .paused:
            guard let device = audio.target(settings: settings) else {
                flash("Connect headphones to keep listening")
                return
            }
            if device.id != deviceID { restartAt(index, on: device) } else { audio.player.play() }
            quietOthers()
            pausedByRoute = false
            setState(scheduled.isEmpty ? .preparing : .speaking)
        case .idle:
            break
        }
    }

    /// Jumps to the start of the next / previous paragraph.
    func skipParagraph(_ delta: Int) {
        guard isActive, !chunks.isEmpty, paragraphOf.count == chunks.count else { skip(delta); return }
        let current = paragraphOf[min(index, paragraphOf.count - 1)]
        let target = max(0, current + delta)
        if let i = paragraphOf.firstIndex(where: { $0 == target }) {
            restartAt(i, on: nil)
        } else if delta > 0 {
            stop()
        }
    }

    /// Pauses while another app has a microphone open (a call), checked every second.
    private func watchForCalls(_ on: Bool) {
        callTimer?.invalidate()
        callTimer = nil
        guard on, settings.pauseForCalls else { return }
        callTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .speaking || self.state == .preparing, MediaControl.onCall() else { return }
                self.togglePause()
                self.pausedForCall = true
                self.flash("Paused — a call is using the microphone")
            }
        }
    }

    func skip(_ delta: Int) {
        guard isActive, !chunks.isEmpty else { return }
        restartAt(max(0, min(chunks.count - 1, index + delta)), on: nil)
    }

    func changeSpeed(by delta: Double) {
        let next = (max(0.7, min(4.0, speed + delta)) * 20).rounded() / 20
        if boosted { settings.boostSpeed = next } else { settings.speed = next }
        flash(String(format: boosted ? "Boost %.2g×" : "Speed %.2g×", next))
    }

    /// Switches between your normal speed and the boost speed, gliding over
    /// a third of a second without restarting the sentence.
    func setBoost(_ on: Bool) {
        guard on != boosted else { return }
        boosted = on
        flash(String(format: on ? "Boost %.2g×" : "Normal speed %.2g×", speed))
        applyAudioSettings(ramp: true)
        speedChanged()
    }

    /// Applies volume, and speed on the player at once (or gliding, with
    /// `ramp`); with Kokoro, upcoming sentences are regenerated at the new
    /// speed by `speedChanged` for full clarity.
    func applyAudioSettings(ramp: Bool = false) {
        let head = scheduled.first ?? index
        let target = speed / (bakedFor[head] ?? bakedSpeed)
        rampTimer?.invalidate()
        rampTimer = nil
        guard ramp, isActive else {
            audio.apply(speedStretch: target, volume: settings.volume)
            return
        }
        let from = Double(audio.stretch.rate)
        var step = 0
        rampTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                step += 1
                let f = min(1, Double(step) / 11)
                let eased = f * f * (3 - 2 * f)
                self.audio.apply(speedStretch: from + (target - from) * eased, volume: self.settings.volume)
                if f >= 1 { t.invalidate(); self.rampTimer = nil; self.applyAudioSettings() }
            }
        }
    }

    /// Keeps what's already queued in the player (its speed is corrected on
    /// the fly) and regenerates the sentences after it at the new speed, so
    /// the voice never restarts mid-sentence.
    func speedChanged() {
        guard usesKokoro, isActive, abs(speed - bakedSpeed) > 0.01 else {
            if rampTimer == nil { applyAudioSettings() }
            return
        }
        bakedSpeed = speed
        readID += 1
        kokoro.cancelPending()
        let keep = Set(scheduled)
        cache = cache.filter { keep.contains($0.key) }
        requested = requested.intersection(keep)
        failed = []
        if rampTimer == nil { applyAudioSettings() }
        fill()
    }

    private func finishNaturally() {
        let done = onFinish
        onInterrupt = nil
        stop(resumeMedia: done == nil)
        done?()
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
        // Technical chunks are generated faster still; the player rate stays the
        // same, so `bakedFor` records the normal speed they stand in for.
        let fast = i < technical.count && technical[i] && chunks.count == technical.count
        let factor = fast ? max(settings.technicalSpeed / bakedSpeed, 1) : 1
        let normal = bakedSpeed
        let stretch = bakedSpeed * factor
        let kokoroSession = usesKokoro
        let leadIn = i == leadInIndex ? 0.3 : 0
        Task {
            let result: SpeechAudio?
            if kokoroSession {
                result = await kokoro.synthesize(text, voice: settings.voice, stretch: stretch).result.value
            } else {
                result = await apple.synthesize(text, voiceID: settings.appleVoiceID, speed: 1)
            }
            guard id == readID else { return }
            if let result, let (buffer, shift) = audio.buffer(for: result, leadIn: leadIn) {
                cache[i] = buffer
                let duration = Double(buffer.frameLength) / buffer.format.sampleRate
                let words = result.words.isEmpty ? SpokenWord.estimated(for: text, duration: duration - shift) : result.words
                timings[i] = SpokenWord.grouped(words.map { SpokenWord(range: $0.range, start: $0.start + shift, end: $0.end + shift) })
                bakedFor[i] = kokoroSession ? normal : 1
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
            chunkFrames[i] = (scheduledFrames, AVAudioFramePosition(buffer.frameLength))
            scheduledFrames += AVAudioFramePosition(buffer.frameLength)
            audio.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.finished(i, token: token) } }
            }
            next += 1
        }
        if index >= chunks.count, scheduled.isEmpty, !chunks.isEmpty {
            finishNaturally()
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
            finishNaturally()
            return
        }
        if let next = scheduled.first { show(next) } else if state == .speaking { setState(.preparing) }
        fill()
        scheduleReady()
    }

    private func show(_ i: Int) {
        // Chunks made before a speed change carry their old speed; correct it.
        if rampTimer == nil, let baked = bakedFor[i], abs(Double(audio.stretch.rate) - speed / baked) > 0.01 { applyAudioSettings() }
        position = i + 1
        currentText = chunks[i]
    }

    /// Drops the player queue and continues from chunk `i` (skip, device switch).
    private func restartAt(_ i: Int, on device: OutputDevice?) {
        playToken += 1
        audio.player.stop()
        resetTimeline()
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

    // MARK: Following along

    /// Follows words only when something shows them: a page to mark, or the
    /// bar highlight. 20 checks a second is smooth for speech even at 3x.
    private func startWordTracking() {
        wordTimer?.invalidate()
        wordTimer = nil
        guard isActive, (locator != nil && settings.highlightWords) || settings.highlightWordsInBar else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackWord() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        wordTimer = timer
    }

    private func resetTimeline() {
        chunkFrames = [:]
        scheduledFrames = 0
        setSpoken(nil)
    }

    /// Finds the word being heard right now from the player's position, minus
    /// the output delay (large on Bluetooth), and reports it when it changes.
    private func trackWord() {
        guard state == .speaking, let nodeTime = audio.player.lastRenderTime,
              let t = audio.player.playerTime(forNodeTime: nodeTime) else { return }
        let rate = t.sampleRate
        let heard = t.sampleTime - AVAudioFramePosition(audio.outputLatency * Double(audio.stretch.rate) * rate)
        guard let chunk = scheduled.first(where: { i in
            chunkFrames[i].map { heard >= $0.start && heard < $0.start + $0.length } ?? false
        }), let frames = chunkFrames[chunk], let words = timings[chunk] else { return }
        let secs = Double(heard - frames.start) / rate
        let w = words.lastIndex { $0.start <= secs }
        // Past a word's end with the next not started: keep it lit through short gaps.
        setSpoken(w.map { (chunk, $0) })
    }

    private func setSpoken(_ s: (chunk: Int, word: Int)?) {
        guard s?.chunk != spoken?.chunk || s?.word != spoken?.word else { return }
        spoken = s
        guard let s, let w = timings[s.chunk]?[s.word], s.chunk < chunks.count else {
            if spokenRange != nil { spokenRange = nil }
            onWord?(nil, "", locator)
            return
        }
        let text = chunks[s.chunk] as NSString
        guard NSMaxRange(w.range) <= text.length else { return }
        // Only redraw the bar per word when it shows the word.
        if settings.highlightWordsInBar { spokenRange = s.chunk == position - 1 ? w.range : nil }
        // Code read fast is shortened, so it can't be followed on the page.
        let isTechnical = s.chunk < technical.count && technical[s.chunk]
        if locator != nil, settings.highlightWords {
            if isTechnical {
                onWord?(nil, "", locator)
            } else {
                let rest = text.substring(from: NSMaxRange(w.range))
                onWord?(text.substring(with: w.range), String(rest.prefix(60)), locator)
            }
        }
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
        if s == .idle || state == .idle { watchForCalls(s != .idle) }
        state = s
        onStateChange?(s)
    }

    /// A notice that stays until `clearNotice` (e.g. "Read it? Say yes or no").
    func hold(_ message: String) {
        notice = message
    }

    func clearNotice() { notice = nil }

    /// Resumes media paused for a chain of readings (announcement → answer → body).
    func resumeMedia() { restoreOthers() }

    /// Ducks (or, if that isn't possible, pauses) other audio per the media
    /// setting — only when something else is actually playing. Returns true when
    /// the output was just reconfigured and speech should wait a moment.
    @discardableResult
    private func quietOthers() -> Bool {
        guard settings.mediaPolicy == .duck else { return false }
        guard ducker.isLingering || !MediaControl.playingApps().isEmpty else { return false }
        var fresh = false
        if !ducker.duck(to: settings.duckLevel, freshlyBuilt: &fresh), !media.hasPaused { media.pauseOthers() }
        return fresh
    }

    private func restoreOthers() {
        ducker.release()
        media.resumeOthers()
    }

    func flash(_ message: String) {
        notice = message
        Log.write("notice: \(message)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            if self?.notice == message { self?.notice = nil }
        }
    }
}
