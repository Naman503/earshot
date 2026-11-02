import EarshotCore
import Foundation

/// Speaks notifications: "WhatsApp, Rahul. Read it?" → yes → the message (or a
/// summary of a long one). Pauses an article being read and picks it up after.
@MainActor
final class Announcer: ObservableObject {
    @Published private(set) var history: [BannerNote] = []
    /// The notification waiting for a yes / no.
    @Published private(set) var pending: BannerNote?
    /// Any question waiting for a yes / no (notification or page summary).
    @Published private(set) var isAsking = false

    private let settings: Settings
    private let reader: Reader
    private let voice = VoiceReply()
    private var queue: [BannerNote] = []
    private var busy = false
    private var snapshot: Reader.Snapshot?
    private var answer: ((Bool) -> Void)?
    private let shortLimit = 110
    private let longLimit = 260

    init(settings: Settings, reader: Reader) {
        self.settings = settings
        self.reader = reader
    }

    func handle(_ note: BannerNote) {
        if !settings.knownApps.contains(note.app) { settings.knownApps.append(note.app) }
        history.insert(note, at: 0)
        if history.count > 30 { history.removeLast() }
        guard settings.notificationsEnabled, settings.mode(for: note.app) != .mute else { return }
        if settings.quietHours, inQuietHours(Calendar.current.component(.hour, from: Date()), start: settings.quietStart, end: settings.quietEnd) {
            Log.write("announce: quiet hours, skipping \(note.app)")
            return
        }
        queue.append(note)
        drain()
    }

    /// Hotkey / gesture: answer a pending prompt with yes, or read the latest notification.
    func readLatestOrAnswer() {
        if let answer {
            self.answer = nil
            answer(true)
        } else if let latest = history.first {
            queue.insert(latest, at: 0)
            readBodyNext = latest.id
            drain()
        } else {
            reader.flash("No notifications yet")
        }
    }

    /// Esc / no: skip the pending notification.
    func dismissPending() -> Bool {
        guard let answer else { return false }
        self.answer = nil
        answer(false)
        return true
    }

    /// Set when the user asked for a notification explicitly: read its body straight away.
    private var readBodyNext: String?

    private func drain() {
        guard !busy, let note = queue.first else { return }
        if reader.isActive, snapshot == nil {
            guard settings.interruptReading else {
                // Try again once the current reading ends.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.drain() }
                return
            }
            snapshot = reader.snapshot()
        }
        busy = true
        queue.removeFirst()

        let mode = settings.mode(for: note.app)
        let explicit = readBodyNext == note.id
        readBodyNext = nil
        let short = note.body.count <= shortLimit
        let intro = "\(note.app). \(note.who)."

        if explicit || mode == .full || (mode == .ask && short && settings.readShortInFull) {
            Task { await readBody(note, intro: intro) }
        } else if mode == .brief || note.body.isEmpty {
            speak(intro) { [weak self] in self?.done() }
        } else {
            speak(intro + " Read it?") { [weak self] in self?.ask(note) }
        }
    }

    private func ask(_ note: BannerNote) {
        pending = note
        askYesNo("Read it?") { [weak self] yes in
            guard let self else { return }
            self.pending = nil
            if yes {
                Task { await self.readBody(note, intro: nil) }
            } else {
                self.done()
            }
        }
    }

    /// Waits for yes / no — by voice, a four-finger tap or the shortcut — after
    /// a spoken question. No answer counts as no.
    func askYesNo(_ question: String, then: @escaping (Bool) -> Void) {
        let listening = settings.voiceReplies && VoiceReply.authorized
        reader.hold(listening ? "\(question) Say yes or no" : "\(question) Press \(shortcutHint) or tap with 4 fingers")
        isAsking = true
        var settled = false
        let settle: (Bool) -> Void = { [weak self] yes in
            guard let self, !settled else { return }
            settled = true
            self.answer = nil
            self.isAsking = false
            self.reader.clearNotice()
            then(yes)
        }
        answer = settle
        if listening {
            Task {
                let heard = await voice.listen(timeout: 6)
                settle(heard ?? false)
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { settle(false) }
        }
    }

    private func readBody(_ note: BannerNote, intro: String?) async {
        var body = note.body
        if settings.summarizeLong, body.count > longLimit {
            reader.hold("Summarizing…")
            if let summary = await Summarizer.summarize(body, from: note.who) { body = "In short: " + summary }
            reader.clearNotice()
        }
        speak([intro, body].compactMap { $0 }.joined(separator: " ")) { [weak self] in self?.done() }
    }

    private func speak(_ text: String, then: @escaping () -> Void) {
        let started = reader.read(text, source: "notification", quiet: true, onFinish: then, onInterrupt: { [weak self] in
            // The user cut in (Esc, a new tap): drop the rest and don't restore.
            self?.snapshot = nil
            self?.abandon()
        })
        if !started { abandon() }
    }

    private func done() {
        busy = false
        if let s = snapshot, queue.isEmpty {
            snapshot = nil
            reader.restore(s)
        } else if queue.isEmpty {
            reader.resumeMedia()
        }
        drain()
    }

    private func abandon() {
        busy = false
        answer = nil
        pending = nil
        isAsking = false
        reader.clearNotice()
        DispatchQueue.main.async { [weak self] in self?.drain() }
    }

    private var shortcutHint: String {
        settings.shortcuts[.readNotification].map(HotKeys.describe) ?? "the read-notification shortcut"
    }
}
