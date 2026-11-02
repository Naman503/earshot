import AppKit
import Combine
import ScreenCaptureKit
import EarshotCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static private(set) var shared: AppDelegate!

    let settings = Settings.shared
    let audio = AudioOutput()
    let kokoro = KokoroEngine()
    let grabber = TextGrabber()
    let hotKeys = HotKeys()
    let trackpad = Trackpad()
    private(set) var reader: Reader!
    private(set) var announcer: Announcer!
    let notifications = NotificationWatcher()
    private(set) var pageWatcher: PageWatcher!
    private(set) var dictation: Dictation!
    private var hud: HUD!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ note: Notification) {
        Self.shared = self
        reader = Reader(settings: settings, audio: audio, kokoro: kokoro)
        hud = HUD(reader: reader, settings: settings)
        announcer = Announcer(settings: settings, reader: reader)
        notifications.onBanner = { [weak self] in self?.announcer.handle($0) }
        pageWatcher = PageWatcher(settings: settings, reader: reader, grabber: grabber)
        dictation = Dictation(settings: settings, kokoro: kokoro, reader: reader)
        dictation.onStateChange = { [weak self] state in
            guard let self else { return }
            self.hotKeys.setEscapeActive(state == .listening || (self.reader.isActive && self.settings.escapeStops))
        }
        HotKeys.onRelease = { [weak self] action in
            if action == .dictate { self?.dictation.released() }
        }
        // Load the dictation model once the engine is up, so the first dictation is quick.
        kokoro.$status.removeDuplicates().sink { [weak self] status in
            guard let self, status == .ready, self.settings.dictationEnabled else { return }
            self.kokoro.warmSpeechToText(model: self.settings.dictationModel)
        }.store(in: &bag)
        Log.write("launch \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "") accessibility=\(AXIsProcessTrusted())")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "Earshot")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        kokoro.start()
        HotKeys.onAction = { [weak self] in self?.perform($0) }
        trackpad.onGesture = { [weak self] g in
            guard let self, self.settings.gesturesEnabled, let action = self.settings.gestures[g], action != .none else { return }
            Log.write("gesture: \(g.label) → \(action.rawValue)")
            // While a notification asks "Read it?", a reading tap means yes.
            if self.announcer.isAsking, self.settings.tapAnswersPrompt,
               [.paragraph, .smartRead, .readNotification].contains(action) {
                self.announcer.readLatestOrAnswer()
                return
            }
            // A tap on selected text reads exactly the selection.
            if self.settings.tapReadsSelection, [.paragraph, .sentence, .section, .fromHere, .smartRead].contains(action),
               let sel = self.grabber.selection(near: TextGrabber.pointer) {
                Log.write("gesture: reading the selection (\(sel.text.count) chars)")
                self.start(sel)
                return
            }
            self.perform(action)
        }

        settings.$shortcuts.sink { [weak self] in self?.hotKeys.register($0) }.store(in: &bag)
        settings.$gestures.combineLatest(settings.$gesturesEnabled).sink { [weak self] gestures, enabled in
            guard let self else { return }
            if enabled {
                self.trackpad.start(maxTaps: Self.maxTaps(gestures))
            } else {
                self.trackpad.stop()
            }
        }.store(in: &bag)
        reader.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.hud.update() } }.store(in: &bag)
        reader.onStateChange = { [weak self] state in
            guard let self else { return }
            self.hotKeys.setEscapeActive(state != .idle && self.settings.escapeStops)
            self.statusItem.button?.image = NSImage(systemSymbolName: state == .idle ? "headphones" : "waveform",
                                                    accessibilityDescription: "Earshot")
        }
        settings.$volume.sink { [weak self] _ in
            DispatchQueue.main.async { self?.reader.applyAudioSettings() }
        }.store(in: &bag)
        // Speed: the player follows at once; regeneration waits until the slider rests.
        settings.$speed.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reader.applyAudioSettings() }
        }.store(in: &bag)
        settings.$speed.dropFirst().debounce(for: .milliseconds(400), scheduler: DispatchQueue.main).sink { [weak self] _ in
            self?.reader.speedChanged()
        }.store(in: &bag)

        // Trackpads go away across sleep and when a Magic Trackpad connects.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartTrackpad() }
        }

        // Wake up web-content accessibility in browsers and Electron apps ahead of the first tap.
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            grabber.enableWebAccessibility(pid: app.processIdentifier)
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { _ = self?.grabber.enableWebAccessibility(pid: app.processIdentifier) }
        }

        notifications.start()
        pageWatcher.start()
        handleDebugArguments()
        if !AXIsProcessTrusted() { openSettings(tab: .general) }
    }

    func applicationWillTerminate(_ note: Notification) {
        reader.stop()
        kokoro.stop()
    }

    private func restartTrackpad() {
        guard settings.gesturesEnabled else { return }
        trackpad.restart(maxTaps: Self.maxTaps(settings.gestures))
    }

    private static func maxTaps(_ gestures: [TrackpadTap: ReadAction]) -> [Int: Int] {
        gestures.filter { $0.value != .none }.keys.reduce(into: [:]) { $0[$1.fingers] = max($0[$1.fingers] ?? 1, $1.taps) }
    }

    // MARK: Actions

    func perform(_ action: ReadAction) {
        switch action {
        case .smartRead:
            if let sel = grabber.selection() { start(sel) } else { grabAndRead(.paragraph) }
        case .paragraph: grabAndRead(.paragraph)
        case .sentence: grabAndRead(.sentence)
        case .fromHere: grabAndRead(.fromHere)
        case .window: grabAndRead(.window)
        case .section: grabAndRead(.section)
        case .visible: grabAndRead(.visible)
        case .selection:
            if let sel = grabber.selection() { start(sel) } else { reader.flash("Nothing selected") }
        case .pauseResume: reader.togglePause()
        case .stop:
            if dictation.state == .listening { dictation.cancel() } else if !announcer.dismissPending() { reader.stop() }
        case .dictate: dictation.pressed()
        case .readNotification: announcer.readLatestOrAnswer()
        case .summarize: summarize()
        case .autoReadToggle: pageWatcher.togglePin()
        case .clipboard:
            if let s = NSPasteboard.general.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reader.read(s, source: "clipboard")
            } else {
                reader.flash("The clipboard has no text")
            }
        case .readAgain:
            if let last = reader.history.first { reader.read(last, source: "read again") } else { reader.flash("Nothing read yet") }
        case .nextParagraph: reader.skipParagraph(1)
        case .previousParagraph: reader.skipParagraph(-1)
        case .nextSentence: reader.skip(1)
        case .previousSentence: reader.skip(-1)
        case .faster: reader.changeSpeed(by: 0.1)
        case .slower: reader.changeSpeed(by: -0.1)
        case .none: break
        }
    }

    private func grabAndRead(_ unit: GrabUnit) {
        guard AXIsProcessTrusted() else {
            reader.flash("Earshot needs Accessibility permission")
            openSettings(tab: .general)
            return
        }
        let point = TextGrabber.pointer
        let grabber = self.grabber
        let started = Date()
        Task.detached {
            let grab = await grabber.grab(unit, at: point)
            await MainActor.run {
                let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                Log.write("grab \(unit.rawValue) in \(app): \(grab?.source ?? "nothing") in \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(grab?.text.prefix(80) ?? "")")
                guard var grab else { self.reader.flash("Couldn't find text under the pointer"); return }
                // Paragraph reach: read N paragraphs above and below as set in Settings.
                if unit == .paragraph, self.settings.paragraphsBefore > 0 || self.settings.paragraphsAfter != 0 {
                    grab.text = TextUnits.expand(current: grab.text, before: grab.before ?? "", after: grab.after ?? "",
                                                 paragraphsBefore: self.settings.paragraphsBefore,
                                                 paragraphsAfter: self.settings.paragraphsAfter)
                }
                self.start(grab)
            }
        }
    }

    /// Summary of the selection or the page under the pointer, then "Read the whole page?".
    private func summarize() {
        guard AXIsProcessTrusted() else { reader.flash("Earshot needs Accessibility permission"); return }
        guard Summarizer.available else {
            reader.flash("Summaries need Apple Intelligence — reading the page instead")
            grabAndRead(.fromHere)
            return
        }
        let point = TextGrabber.pointer
        let grabber = self.grabber
        let selection = grabber.selection()
        reader.stop()
        reader.hold("Summarizing…")
        Task {
            let grab: Grab?
            if let selection { grab = selection } else { grab = await Task.detached { await grabber.grab(.window, at: point) }.value }
            guard let grab else { reader.clearNotice(); reader.flash("Couldn't find text to summarize"); return }
            let cleaned = TextPrep.clean(grab.text, options: settings.textOptions)
            let text = selection == nil ? TextPrep.mainContent(cleaned) : cleaned
            Log.write("summarize: \(text.count) chars from \(grab.source)")
            guard text.count > 500 else {
                reader.clearNotice()
                reader.read(text, source: "short page")
                return
            }
            let started = Date()
            let summary = await Summarizer.summarizePage(text) { [weak self] done, total in
                Task { @MainActor in self?.reader.hold(total > 1 ? "Summarizing… part \(min(done + 1, total)) of \(total)" : "Summarizing…") }
            }
            reader.clearNotice()
            Log.write("summarize: \(summary?.count ?? 0) chars in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            guard let summary else {
                reader.flash("Couldn't summarize this — reading it instead")
                reader.read(text, source: "page")
                return
            }
            reader.read("Here's the gist. " + summary, source: "summary", onFinish: { [weak self] in
                guard let self else { return }
                self.announcer.askYesNo(selection == nil ? "Read the whole page?" : "Read all of it?") { yes in
                    if yes { self.reader.read(text, source: "page after summary") } else { self.reader.resumeMedia() }
                }
            })
        }
    }

    private func start(_ grab: Grab) {
        if let f = grab.frame { hud.flash(rect: f) }
        reader.read(grab.text, source: grab.source)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status: String = switch kokoro.status {
        case .ready: "Kokoro voice ready"
        case .starting: "Kokoro starting… (Apple voice meanwhile)"
        case .notInstalled: "Kokoro not installed — using Apple voice"
        case .failed(let m): "Kokoro failed: \(m)"
        }
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        for action: ReadAction in [.smartRead, .section, .fromHere, .visible, .window, .summarize] {
            add(menu, action.title, action)
        }
        add(menu, dictation.state == .listening ? "Stop dictation" : "Start dictation", .dictate)
        add(menu, pageWatcher.pinnedTitle.map { "Stop auto-reading “\($0.prefix(40))”" } ?? "Auto-read new text on this page", .autoReadToggle)
        if reader.isActive {
            menu.addItem(.separator())
            add(menu, reader.state == .paused ? "Resume" : "Pause", .pauseResume)
            add(menu, "Stop", .stop)
        }
        if !reader.history.isEmpty {
            let recent = NSMenuItem(title: "Recently read", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (i, text) in reader.history.prefix(10).enumerated() {
                let title = text.replacingOccurrences(of: "\n", with: " ").prefix(60)
                let item = NSMenuItem(title: String(title) + (text.count > 60 ? "…" : ""), action: #selector(readHistory(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                sub.addItem(item)
            }
            recent.submenu = sub
            menu.addItem(recent)
        }
        if !announcer.history.isEmpty {
            let recent = NSMenuItem(title: "Recent notifications", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for note in announcer.history.prefix(10) {
                let item = NSMenuItem(title: "\(note.app): \(note.who)", action: #selector(readNote(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = note.id
                sub.addItem(item)
            }
            recent.submenu = sub
            menu.addItem(recent)
        }
        menu.addItem(.separator())
        let speed = NSMenuItem(title: String(format: "Speed: %.2g×", settings.speed), action: nil, keyEquivalent: "")
        let speeds = NSMenu()
        for s in [1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 3.0] {
            let item = NSMenuItem(title: String(format: "%.3g×", s), action: #selector(setSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s
            item.state = abs(settings.speed - s) < 0.01 ? .on : .off
            speeds.addItem(item)
        }
        speed.submenu = speeds
        menu.addItem(speed)
        let device = audio.target(settings: settings)
        menu.addItem(withTitle: device.map { "Output: \($0.name)" } ?? "Output: none allowed (\(settings.outputPolicy == .headphonesOnly ? "connect headphones" : "check Settings"))",
                     action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        let s = NSMenuItem(title: "Settings…", action: #selector(openSettingsMenu), keyEquivalent: ",")
        s.target = self
        menu.addItem(s)
        menu.addItem(withTitle: "Quit Earshot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: ReadAction) {
        let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action.rawValue
        if let combo = settings.shortcuts[action] {
            item.title += "    " + HotKeys.describe(combo)
        }
        menu.addItem(item)
    }

    @objc private func menuAction(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let action = ReadAction(rawValue: raw) else { return }
        // Let the menu close so the pointer target is the page, not the menu.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.perform(action) }
    }

    @objc private func readHistory(_ item: NSMenuItem) {
        guard reader.history.indices.contains(item.tag) else { return }
        reader.read(reader.history[item.tag], source: "read again")
    }

    @objc private func readNote(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String,
              let note = announcer.history.first(where: { $0.id == id }) else { return }
        reader.read("\(note.app). \(note.who). \(note.body)", source: "notification history")
    }

    @objc private func setSpeed(_ item: NSMenuItem) {
        if let s = item.representedObject as? Double { settings.speed = s }
    }

    @objc private func openSettingsMenu() { openSettings(tab: .howTo) }

    func openSettings(tab: SettingsTab) {
        SettingsNavigation.shared.tab = tab
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Earshot Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView()
                .environmentObject(settings).environmentObject(kokoro).environmentObject(audio).environmentObject(reader)
                .environmentObject(announcer).environmentObject(pageWatcher).environmentObject(dictation))
            w.setContentSize(NSSize(width: 920, height: 680))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Saves a PNG of every settings page (for checking the layout).
    private func renderSettings(to dir: String) {
        openSettings(tab: .howTo)
        let tabs = SettingsTab.allCases
        func shoot(_ i: Int) {
            guard i < tabs.count else { Log.write("render-settings: done"); return }
            SettingsNavigation.shared.tab = tabs[i]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let window = self.settingsWindow else { return }
                let url = URL(fileURLWithPath: "\(dir)/\(i)-\(tabs[i].rawValue).png")
                Task {
                    // The real on-screen pixels (needs Screen Recording), else an offscreen render.
                    if let content = try? await SCShareableContent.current,
                       let scw = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) {
                        let config = SCStreamConfiguration()
                        config.width = Int(scw.frame.width * 2)
                        config.height = Int(scw.frame.height * 2)
                        if let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: scw), configuration: config) {
                            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: url)
                            shoot(i + 1)
                            return
                        }
                    }
                    if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: url)
                    }
                    shoot(i + 1)
                }
            }
        }
        shoot(0)
    }

    // MARK: Debug

    /// --settings=<tab>, --say=<text>, --probe=<unit> (grab at the pointer after 3 s, log it, don't speak).
    private func handleDebugArguments() {
        for arg in CommandLine.arguments.dropFirst() {
            let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
            let value = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "--dump-nc":
                // Dumps Notification Center's accessibility tree a few times (banner research).
                for delay in [1.5, 3.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        guard let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else {
                            Log.write("dump-nc: not running"); return
                        }
                        Log.write("dump-nc t=\(delay):\n" + AXDump.tree(AXUIElementCreateApplication(nc.processIdentifier)))
                    }
                }
            case "--summarize-app":
                // Summarizes the named app's front page into the log, silently.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    guard let raw = self.grabber.pageText(inApp: value) else { Log.write("summarize-app: no page text"); return }
                    let text = TextPrep.mainContent(TextPrep.clean(raw, options: self.settings.textOptions))
                    Log.write("summarize-app: \(raw.count) chars raw, \(text.count) after cleanup; starts \"\(text.prefix(60))\"")
                    let t0 = Date()
                    Task {
                        let s = await Summarizer.summarizePage(text) { d, n in Log.write("summarize-app: part \(d)/\(n)") }
                        Log.write("summarize-app: \(Int(Date().timeIntervalSince(t0) * 1000)) ms →\n\(s ?? "nil")")
                    }
                }
            case "--watch-probe":
                // URL + cost of fetching the whole page text, for auto-read tuning.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    for _ in 0..<3 {
                        let t0 = Date()
                        let info = self.grabber.pageInfo(inApp: value)
                        Log.write("watch-probe: url=\(info?.url ?? "nil") chars=\(info?.text.count ?? -1) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
                    }
                }
            case "--settings":
                openSettings(tab: SettingsTab(rawValue: value) ?? .howTo)
            case "--render-settings":
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.renderSettings(to: value) }
            case "--say":
                waitForEngine { self.reader.read(value, source: "--say") }
            case "--probe", "--probe-app":
                let unit: GrabUnit = parts[0] == "--probe" ? GrabUnit(rawValue: value) ?? .paragraph : .paragraph
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    let p = parts[0] == "--probe-app" ? self.grabber.samplePoint(inApp: value) ?? .zero : TextGrabber.pointer
                    let grabber = self.grabber
                    Task.detached {
                        Log.write("probe diagnose: \(grabber.diagnose(at: p))")
                        let g = await grabber.grab(unit, at: p)
                        Log.write("probe \(unit.rawValue) at \(p): source=\(g?.source ?? "nil") frame=\(String(describing: g?.frame))\n---\n\(g?.text.prefix(1500) ?? "")\n---")
                    }
                }
            default:
                break
            }
        }
    }

    private func waitForEngine(_ then: @escaping () -> Void, tries: Int = 40) {
        if kokoro.status == .ready || tries == 0 || kokoro.status == .notInstalled { then(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.waitForEngine(then, tries: tries - 1) }
    }
}
