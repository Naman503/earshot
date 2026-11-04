import AppKit
import EarshotCore

/// Auto-read: once a second, compares the text of the page you're looking at
/// (or a page you pinned) with what it was, waits for changes to settle so a
/// streaming reply is complete, then reads what's new.
@MainActor
final class PageWatcher: ObservableObject {
    /// The window pinned with "Auto-read this page", if any.
    @Published private(set) var pinnedTitle: String?
    /// Host of the last page seen in another app (for "Add current site").
    @Published private(set) var lastHost: String?

    private let settings: Settings
    private let reader: Reader
    private let grabber: TextGrabber
    private let queue = DispatchQueue(label: "earshot.autoread")
    private var timer: Timer?
    private var busy = false

    private var pinned: (pid: pid_t, window: AXUIElement)?
    private var windowID: Int?
    private var key: String?
    private var baseline: String?
    private var latest = ""
    private var lastChange = Date.distantPast
    private var changeStart: Date?
    private var navigated = false
    private var lastTyped: String?
    private var waiting: (text: String, source: String)?

    private let settle: TimeInterval = 1.5
    private let streamingCap: TimeInterval = 45

    init(settings: Settings, reader: Reader, grabber: TextGrabber) {
        self.settings = settings
        self.reader = reader
        self.grabber = grabber
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Starts or stops auto-reading the front window, whatever site it is.
    func togglePin() {
        if pinned != nil {
            pinned = nil
            pinnedTitle = nil
            reset()
            reader.flash("Stopped auto-reading this page")
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &win) == .success, let win else {
            reader.flash("No window to watch")
            return
        }
        pinned = (app.processIdentifier, win as! AXUIElement)
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &title)
        pinnedTitle = (title as? String).flatMap { $0.isEmpty ? nil : $0 } ?? app.localizedName
        reset()
        reader.flash("Auto-reading new text on this page")
    }

    private func reset() {
        key = nil
        baseline = nil
        windowID = nil
        changeStart = nil
        navigated = false
    }

    private func tick() {
        // Something we held back while you were listening to something else.
        if let w = waiting, !reader.isActive {
            waiting = nil
            reader.read(w.text, source: w.source, quiet: true)
        }
        guard !busy, AXIsProcessTrusted(), pinned != nil || settings.autoReadEnabled else { return }
        let target: (pid_t, AXUIElement?)
        if let pinned {
            target = (pinned.pid, pinned.window)
        } else {
            guard let app = NSWorkspace.shared.frontmostApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            target = (app.processIdentifier, nil)
        }
        busy = true
        let grabber = self.grabber
        let rules = settings.autoReadRules
        let isPinned = pinned != nil
        queue.async {
            // Only read the page when a rule covers this site or app: fetching a
            // whole page every second makes long pages (and the app) stutter.
            if !isPinned {
                let id = grabber.pageIdentity(pid: target.0)
                if id == nil || AutoReadRule.match(rules, host: id?.host, app: id?.app ?? "") == nil {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self.busy = false
                            if let host = id?.host { self.lastHost = host }
                            self.reset()
                        }
                    }
                    return
                }
            }
            let snap = grabber.pageSnapshot(pid: target.0, window: target.1)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = false
                    self.process(snap)
                }
            }
        }
    }

    private func process(_ snap: TextGrabber.PageSnapshot?) {
        guard let snap else {
            if pinned != nil {
                pinned = nil
                pinnedTitle = nil
                reader.flash("The auto-read page closed")
            }
            reset()
            return
        }
        if snap.host != nil { lastHost = snap.host }
        let rule: AutoReadRule? = pinned != nil
            ? AutoReadRule(pattern: "pinned", enabled: true, newContent: true, newPage: .nothing)
            : AutoReadRule.match(settings.autoReadRules, host: snap.host, app: snap.app)
        guard let rule else { reset(); return }
        if let t = snap.typed { lastTyped = t }

        let now = Date()
        if snap.windowID != windowID {
            // Switched windows or apps: take the page as it is, read nothing.
            windowID = snap.windowID
            key = snap.key
            baseline = snap.text
            latest = snap.text
            changeStart = nil
            navigated = false
            return
        }
        if snap.key != key {
            key = snap.key
            navigated = true
            changeStart = now
            lastChange = now
            latest = snap.text
            return
        }
        if snap.text != latest {
            latest = snap.text
            lastChange = now
            if changeStart == nil { changeStart = now }
        }
        guard let started = changeStart, now.timeIntervalSince(lastChange) >= settle || now.timeIntervalSince(started) >= streamingCap else { return }
        changeStart = nil

        if navigated {
            navigated = false
            baseline = latest
            newPage(latest, action: rule.newPage)
            return
        }
        guard let old = baseline else { baseline = latest; return }
        baseline = latest
        switch TextDiff.change(from: old, to: latest) {
        case .inserted(let added):
            guard rule.newContent else { return }
            let cleaned = TextPrep.clean(added, options: settings.textOptions)
            guard let text = TextDiff.speakable(cleaned, typed: lastTyped) else { return }
            if snap.typed == nil { lastTyped = nil }
            Log.write("auto-read: \(text.count) new chars on \(snap.host ?? snap.app)")
            speak(text, source: "auto-read")
        case .replaced:
            // An in-page navigation (single-page apps change content without a new URL).
            newPage(latest, action: rule.newPage)
        case .none:
            break
        }
    }

    private func newPage(_ text: String, action: NewPageAction) {
        let main = TextPrep.mainContent(TextPrep.clean(text, options: settings.textOptions))
        switch action {
        case .nothing:
            return
        case .firstParagraph:
            guard let first = main.components(separatedBy: "\n").first(where: { $0.count >= 100 }) else { return }
            Log.write("auto-read: first paragraph of new page (\(first.count) chars)")
            speak(first, source: "auto-read page")
        case .summary:
            guard main.count > 300 else { speak(main, source: "auto-read page"); return }
            Task {
                guard let s = await Summarizer.summarizePage(main, progress: { _, _ in }) else { return }
                speak(s, source: "auto-read summary")
            }
        }
    }

    /// Reads now, or after whatever you're already listening to.
    private func speak(_ text: String, source: String) {
        if reader.isActive {
            waiting = (text, source)
        } else {
            reader.read(text, source: source, quiet: true)
        }
    }
}
