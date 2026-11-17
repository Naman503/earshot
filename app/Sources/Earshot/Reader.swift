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
    enum SpeedMode { case normal, boost, slow }
    /// Boost (`settings.boostSpeed`) or slow (`settings.slowSpeed`) instead of the normal speed.
    @Published private(set) var speedMode: SpeedMode = .normal
    var boosted: Bool { speedMode == .boost }
    /// The speed in use right now.
    var speed: Double {
        switch speedMode {
        case .normal: settings.speed
        case .boost: settings.boostSpeed
        case .slow: settings.slowSpeed
        }
    }
    private var usesKokoro = false
    /// First chunk of a reading gets a short silent lead-in.
    private var leadInIndex: Int?
    private var deviceID: AudioDeviceID = 0
    private var pausedByRoute = false
    private var onFinish: (() -> Void)?
    /// Paragraph number of each chunk (for paragraph skips).
    private var paragraphOf: [Int] = []
    private var callTimer: Timer?
    private var checkingCall = false
    private var pausedForCall = false
    /// Runs when this reading is cut short (Esc, a new tap, headphones gone).
    private var onInterrupt: (() -> Void)?
    private let lookahead = 4
    /// Each chunk made at every speed mode (normal / boost / slow), so a
    /// switch between them is an instant cut, not a wait for new audio.
    private struct Version { let buffer: AVAudioPCMBuffer; let words: [SpokenWord]; let timings: [SpokenWord] }
    private var versions: [Int: [SpeedMode: Version]] = [:]
    /// Which chunks are code / commands, read at the fast speed.
    private var technical: [Bool] = []
    /// Debug tests read silently and leave other audio alone without touching
    /// saved settings (a test that changed them and was cut short left Earshot
    /// at volume 0).
    var testMuted = false
    /// When the current reading was asked for (to log how fast it started).
    private var readStartedAt: Date?
    /// When the untouched audio runs out after a speed change (for the log).
    private var switchAt: Date?
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
        audio.onEngineReset = { [weak self] in self?.engineReset() }
    }

    var isActive: Bool { state != .idle }

    // MARK: Start / stop

    /// Where a reading was when something interrupted it.
    struct Snapshot {
        var chunks: [String]
        var index: Int
        var paused: Bool
        var technical: [Bool] = []
        /// The page the reading came from, so the word highlight carries on after.
        var locator: WordLocator?
        var paragraphOf: [Int] = []
    }

    /// Reads `raw` aloud. `quiet` skips the on-screen "connect headphones"
    /// reminder (for notifications). `onFinish` runs only when it reads to the end.
    @discardableResult
    func read(_ raw: String, source: String, quiet: Bool = false, locator: WordLocator? = nil,
              onFinish: (() -> Void)? = nil, onInterrupt: (() -> Void)? = nil) -> Bool {
        // The voice was put to sleep to save memory: wake it and wait (a few
        // seconds) rather than switching to the Apple voice.
        if settings.engine == .kokoro, kokoro.status == .asleep || kokoro.waking {
            kokoro.wake()
            if !quiet { hold("Waking the voice…") }
            let deadline = Date().addingTimeInterval(15)
            func retry() {
                guard kokoro.status == .ready || Date() > deadline else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { retry() }
                    return
                }
                clearNotice()
                _ = readNow(raw, source: source, quiet: quiet, locator: locator, onFinish: onFinish, onInterrupt: onInterrupt)
            }
            retry()
            return true
        }
        return readNow(raw, source: source, quiet: quiet, locator: locator, onFinish: onFinish, onInterrupt: onInterrupt)
    }

    private func readNow(_ raw: String, source: String, quiet: Bool, locator: WordLocator?,
                         onFinish: (() -> Void)?, onInterrupt: (() -> Void)?) -> Bool {
        let text = TextPrep.apply(settings.pronunciations, to: TextPrep.clean(raw, options: settings.textOptions))
        let mapped = TextPrep.pieces(text, technical: settings.technicalText)
        technical = mapped.map(\.technical)
        let parts = mapped.map(\.text)
        guard !parts.isEmpty else {
            if !quiet { flash("Nothing to read here") }
            return false
        }
        Log.write("read: \(parts.count) chunks from \(source), \(text.count) chars")
        readingNotification = source.hasPrefix("notification")
        // What exactly is being read, so a line that seems skipped can be checked:
        // the full text, with technical lines (read fast) marked.
        let marked = mapped.map { ($0.technical ? "[fast] " : "") + $0.text }.joined(separator: "\n")
        try? marked.write(to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Earshot/last-read.txt"),
                          atomically: true, encoding: .utf8)
        let fast = mapped.filter(\.technical).count
        if fast > 0 { Log.write("read: \(fast) of \(mapped.count) pieces are code/commands, read fast") }
        readStartedAt = Date()
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
        return Snapshot(chunks: chunks, index: index, paused: state == .paused, technical: technical,
                        locator: locator, paragraphOf: paragraphOf)
    }

    /// True while a notification is being read out (they may pause or duck
    /// a playing video differently from ordinary readings).
    private var readingNotification = false

    /// The media policy for what's being read now: notifications can have
    /// their own choice, so a movie pauses for them but ducks for readings.
    private var effectiveMediaPolicy: MediaPolicy {
        guard readingNotification else { return settings.mediaPolicy }
        switch settings.notificationMediaPolicy {
        case .same: return settings.mediaPolicy
        case .duck: return .duck
        case .pause: return .pauseAndResume
        }
    }

    func restore(_ s: Snapshot) {
        readingNotification = false
        technical = s.technical
        guard start(s.chunks, at: s.index, quiet: true, onFinish: nil) else { return }
        // Back to the page: the word highlight picks up where it left off.
        locator = s.locator
        paragraphOf = s.paragraphOf
        startWordTracking()
        Log.write("read: resumed at sentence \(s.index + 1) of \(s.chunks.count)\(s.locator != nil ? ", with highlight" : "")")
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

        if effectiveMediaPolicy == .pauseAndResume, !testMuted, !media.hasPaused { media.pauseOthers() }
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
        if isActive, !chunks.isEmpty {
            Log.write("read: ended at sentence \(min(index + 1, chunks.count)) of \(chunks.count)\(index >= chunks.count ? " (finished)" : " (stopped)")")
        }
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
        versions = [:]
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
            if device.id != deviceID || !audio.engine.isRunning { restartAt(index, on: device) }
            audio.player.play()
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
                guard let self, self.state == .speaking || self.state == .preparing, !self.checkingCall else { return }
                // Asking the audio system about every app can be slow; never on the main thread.
                self.checkingCall = true
                DispatchQueue.global(qos: .utility).async {
                    let onCall = MediaControl.onCall()
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self.checkingCall = false
                            guard onCall, self.state == .speaking || self.state == .preparing else { return }
                            self.togglePause()
                            self.pausedForCall = true
                            self.flash("Paused — a call is using the microphone")
                        }
                    }
                }
            }
        }
    }

    /// The voice for one chunk: Devanagari text gets the Hindi voice, if chosen.
    private func voice(for text: String) -> String {
        guard !settings.hindiVoice.isEmpty, Self.mostlyDevanagari(text) else { return settings.voice }
        return settings.hindiVoice
    }

    static func mostlyDevanagari(_ text: String) -> Bool {
        var hindi = 0, letters = 0
        for u in text.unicodeScalars where CharacterSet.letters.contains(u) {
            letters += 1
            if (0x0900...0x097F).contains(u.value) { hindi += 1 }
        }
        return letters > 0 && hindi * 3 > letters
    }

    /// Jumps to the sentence whose text starts with `snippet` (from a click on
    /// the page). Returns false when no sentence matches.
    func jump(toTextNear snippet: String) -> Bool {
        guard isActive, !chunks.isEmpty else { return false }
        let want = Self.normalizedWords(snippet)
        guard want.count >= 2 else { return false }
        // The sentence that contains the first clicked words, nearest first.
        let order = chunks.indices.sorted { abs($0 - index) < abs($1 - index) }
        for i in order {
            let have = Self.normalizedWords(chunks[i])
            guard !have.isEmpty else { continue }
            for start in have.indices.dropLast(min(1, have.count - 1)) where have[start] == want[0] {
                let n = min(want.count, have.count - start, 3)
                if n >= 2, Array(have[start..<start + n]) == Array(want[0..<n]) {
                    Log.write("read: jumped to sentence \(i + 1) (clicked “\(snippet.prefix(30))…”)")
                    restartAt(i, on: nil)
                    return true
                }
            }
        }
        return false
    }

    private static func normalizedWords(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map { normalizedWord(String($0)) }.filter { !$0.isEmpty }
    }

    func skip(_ delta: Int) {
        guard isActive, !chunks.isEmpty else { return }
        restartAt(max(0, min(chunks.count - 1, index + delta)), on: nil)
    }

    func changeSpeed(by delta: Double) {
        let next = (max(0.7, min(4.0, speed + delta)) * 20).rounded() / 20
        switch speedMode {
        case .normal: settings.speed = next
        case .boost: settings.boostSpeed = next
        case .slow: settings.slowSpeed = next
        }
        flash(String(format: speedMode == .boost ? "Boost %.2g×" : speedMode == .slow ? "Slow %.2g×" : "Speed %.2g×", next))
    }

    /// Switches between your normal speed and the boost speed, gliding over
    /// a third of a second without restarting the sentence.
    func setBoost(_ on: Bool) {
        setSpeedMode(on ? .boost : .normal)
    }

    /// Glides to the mode's speed on the player right away, and re-voices what
    /// comes next at that speed (see `speedChanged`).
    func setSpeedMode(_ mode: SpeedMode, quiet: Bool = false) {
        guard mode != speedMode else { return }
        speedMode = mode
        if !quiet {
            flash(String(format: mode == .boost ? "Boost %.2g×" : mode == .slow ? "Slow %.2g×" : "Normal speed %.2g×", speed))
        }
        if !switchInstantly() { speedChanged() }
    }

    /// Switches to the ready-made audio of the new speed mode at the next gap
    /// between words: the current audio fades out over a few milliseconds in
    /// that gap and the other version fades in at the same word. Nothing is
    /// made, so there's no wait, no gap and no repeated word. Returns false
    /// when the other version isn't there (then `speedChanged` re-voices).
    private func switchInstantly() -> Bool {
        guard usesKokoro, isActive, let playing = scheduled.first else {
            if isActive { Log.write("speed switch: nothing queued (sentence \(index + 1), state \(state), cached \(cache.keys.sorted()), requested \(requested.sorted()))") }
            return false
        }
        guard let old = cache[playing], let new = versions[playing]?[speedMode], let frames = chunkFrames[playing],
              let node = audio.player.lastRenderTime, let t = audio.player.playerTime(forNodeTime: node) else {
            Log.write("speed switch: no ready version for sentence \(playing + 1) (versions: \(versions[playing].map { "\($0.keys.count)" } ?? "none"))")
            return false
        }
        let oldWords = versions[playing]?.values.first { $0.buffer === old }?.words ?? []
        guard !oldWords.isEmpty, oldWords.count == new.words.count else {
            Log.write("speed switch: versions don't line up (\(oldWords.count) vs \(new.words.count) words)")
            return false
        }
        let rate = old.format.sampleRate
        let at = max(0, min(t.sampleTime - frames.start, AVAudioFramePosition(old.frameLength)))
        let now = Double(at) / rate
        // A word far enough ahead to schedule the cut cleanly.
        let k = oldWords.firstIndex { $0.start >= now + 0.08 }
        func gapMiddle(_ w: [SpokenWord], _ k: Int) -> Double {
            k > 0 ? (w[k - 1].end + w[k].start) / 2 : max(0, w[k].start - 0.03)
        }
        // Cut in the pause before word k — or right here if we're already past
        // the middle of that pause (it's silence either way) — and start the new
        // version the same distance before the same word.
        var cutOld = AVAudioFramePosition(old.frameLength), cutNew: AVAudioFramePosition = 0
        if let k {
            let oldTime = max(gapMiddle(oldWords, k), now + 0.02)
            let lead = max(0, oldWords[k].start - oldTime)
            let newFloor = k > 0 ? new.words[k - 1].end : 0
            cutOld = AVAudioFramePosition(oldTime * rate)
            cutNew = AVAudioFramePosition(max(newFloor, new.words[k].start - lead) * rate)
        }
        // Nothing left of this sentence (only its "done" signal is pending):
        // carry on from the next one at the new speed.
        let sentenceOver = k == nil && cutOld <= at
        guard cutOld > at || sentenceOver else { return false }

        bakedSpeed = speed
        // Sentences still being made are kept: they come with every speed, and
        // the version for the new mode is picked when they arrive.
        playToken += 1
        let token = playToken
        audio.player.stop()
        chunkFrames = [:]
        scheduled = []
        // 1. The rest of what you're hearing, to the gap, fading out at the very end.
        let head = slice(old, from: at, to: cutOld, fadeIn: false, fadeOut: k != nil)
        var cursor: AVAudioFramePosition = 0
        if let head {
            if k == nil {
                // No word left: this sentence plays out at its speed; switch from the next.
                audio.player.scheduleBuffer(head, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.finished(playing, token: token) } }
                }
                scheduled = [playing]
                chunkFrames[playing] = (-at, AVAudioFramePosition(old.frameLength))
            } else {
                audio.player.scheduleBuffer(head)
            }
            cursor = AVAudioFramePosition(head.frameLength)
        }
        // 2. The new speed from that same word.
        if k != nil, let tail = slice(new.buffer, from: cutNew, to: AVAudioFramePosition(new.buffer.frameLength), fadeIn: true, fadeOut: false) {
            audio.player.scheduleBuffer(tail, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.finished(playing, token: token) } }
            }
            scheduled = [playing]
            // Positions in the new version line up with what's heard, for the highlight.
            chunkFrames[playing] = (cursor - cutNew, AVAudioFramePosition(new.buffer.frameLength))
            cache[playing] = new.buffer
            timings[playing] = new.timings
            cursor += AVAudioFramePosition(tail.frameLength)
        }
        scheduledFrames = cursor
        // 3. Everything after: the ready-made versions, or made again.
        for (i, byMode) in versions where i > playing {
            if let v = byMode[speedMode] { cache[i] = v.buffer; timings[i] = v.timings; bakedFor[i] = speed }
            else { cache[i] = nil; requested.remove(i) }
        }
        for i in cache.keys where i > playing && versions[i] == nil { cache[i] = nil; requested.remove(i) }
        bakedFor[playing] = speed
        index = playing
        if sentenceOver {
            cache[playing] = nil
            versions[playing] = nil
            index = playing + 1
        }
        if state != .paused { audio.player.play() }
        applyAudioSettings()
        scheduleReady()
        fill()
        let said = { (w: SpokenWord) in (self.chunks[playing] as NSString).substring(with: w.range) }
        Log.write("speed switch: instant in chunk \(playing) at \(String(format: "%.2f", now)) s, \(k.map { "between “\($0 > 0 ? said(oldWords[$0 - 1]) : "")” and “\(said(oldWords[$0]))” (word \($0) of \(oldWords.count))" } ?? "at sentence end")")
        return true
    }

    /// A copy of `buffer` from `from` to `to`, with 6 ms fades where asked.
    private func slice(_ buffer: AVAudioPCMBuffer, from: AVAudioFramePosition, to: AVAudioFramePosition,
                       fadeIn: Bool, fadeOut: Bool) -> AVAudioPCMBuffer? {
        let n = Int(to - from)
        guard n > 0, let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(n)),
              let src = buffer.floatChannelData, let dst = out.floatChannelData else { return nil }
        out.frameLength = AVAudioFrameCount(n)
        dst[0].update(from: src[0] + Int(from), count: n)
        let fade = min(n / 2, Int(buffer.format.sampleRate * 0.006))
        for j in 0..<fade {
            let g = Float(j) / Float(fade)
            if fadeIn { dst[0][j] *= g }
            if fadeOut { dst[0][n - 1 - j] *= g }
        }
        return out
    }

    /// Applies volume, and speed on the player at once (or gliding, with
    /// `ramp`); with Kokoro, upcoming sentences are regenerated at the new
    /// speed by `speedChanged` for full clarity.
    func applyAudioSettings() {
        // Kokoro audio is always made at the speed it plays at (speed changes
        // re-voice it), so it never goes through the time-stretch; only the
        // Apple voice, made at one speed, is sped up by the player.
        audio.apply(speedStretch: usesKokoro ? 1 : speed / bakedSpeed, volume: testMuted ? 0 : settings.volume)
    }

    /// New speed without stretching anything: the audio playing now carries on
    /// untouched up to a word ~0.4 s ahead, the sentence is re-voiced from that
    /// word at the new speed meanwhile, and playback switches there. Everything
    /// queued after it is made again at the new speed.
    func speedChanged() {
        if usesKokoro, isActive, abs(speed - bakedSpeed) > 0.01 { Log.write("speed switch: re-voicing (no ready-made version)") }
        guard usesKokoro, isActive, abs(speed - bakedSpeed) > 0.01 else {
            applyAudioSettings()
            return
        }
        bakedSpeed = speed
        versions = [:]  // the speed values changed: ready-made versions are stale
        readID += 1
        kokoro.cancelPending()
        failed = []
        leadInIndex = nil
        guard let playing = scheduled.first, let buffer = cache[playing], let frames = chunkFrames[playing],
              let node = audio.player.lastRenderTime, let t = audio.player.playerTime(forNodeTime: node) else {
            // Nothing playing yet: make what's next at the new speed.
            cache = [:]
            requested = []
            fill()
            return
        }
        let rate = buffer.format.sampleRate
        let at = max(0, min(t.sampleTime - frames.start, AVAudioFramePosition(buffer.frameLength)))
        let now = Double(at) / rate
        let margin = 0.6  // time to make the new audio before it's needed
        // The switch point: the first word starting at least `margin` from now —
        // in this sentence, or else in the next one (already made), so there's
        // always untouched audio playing while the new speed is prepared.
        var switchChunk = playing
        var switchWord = (timings[playing] ?? []).first { $0.start >= now + margin }
        let leftHere = Double(AVAudioFramePosition(buffer.frameLength) - at) / rate
        if switchWord == nil, playing + 1 < chunks.count, cache[playing + 1] != nil, scheduled.contains(playing + 1) {
            switchChunk = playing + 1
            switchWord = (timings[playing + 1] ?? []).first { $0.start >= margin - leftHere }
        }
        // Untouched pieces: the rest of this sentence, plus the next one up to
        // the switch word when the switch is there.
        var pieces: [(AVAudioPCMBuffer, AVAudioFramePosition, AVAudioFramePosition)] = []
        let cutHere = switchChunk == playing ? switchWord.map { AVAudioFramePosition($0.start * rate) } : nil
        pieces.append((buffer, at, min(cutHere ?? AVAudioFramePosition(buffer.frameLength), AVAudioFramePosition(buffer.frameLength))))
        if switchChunk == playing + 1, let nextBuffer = cache[playing + 1] {
            let end = switchWord.map { AVAudioFramePosition($0.start * nextBuffer.format.sampleRate) } ?? AVAudioFramePosition(nextBuffer.frameLength)
            pieces.append((nextBuffer, 0, min(end, AVAudioFramePosition(nextBuffer.frameLength))))
        }

        playToken += 1
        audio.player.stop()
        chunkFrames = [:]
        scheduledFrames = 0
        scheduled = []
        cache = [:]
        requested = []
        let token = playToken
        let resumeAt = switchWord == nil ? switchChunk + 1 : switchChunk
        let last = resumeAt >= chunks.count
        var keep: AVAudioFramePosition = 0
        for (n, (src, from, to)) in pieces.enumerated() where to > from {
            let count = to - from
            guard let piece = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: AVAudioFrameCount(count)),
                  let s = src.floatChannelData, let d = piece.floatChannelData else { continue }
            piece.frameLength = AVAudioFrameCount(count)
            d[0].update(from: s[0] + Int(from), count: Int(count))
            let isLast = last && n == pieces.count - 1
            audio.player.scheduleBuffer(piece, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                // The last sentence played out: that's the end of the reading.
                guard isLast else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { if self?.playToken == token { self?.finishNaturally() } } }
            }
            keep += count
        }
        scheduledFrames = keep
        switchAt = Date().addingTimeInterval(Double(keep) / rate)
        if let switchWord, switchChunk < chunks.count {
            // Re-voice that sentence from the switch word.
            chunks[switchChunk] = (chunks[switchChunk] as NSString).substring(from: switchWord.range.location)
            timings[switchChunk] = nil
        }
        index = resumeAt
        position = min(resumeAt, chunks.count)
        if state != .paused { audio.player.play() }
        applyAudioSettings()
        if index < chunks.count { fill() }
    }

    /// Debug: playing chunk, player stretch ratio, and the speed it was made at.
    var debugSpeedState: String {
        let head = scheduled.first ?? index
        return String(format: "chunk %d, mode %@, speed %.2f, made at %.2f, stretch %@, queued %d, delay %d ms",
                      head, "\(speedMode)", speed, bakedFor[head] ?? -1, audio.stretch.bypass ? "off" : String(format: "%.2f", audio.stretch.rate),
                      scheduled.count, Int(audio.outputLatency * 1000))
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
        // Nothing speakable (a form blank, a row of dashes): skip it outright
        // instead of asking the engine and waiting on an empty answer.
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else {
            failed.insert(i)
            scheduleReady()
            return
        }
        // Technical chunks are generated faster still; the player rate stays the
        // same, so `bakedFor` records the normal speed they stand in for.
        let fast = i < technical.count && technical[i] && chunks.count == technical.count
        func stretch(_ speed: Double) -> Double { speed * (fast ? max(settings.technicalSpeed / speed, 1) : 1) }
        let normal = bakedSpeed
        let primary = stretch(bakedSpeed)
        // The other speed modes, made from the same voice pass for instant switches.
        let modeSpeeds: [SpeedMode: Double] = [.normal: stretch(settings.speed), .boost: stretch(settings.boostSpeed), .slow: stretch(settings.slowSpeed)]
        // The first sentence of a reading is made at one speed only, so it
        // starts as fast as possible; every later one comes at all speeds.
        let also = i == leadInIndex ? [] : Array(Set(modeSpeeds.values.filter { abs($0 - primary) > 0.01 }))
        let kokoroSession = usesKokoro
        let leadIn = i == leadInIndex ? 0.3 : 0
        Task {
            let result: SpeechAudio?
            if kokoroSession {
                result = await kokoro.synthesize(text, voice: voice(for: text), stretch: primary, also: also).result.value
            } else {
                result = await apple.synthesize(text, voiceID: settings.appleVoiceID, speed: 1)
            }
            guard id == readID else { return }
            @MainActor func version(_ a: SpeechAudio) -> Version? {
                guard let (buffer, shift) = audio.buffer(for: a, leadIn: leadIn) else { return nil }
                let duration = Double(buffer.frameLength) / buffer.format.sampleRate
                let raw = a.words.isEmpty ? SpokenWord.estimated(for: text, duration: duration - shift) : a.words
                let words = raw.map { SpokenWord(range: $0.range, start: $0.start + shift, end: $0.end + shift) }
                return Version(buffer: buffer, words: words, timings: SpokenWord.grouped(words))
            }
            if let result, let main = version(result) {
                if kokoroSession, also.isEmpty, modeSpeeds.values.contains(where: { abs($0 - primary) > 0.01 }) {
                    // First sentence: made at one speed to start fast; its other
                    // speeds follow in the background for instant switches.
                    let others = Array(Set(modeSpeeds.values.filter { abs($0 - primary) > 0.01 }))
                    Task {
                        guard let more = await kokoro.synthesize(text, voice: voice(for: text), stretch: others[0], also: Array(others.dropFirst())).result.value,
                              id == readID, chunks.indices.contains(i), chunks[i] == text else { return }
                        var all = more.alternates
                        all[others[0]] = more
                        for (mode, sp) in modeSpeeds where versions[i]?[mode] == nil {
                            if let a = all.first(where: { abs($0.key - sp) < 0.01 })?.value, let v = version(a) { versions[i]?[mode] = v }
                        }
                    }
                }
                if kokoroSession {
                    var byMode: [SpeedMode: Version] = [:]
                    for (mode, sp) in modeSpeeds {
                        if abs(sp - primary) < 0.01 { byMode[mode] = main }
                        else if let alt = result.alternates.first(where: { abs($0.key - sp) < 0.01 })?.value { byMode[mode] = version(alt) }
                    }
                    versions[i] = byMode
                }
                // The speed mode may have changed while this was being made.
                let use = (kokoroSession ? versions[i]?[speedMode] : nil) ?? main
                cache[i] = use.buffer
                timings[i] = use.timings
                bakedFor[i] = kokoroSession ? (versions[i]?[speedMode] != nil ? speed : normal) : 1
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
            if failed.contains(next) {
                // Skip a chunk that can't be voiced, wherever it is in the
                // queue, so one dead sentence never leaves a gap in the sound.
                if scheduled.isEmpty, next == index { index += 1 }
                next += 1
                continue
            }
            guard let buffer = cache[next] else { break }
            let i = next
            if let due = switchAt {
                // How the new-speed audio met the switch point (negative = a gap).
                Log.write("speed switch: new audio ready \(Int(due.timeIntervalSinceNow * 1000)) ms before the switch")
                switchAt = nil
            }
            if let t0 = readStartedAt {
                Log.write("read: first audio after \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
                readStartedAt = nil
            }
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
        versions[i] = nil
        index = i + 1
        if index >= chunks.count {
            finishNaturally()
            return
        }
        if let next = scheduled.first { show(next) } else if state == .speaking {
            // Ran out of audio mid-reading: the next sentence isn't ready yet.
            Log.write("read: waiting for sentence \(index + 1) (requested: \(requested.contains(index)), failed: \(failed.contains(index)))")
            setState(.preparing)
        }
        fill()
        scheduleReady()
    }

    private func show(_ i: Int) {
        // Chunks made before a speed change carry their old speed; correct it.
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
        // What you hear now left the player this long ago: the earbuds' delay plus
        // the time-stretch and limiter look-ahead, and your own timing nudge.
        let delay = audio.outputLatency * Double(audio.stretch.rate) + settings.highlightOffset
        let heard = t.sampleTime - AVAudioFramePosition(delay * rate)
        guard let chunk = scheduled.first(where: { i in
            chunkFrames[i].map { heard >= $0.start && heard < $0.start + $0.length } ?? false
        }), let frames = chunkFrames[chunk], let words = timings[chunk] else { return }
        let secs = Double(heard - frames.start) / rate
        // Before a sentence's first word (the pause between sentences) there's
        // no new word yet: keep the last one lit rather than clearing the marker,
        // which used to make it blink off — and often vanish — every sentence.
        guard let w = words.lastIndex(where: { $0.start <= secs }) else { return }
        setSpoken((chunk, w))
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
                // Code read fast can't be followed on the page; keep the last
                // word lit (clearing it also threw away the finder's place).
            } else {
                let rest = text.substring(from: NSMaxRange(w.range))
                onWord?(text.substring(with: w.range), String(rest.prefix(60)), locator)
            }
        }
    }

    // MARK: Headphones

    /// The system stopped the audio engine mid-reading: restart it and carry
    /// on from the sentence that was playing, instead of going silent.
    private func engineReset() {
        guard isActive, let device = audio.target(settings: settings) else { return }
        let at = scheduled.first ?? index
        Log.write("read: audio was reset by the system — resuming at sentence \(at + 1)")
        let wasPaused = state == .paused
        restartAt(at, on: device)
        if wasPaused { audio.player.pause() }
    }

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
        releaseWork?.cancel()
        releaseWork = nil
        if s == .idle { scheduleAudioRelease(after: 8) }
        if s == .paused { scheduleAudioRelease(after: 60) }
    }

    /// Lets go of the output device once nothing is playing. A running audio
    /// engine keeps a (silent) stream open to the earbuds, and multipoint earbuds
    /// treat that as "the Mac is playing": they keep switching back to the Mac
    /// and the phone loses its audio for seconds at a time.
    private var releaseWork: DispatchWorkItem?
    private func scheduleAudioRelease(after seconds: Double) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .idle || self.state == .paused, self.audio.engine.isRunning else { return }
            self.audio.shutdown()
            Log.write("audio: released the output device (nothing playing)")
        }
        releaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
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
        guard effectiveMediaPolicy == .duck, !testMuted else { return false }
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
