import AppKit
import Combine
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
            if self.announcer.pending != nil, self.settings.tapAnswersPrompt,
               [.paragraph, .smartRead, .readNotification].contains(action) {
                self.announcer.readLatestOrAnswer()
                return
            }
            self.perform(action)
        }

        settings.$shortcuts.sink { [weak self] in self?.hotKeys.register($0) }.store(in: &bag)
        settings.$gestures.combineLatest(settings.$gesturesEnabled).sink { [weak self] gestures, enabled in
            guard let self else { return }
            if enabled {
                self.trackpad.start(multiTapFingers: Set(gestures.filter { $0.key.taps > 1 && $0.value != .none }.map(\.key.fingers)))
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
        settings.$speed.combineLatest(settings.$volume).sink { [weak self] _, _ in
            DispatchQueue.main.async { self?.reader.applyAudioSettings() }
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
        handleDebugArguments()
        if !AXIsProcessTrusted() { openSettings(tab: .general) }
    }

    func applicationWillTerminate(_ note: Notification) {
        reader.stop()
        kokoro.stop()
    }

    private func restartTrackpad() {
        guard settings.gesturesEnabled else { return }
        trackpad.restart(multiTapFingers: Set(settings.gestures.filter { $0.key.taps > 1 }.map(\.key.fingers)))
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
        case .selection:
            if let sel = grabber.selection() { start(sel) } else { reader.flash("Nothing selected") }
        case .pauseResume: reader.togglePause()
        case .stop: if !announcer.dismissPending() { reader.stop() }
        case .readNotification: announcer.readLatestOrAnswer()
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
                if let grab { self.start(grab) } else { self.reader.flash("Couldn't find text under the pointer") }
            }
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
        for action: ReadAction in [.smartRead, .fromHere, .window] {
            add(menu, action.title, action)
        }
        if reader.isActive {
            menu.addItem(.separator())
            add(menu, reader.state == .paused ? "Resume" : "Pause", .pauseResume)
            add(menu, "Stop", .stop)
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

    @objc private func readNote(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String,
              let note = announcer.history.first(where: { $0.id == id }) else { return }
        reader.read("\(note.app). \(note.who). \(note.body)", source: "notification history")
    }

    @objc private func setSpeed(_ item: NSMenuItem) {
        if let s = item.representedObject as? Double { settings.speed = s }
    }

    @objc private func openSettingsMenu() { openSettings(tab: .voice) }

    func openSettings(tab: SettingsTab) {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Earshot Settings"
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        settingsWindow?.contentView = NSHostingView(rootView: SettingsView(initialTab: tab)
            .environmentObject(settings).environmentObject(kokoro).environmentObject(audio).environmentObject(reader)
            .environmentObject(announcer))
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
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
            case "--settings":
                openSettings(tab: SettingsTab(rawValue: value) ?? .voice)
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
