import AppKit
import AVFoundation
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
    let dockSwipes = DockSwipeWatcher()
    private(set) var reader: Reader!
    private(set) var announcer: Announcer!
    let notifications = NotificationWatcher()
    private(set) var pageWatcher: PageWatcher!
    private var macDictation: MacDictation!
    private var holdKeys: HoldKeys!
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
        macDictation = MacDictation(reader: reader)
        macDictation.watchKeys()
        holdKeys = HoldKeys(settings: settings, reader: reader)
        holdKeys.start()
        HotKeys.onRelease = { [weak self] action in
            if action == .dictate { self?.macDictation.released() }
            if action == .boost { self?.boostReleased() }
        }
        Log.write("launch \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "") accessibility=\(AXIsProcessTrusted())")
        watchForStalls()
        dockSwipes.start()
        // A swipe that switched desktops can register as a tap a moment before
        // the switch: if reading started from a gesture just now, undo it.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lastSpaceChange = Date()
                if Date().timeIntervalSince(self.lastGesture) < 1, self.reader.isActive {
                    Log.write("gesture: reading stopped — that was a desktop swipe")
                    self.reader.stop()
                }
            }
        }
        // Free the voice's memory after a while without reading, if chosen.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.reader.isActive { self.lastReading = Date(); return }
                guard self.settings.sleepVoiceWhenIdle, self.kokoro.status == .ready,
                      Date().timeIntervalSince(self.lastReading) > Double(self.settings.sleepVoiceAfterMinutes) * 60 else { return }
                self.kokoro.sleep()
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "Earshot")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        kokoro.start()
        HotKeys.onAction = { [weak self] action in
            guard let self else { return }
            if [.smartRead, .paragraph, .sentence, .fromHere, .section, .visible, .selection, .window, .clipboard, .readAgain, .summarize].contains(action) {
                self.kokoro.warm(voice: self.settings.voice)
            }
            self.perform(action)
        }
        trackpad.onGesture = { [weak self] g in
            guard let self, self.settings.gesturesEnabled, let action = self.settings.gestures[g], action != .none else { return }
            // A desktop switch (four-finger swipe) right around it: it was a swipe.
            if self.dockSwipes.swipingNow {
                Log.write("gesture: \(g.label) ignored (desktop swipe)")
                return
            }
            if Date().timeIntervalSince(self.lastSpaceChange) < 1 {
                Log.write("gesture: \(g.label) ignored (desktop switch)")
                return
            }
            self.lastGesture = Date()
            Log.write("gesture: \(g.label) → \(action.rawValue)")
            if action != .stop, action != .pauseResume { self.kokoro.warm(voice: self.settings.voice) }
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
        settings.$readScope.sink { [weak self] in self?.grabber.readScope = $0 }.store(in: &bag)
        settings.$gestures.combineLatest(settings.$gesturesEnabled).sink { [weak self] gestures, enabled in
            guard let self else { return }
            if enabled {
                self.trackpad.start(maxTaps: Self.maxTaps(gestures))
            } else {
                self.trackpad.stop()
            }
        }.store(in: &bag)
        reader.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.hud.update() } }.store(in: &bag)
        reader.onWord = { [weak self] word, next, locator in self?.hud.showWord(word, next: next, locator: locator) }
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
        settings.$slowSpeed.dropFirst().debounce(for: .milliseconds(400), scheduler: DispatchQueue.main).sink { [weak self] _ in
            self?.reader.speedChanged()
        }.store(in: &bag)
        settings.$boostSpeed.dropFirst().debounce(for: .milliseconds(400), scheduler: DispatchQueue.main).sink { [weak self] _ in
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

    private var lastReading = Date()
    private var lastSpaceChange = Date.distantPast
    private var lastGesture = Date.distantPast
    private let stallQueue = DispatchQueue(label: "earshot.stalls", qos: .utility)
    private var stallTimer: DispatchSourceTimer?

    /// Logs whenever the app is slow to respond (main thread busy > 0.3 s), so
    /// a freeze leaves a trace of what was happening around it.
    private func watchForStalls() {
        // A .common-mode timer keeps firing while a menu is open, so tracking
        // time doesn't count; a genuinely blocked main thread still delays it.
        var last = Date()
        let t = Timer(timeInterval: 2, repeats: true) { _ in
            let now = Date()
            let lag = now.timeIntervalSince(last) - 2
            // Over 30 s is the Mac having slept, not the app being busy.
            if lag > 0.3, lag < 30 { Log.write("stall: the app was busy for \(Int(lag * 1000)) ms") }
            last = now
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
    }

    private var boostPressedAt = Date.distantPast

    /// Holding the boost key is a burst: back to normal speed on release.
    private func boostReleased() {
        if reader.boosted, Date().timeIntervalSince(boostPressedAt) > 0.45 { reader.setBoost(false) }
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
            if !announcer.dismissPending() { reader.stop() }
        case .dictate: macDictation.pressed()
        case .boost:
            boostPressedAt = Date()
            reader.setBoost(!reader.boosted)
        case .slowMode:
            reader.setSpeedMode(reader.speedMode == .slow ? .normal : .slow)
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
                if (grab?.text.count ?? 0) < 25 {
                    // Grabbed almost nothing: record what's under the pointer, to see why.
                    let grabber = self.grabber
                    DispatchQueue.global().async { Log.write("grab: little text — under the pointer:\n  \(grabber.chainAt(point))") }
                }
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
        if settings.flashParagraph, let f = grab.frame { hud.flash(rect: f) }
        reader.read(grab.text, source: grab.source, locator: grab.locator)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // The live card: status, progress, playback controls, quick speed.
        let header = NSMenuItem()
        let card = NSHostingView(rootView: MenuHeader(reader: reader, kokoro: kokoro, settings: settings,
                                                      output: audio.target(settings: settings)?.name))
        card.setFrameSize(card.fittingSize)
        header.view = card
        menu.addItem(header)
        menu.addItem(.separator())
        add(menu, "Read under the pointer", .smartRead)
        add(menu, "Read the clipboard", .clipboard)
        add(menu, "Summarize this page", .summarize)
        add(menu, pageWatcher.pinnedTitle.map { "Stop auto-reading “\($0.prefix(40))”" } ?? "Auto-read new text on this page", .autoReadToggle)
        let more = NSMenuItem(title: "More ways to read", action: nil, keyEquivalent: "")
        let moreMenu = NSMenu()
        for action: ReadAction in [.section, .fromHere, .visible, .window] {
            add(moreMenu, action.title, action)
        }
        add(moreMenu, "Start Mac dictation", .dictate)
        more.submenu = moreMenu
        menu.addItem(more)
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
        let s = NSMenuItem(title: "Settings…", action: #selector(openSettingsMenu), keyEquivalent: ",")
        s.target = self
        menu.addItem(s)
        menu.addItem(withTitle: "Quit Earshot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: ReadAction) {
        let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action.rawValue
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
    @objc func openSettingsFromMenu(_ sender: Any?) { openSettings(tab: .howTo) }

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
                .environmentObject(announcer).environmentObject(pageWatcher))
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
            case "--dump-text":
                // Writes the named app's page text to the log folder, to tune what gets read.
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    let text = self.grabber.dumpTexts(inApp: value)
                    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Earshot/page-text.txt")
                    try? text.write(to: url, atomically: true, encoding: .utf8)
                    Log.write("dump-text: \(text.count) chars")
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
            case "--para-test":
                // "App|needle": paragraph reach around the text containing needle (reads nothing aloud).
                let bits = value.split(separator: "|", maxSplits: 1).map(String.init)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    guard bits.count == 2, let el = self.grabber.findText(inApp: bits[0], needle: bits[1]) else { Log.write("para-test: not found"); return }
                    Log.write("para-test chain:\n\(self.grabber.describeAncestors(el))")
                    let n = self.grabber.blockNeighbours(of: el)
                    Log.write("para-test before (last 3):\n\(n?.before.components(separatedBy: "\n").suffix(3).joined(separator: "\n") ?? "nil")")
                    Log.write("para-test container children:\n\(self.grabber.describeChildren(of: el, up: 2))")
                    Log.write("para-test current: \(n?.current ?? "nil")")
                    Log.write("para-test after:\n\(n?.after ?? "nil")")
                    for (b, a) in [(1, 1), (0, -1), (2, 0)] {
                        let t = TextUnits.expand(current: "<<CURRENT>>", before: n?.before ?? "", after: n?.after ?? "", paragraphsBefore: b, paragraphsAfter: a)
                        Log.write("para-test reach \(b) up / \(a) down:\n\(t)")
                    }
                }
            case "--locate-test":
                // "App|needle": finds the paragraph, then each of its words on screen (silent).
                let bits = value.split(separator: "|", maxSplits: 1).map(String.init)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    guard bits.count == 2, let el = self.grabber.findText(inApp: bits[0], needle: bits[1]),
                          let loc = self.grabber.locatorForTest(el) else { Log.write("locate-test: not found"); return }
                    let words = SpokenWord.grouped(SpokenWord.estimated(for: loc.text, duration: 10))
                    DispatchQueue.global().async {
                        let t0 = Date()
                        var hits = 0
                        for w in words.prefix(25) {
                            let phrase = (loc.text as NSString).substring(with: w.range)
                            let box = loc.locator.locate(phrase, next: String((loc.text as NSString).substring(from: NSMaxRange(w.range)).prefix(60)))
                            if box != nil { hits += 1 }
                            Log.write("locate-test: \(phrase) → \(box.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "nil")")
                        }
                        Log.write("locate-test: \(hits)/\(min(25, words.count)) found in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
                    }
                }
            case "--marker-test":
                // "App|needle": glides the word marker over a paragraph (silent, for screenshots).
                let bits = value.split(separator: "|", maxSplits: 1).map(String.init)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    guard bits.count == 2, let el = self.grabber.findText(inApp: bits[0], needle: bits[1]),
                          let loc = self.grabber.locatorForTest(el) else { Log.write("marker-test: not found"); return }
                    let words = SpokenWord.grouped(SpokenWord.estimated(for: loc.text, duration: 10)).prefix(30)
                    for (n, w) in words.enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(n) * 0.25) {
                            self.hud.showWord((loc.text as NSString).substring(with: w.range), next: (loc.text as NSString).substring(from: NSMaxRange(w.range)).prefix(60).description, locator: loc.locator)
                        }
                    }
                    // Screenshots of the display at two moments, into the log folder.
                    for (k, t) in [(1, 1.6), (2, 3.3)] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                            Task {
                                guard let content = try? await SCShareableContent.current, let d = content.displays.first else { return }
                                let config = SCStreamConfiguration()
                                config.width = d.width * 2
                                config.height = d.height * 2
                                guard let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: config) else { Log.write("marker-test: capture failed"); return }
                                let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Earshot/marker-\(k).png")
                                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: url)
                                Log.write("marker-test: saved \(url.path)")
                            }
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(words.count) * 0.25 + 0.5) { self.hud.showWord(nil, next: "", locator: nil) }
                }
            case "--macdictation-test":
                // Starts Mac dictation in Earshot's own test window for 3 s and logs how fast it listened.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 500, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
                    window.title = "Earshot dictation check"
                    let field = NSTextField(frame: NSRect(x: 10, y: 20, width: 480, height: 40))
                    window.contentView?.addSubview(field)
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    window.makeFirstResponder(field)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        Log.write("macdictation-test: input before: \(MacDictation.listeningApps())")
                        self.macDictation.pressed()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            self.macDictation.pressed()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { window.close() }
                        }
                    }
                }
            case "--mickey-test":
                // Presses the 🎤 key twice in Earshot's own window; dictation must end up off.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 500, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
                    window.title = "Earshot dictation check"
                    let field = NSTextField(frame: NSRect(x: 10, y: 20, width: 480, height: 40))
                    window.contentView?.addSubview(field)
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    window.makeFirstResponder(field)
                    func mic() {
                        for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 176, keyDown: down)?.post(tap: .cghidEventTap) }
                    }
                    // Never press anything unless our own window is really in front.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
                            Log.write("mickey-test: Earshot isn't in front — not pressing anything")
                            window.close()
                            return
                        }
                        Log.write("mickey-test: press 1"); mic()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        guard window.isVisible, NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else { return }
                        Log.write("mickey-test: press 2"); mic()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                        Log.write("mickey-test: after 4 s — dictation on: \(MacDictation.menuItem(starting: false) != nil), mic open: \(MacDictation.dictationHearing())")
                        window.close()
                    }
                }
            case "--locate-own":
                // Repeated words + reading that starts above the tapped paragraph, in Earshot's own window.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let paras = ["The cat sat on the mat and the dog sat on the rug in the hall.",
                                 "Then the dog ran to the door and the cat ran to the window of the hall.",
                                 "In the end the cat and the dog both sat by the fire in the hall."]
                    let full = paras.joined(separator: "\n")
                    let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 360, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
                    let tv = NSTextView(frame: NSRect(x: 10, y: 10, width: 340, height: 180))
                    tv.string = full
                    window.contentView?.addSubview(tv)
                    window.orderFrontRegardless()
                    let root = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
                    let start = (full as NSString).range(of: paras[1]).location  // tapped paragraph 2
                    let spoken = paras[0] + " " + paras[1]                         // reach: one paragraph above
                    DispatchQueue.global().async {
                        func find(_ e: AXUIElement) -> AXUIElement? {
                            var r: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &r)
                            if (r as? String) == "AXTextArea" { return e }
                            var k: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &k)
                            for c in k as? [AXUIElement] ?? [] { if let f = find(c) { return f } }
                            return nil
                        }
                        guard let el = find(root) else { Log.write("locate-own: no text view"); return }
                        let loc = self.grabber.textViewLocator(el, text: full, start: start)
                        let words = SpokenWord.grouped(SpokenWord.estimated(for: spoken, duration: 10))
                        var lastY = -1.0, lastX = -1.0, wrong = 0
                        for w in words {
                            let ns = spoken as NSString
                            let phrase = ns.substring(with: w.range)
                            let box = loc.locate(phrase, next: String(ns.substring(from: NSMaxRange(w.range)).prefix(60)))
                            if let b = box, (b.minY < lastY - 1 || (abs(b.minY - lastY) < 1 && b.minX < lastX)) { wrong += 1 }
                            if let b = box { lastY = b.minY; lastX = b.minX }
                            Log.write("locate-own: \(phrase) → \(box.map { "\(Int($0.minX)),\(Int($0.minY))" } ?? "nil") at \(loc.lastRange.map { "\($0.location)" } ?? "-")")
                            loc.lastRange = nil
                        }
                        Log.write("locate-own: \(words.count) words, \(wrong) out of order")
                        DispatchQueue.main.async { window.close() }
                    }
                }
            case "--read-muted":
                // "App": muted reading of a long paragraph in that app, with the page
                // highlight, to measure what the app does while reading.
                waitForEngine {
                    DispatchQueue.global().async {
                        guard let el = self.grabber.findText(inApp: value, needle: "*"), let loc = self.grabber.locatorForTest(el) else {
                            Log.write("read-muted: nothing found"); return
                        }
                        DispatchQueue.main.async {
                            self.reader.testMuted = true
                            self.reader.read(loc.text, source: "muted test", quiet: true, locator: loc.locator)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                                self.reader.stop()
                                self.reader.testMuted = false
                            }
                        }
                    }
                }
            case "--extract-test":
                // A page with every awkward structure, in Earshot's own window: logs what
                // "read from the first paragraph to the end" would read, line by line.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.extractTest(app: value) }
            case "--wake-test":
                // Puts the voice to sleep, then a muted reading: logs how long waking takes.
                waitForEngine {
                    self.kokoro.sleep()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.reader.testMuted = true
                        Log.write("wake-test: reading while asleep")
                        self.reader.read("Testing how quickly the voice wakes up after it was put to sleep.", source: "wake test", quiet: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                            self.reader.stop()
                            self.reader.testMuted = false
                        }
                    }
                }
            case "--follow-test":
                // "App|needle": reads nothing aloud. Prepares the reading a tap there would
                // make and runs every word through the page finder, logging where it fails.
                DispatchQueue.global().async {
                    var hit: AXUIElement?
                    for _ in 0..<4 where hit == nil {  // the page tree may take a moment to come back
                        hit = self.grabber.findText(inApp: value.components(separatedBy: "|")[0], needle: value.components(separatedBy: "|")[1])
                        if hit == nil { sleep(1) }
                    }
                    guard let el = hit,
                          var g = self.grabber.grabForTest(el), let loc = g.locator else { Log.write("follow-test: no grab"); return }
                    let s = DispatchQueue.main.sync { self.settings }
                    g.text = TextUnits.expand(current: g.text, before: g.before ?? "", after: g.after ?? "",
                                              paragraphsBefore: s.paragraphsBefore, paragraphsAfter: s.paragraphsAfter)
                    let text = TextPrep.apply(s.pronunciations, to: TextPrep.clean(g.text, options: s.textOptions))
                    var found = 0, missed = 0
                    for piece in TextPrep.pieces(text, technical: s.technicalText) where !piece.technical {
                        let ns = piece.text as NSString
                        var line = ""
                        for w in SpokenWord.grouped(SpokenWord.estimated(for: piece.text, duration: 10)) {
                            let phrase = ns.substring(with: w.range)
                            let ok = loc.locate(phrase, next: String(ns.substring(from: NSMaxRange(w.range)).prefix(60))) != nil
                            if ok { found += 1 } else {
                                if missed == 0, let r = loc as? TextRunLocator { Log.write("follow-test: first miss “\(phrase)” near: \(r.debugContext)") }
                                missed += 1
                            }
                            line += ok ? phrase + " " : "[\(phrase)] "
                        }
                        Log.write("follow-test: \(line)")
                    }
                    Log.write("follow-test: visible \(loc.visibleArea().map { "\($0)" } ?? "unknown"); \(loc.debugView)")
                    Log.write("follow-test: \(found) found, \(missed) missed")
                }
            case "--scroll-test":
                // "App|needle": glides that app's page 150 px up and back with
                // Earshot's scroll steps (pointer must rest over the page),
                // logging how far the text really moved.
                DispatchQueue.global().async {
                    let parts = value.components(separatedBy: "|")
                    guard let el = self.grabber.findText(inApp: parts[0], needle: parts[1]),
                          let f0 = self.grabber.elementFrame(el) else { Log.write("scroll-test: no text"); return }
                    var pid: pid_t = 0
                    AXUIElementGetPid(el, &pid)
                    let view = CGRect(x: 0, y: 0, width: 20000, height: 20000)  // the window check still applies
                    let ok = DispatchQueue.main.sync { SmoothScroller.canScroll(pid: pid, view: view) }
                    func glide(_ dy: CGFloat) {
                        for _ in 0..<10 { DispatchQueue.main.sync { _ = SmoothScroller.post(-dy / 10, pid: pid, view: view) }; usleep(16_000) }
                        usleep(300_000)
                    }
                    glide(-150)
                    let f1 = self.grabber.elementFrame(el)
                    glide(150)
                    let f2 = self.grabber.elementFrame(el)
                    let m = CGEvent(source: nil)?.location ?? .zero
                    Log.write("scroll-test: mouse \(m) view \(view) owner \(DispatchQueue.main.sync { SmoothScroller.windowOwner(at: m) } ?? -1) pid \(pid)")
                    Log.write("scroll-test: can scroll \(ok), y \(Int(f0.minY)) → \(f1.map { Int($0.minY) } ?? -1) → \(f2.map { Int($0.minY) } ?? -1)")
                }
            case "--room-test":
                // "App|needle": the chain of boxes above that text (to find the
                // scrolling content's true height).
                DispatchQueue.global().async {
                    let parts = value.components(separatedBy: "|")
                    guard let el = self.grabber.findText(inApp: parts[0], needle: parts[1]) else { Log.write("room-test: no text"); return }
                    Log.write("room-test: visible \(self.grabber.visibleFrame(of: el).map { "\($0)" } ?? "?")")
                    for line in self.grabber.lastTexts(near: el, count: 25) { Log.write("room-test: \(line)") }
                    if let v = self.grabber.visibleFrame(of: el) ?? nil {
                        let t = Date()
                        let web = self.grabber.webAreaFrame(of: el) ?? v
                        Log.write("room-test: page bottom below \(web): \(self.grabber.pageBottom(from: el, below: web, column: self.grabber.elementFrame(el).map { $0.minX...$0.maxX }).map { "\($0)" } ?? "none") in \(Int(Date().timeIntervalSince(t) * 1000)) ms")
                    }
                }
            case "--menu-shot":
                // Renders the menu-bar popup card to a PNG (layout check).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let card = NSHostingView(rootView: MenuHeader(reader: self.reader, kokoro: self.kokoro, settings: self.settings,
                                                                  output: "OnePlus Buds 4").background(Color(red: 0.15, green: 0.15, blue: 0.16)))
                    card.setFrameSize(card.fittingSize)
                    let w = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: card.fittingSize),
                                     styleMask: .borderless, backing: .buffered, defer: false)
                    w.appearance = NSAppearance(named: .darkAqua)
                    w.contentView = card
                    w.orderBack(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds)!
                        card.cacheDisplay(in: card.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: value))
                        Log.write("menu-shot: \(card.fittingSize) saved \(value)")
                        w.orderOut(nil)
                    }
                }
            case "--demo-record":
                // Records the README demo into <value>/demo.mov: a styled sample
                // document in Earshot's own window, read muted with the live word
                // highlight, the window region captured with ScreenCaptureKit.
                // The audio is synthesized separately and muxed in afterwards.
                waitForEngine { self.demoRecord(into: URL(fileURLWithPath: value, isDirectory: true)) }
            case "--marker-looks":
                // Shows and photographs the marker in each style/colour (nothing saved).
                let dir = URL(fileURLWithPath: value)
                let looks: [(HighlightStyle, HighlightColor)] = [(.soft, .blue), (.soft, .yellow), (.soft, .accent), (.bold, .yellow), (.bold, .green), (.bold, .pink)]
                for (i, look) in looks.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(i) * 1.2) {
                        self.hud.testMarkerLook(style: look.0, color: look.1, rect: CGRect(x: 820, y: 560, width: 90, height: 18),
                                                file: dir.appendingPathComponent("\(i)-\(look.0)-\(look.1).png"))
                    }
                }
            case "--marker-variant":
                // Shows the word marker mid-screen for 4 s with a given window behaviour.
                let variants: [String: NSWindow.CollectionBehavior] = [
                    "now": [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .canJoinAllApplications, .auxiliary],
                    "noaux": [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .canJoinAllApplications],
                    "old": [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle],
                    "allapps": [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .canJoinAllApplications],
                ]
                HUD.overlayBehavior = variants[value] ?? HUD.overlayBehavior
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.hud.testMarker(CGRect(x: 800, y: 560, width: 120, height: 18))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.hud.testMarkerHide() }
                }
            case "--speed-test":
                // Muted reading with speed changes; logs whether audio is re-made at each speed.
                // "--speed-test=90" first stays idle 90 s (to test a cold, swapped-out engine).
                waitForEngine { DispatchQueue.main.asyncAfter(deadline: .now() + (Double(value) ?? 0)) {
                    self.reader.testMuted = true
                    let text = String(repeating: "This sentence is here so the reader has plenty of speech to work with during the test. ", count: 12)
                    self.reader.read(text, source: "speed test", quiet: true)
                    for (t, mode) in [(2.0, Reader.SpeedMode.slow), (11, .normal), (13, .boost), (17, .normal)] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + t) { self.reader.setSpeedMode(mode, quiet: true) }
                    }
                    for k in 1...36 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 0.5) {
                            Log.write("speed-test t=\(Double(k) * 0.5): \(self.reader.debugSpeedState)")
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 18.5) {
                        self.reader.stop()
                        self.reader.testMuted = false
                    }
                } }
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

    /// Logs what "read from the START paragraph to the end" would read in a
    /// test page opened in the named browser (see scripts/extract-test.sh).
    private func extractTest(app: String) {
        DispatchQueue.global().async {
            var found: AXUIElement?
            for _ in 0..<5 where found == nil {  // the browser builds its tree after the first ask
                found = self.grabber.findText(inApp: app, needle: "START")
                if found == nil { sleep(1) }
            }
            guard let el = found else { Log.write("extract-test: START not found"); return }
            let n = self.grabber.blockNeighbours(of: el)
            Log.write("extract-test after START:\n" + (n?.after ?? "nil"))
        }
    }

    private func waitForEngine(_ then: @escaping () -> Void, tries: Int = 40) {
        if kokoro.status == .ready || tries == 0 || kokoro.status == .notInstalled { then(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.waitForEngine(then, tries: tries - 1) }
    }

    // MARK: README demo recording (--demo-record)

    static let demoBody = """
    Earshot reads whatever is on your screen in a natural voice, straight into your headphones. \
    Every word is highlighted as it is spoken, and the page scrolls by itself, like a teleprompter.
    What you are hearing is Kokoro, a small neural voice running entirely on this Mac. \
    It is reading at two point four times its natural pace, and it still sounds like this.
    """

    private func demoRecord(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let title = "Earshot"
        let body = Self.demoBody
        // The sample document window.
        let rect = NSRect(x: 320, y: 300, width: 840, height: 480)
        let window = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Sample"
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .white
        let tv = NSTextView(frame: NSRect(origin: .zero, size: rect.size))
        tv.isEditable = false
        tv.backgroundColor = .white
        tv.textContainerInset = NSSize(width: 56, height: 44)
        tv.autoresizingMask = [.width, .height]
        let doc = NSMutableAttributedString()
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.paragraphSpacing = 16
        doc.append(NSAttributedString(string: title + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: NSColor.black, .paragraphStyle: titleStyle]))
        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.lineSpacing = 7
        bodyStyle.paragraphSpacing = 14
        doc.append(NSAttributedString(string: body, attributes: [
            .font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor(white: 0.12, alpha: 1), .paragraphStyle: bodyStyle]))
        tv.textStorage?.setAttributedString(doc)
        window.contentView = tv
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        let full = tv.string
        let bodyStart = (full as NSString).range(of: body).location

        Task { @MainActor in
            // Record just this window's screen region.
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let display = content.displays.first else { Log.write("demo: no display"); return }
            let f = window.frame
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: f.minX, y: CGFloat(display.height) - f.maxY, width: f.width, height: f.height)
            config.width = Int(f.width) * 2
            config.height = Int(f.height) * 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.showsCursor = false
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
            let recConfig = SCRecordingOutputConfiguration()
            let movie = dir.appendingPathComponent("demo.mov")
            try? FileManager.default.removeItem(at: movie)
            recConfig.outputURL = movie
            recConfig.videoCodecType = .h264
            let rec = SCRecordingOutput(configuration: recConfig, delegate: self.demoDelegate)
            do {
                try stream.addRecordingOutput(rec)
                try await stream.startCapture()
            } catch {
                Log.write("demo: capture failed to start: \(error)")
                return
            }
            self.demoStream = stream

            // Find our own text view and read the body, muted, with the highlight.
            try? await Task.sleep(for: .seconds(1.2))
            let root = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            func findTextArea(_ e: AXUIElement) -> AXUIElement? {
                var r: CFTypeRef?
                AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &r)
                if (r as? String) == "AXTextArea" { return e }
                var k: CFTypeRef?
                AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &k)
                for c in k as? [AXUIElement] ?? [] { if let found = findTextArea(c) { return found } }
                return nil
            }
            guard let el = findTextArea(root) else { Log.write("demo: no text view"); return }
            let loc = self.grabber.textViewLocator(el, text: full, start: bodyStart)
            self.reader.testMuted = true
            Log.write(String(format: "demo: read called at %.3f", Date().timeIntervalSince1970))
            self.reader.read(body, source: "demo", quiet: true, locator: loc, onFinish: {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    try? await self.demoStream?.stopCapture()
                    self.demoStream = nil
                    self.reader.testMuted = false
                    Log.write("demo: saved \(movie.path)")
                }
            }, onInterrupt: nil)
        }
    }
}

private var demoStreamKey: UInt8 = 0

extension AppDelegate {
    fileprivate var demoStream: SCStream? {
        get { objc_getAssociatedObject(self, &demoStreamKey) as? SCStream }
        set { objc_setAssociatedObject(self, &demoStreamKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
    fileprivate var demoDelegate: DemoRecordingDelegate { DemoRecordingDelegate.shared }
}

/// Logs when ScreenCaptureKit actually starts writing frames, so the demo's
/// audio can be placed at the right moment when muxing.
final class DemoRecordingDelegate: NSObject, SCRecordingOutputDelegate {
    static let shared = DemoRecordingDelegate()
    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Log.write(String(format: "demo: recording started at %.3f", Date().timeIntervalSince1970))
    }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        Log.write("demo: recording failed: \(error)")
    }
}
