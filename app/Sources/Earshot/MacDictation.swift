import AppKit
import ApplicationServices
import CoreAudio

/// Makes the Mac's own dictation dependable, however it's started (the 🎤 key,
/// pressing Control twice, Edit ▸ Start Dictation, or ⌃⌥D):
///   • ⌃⌥D presses the front app's Start Dictation directly (hold to talk, or
///     tap to start and stop), after stopping Earshot's reading and ducking;
///   • after any dictation start, it checks the microphone really opened.
///     Dictation sometimes comes up "on" but deaf; then it does what you'd do
///     by hand — turns it off and on again — and if that fails too, restarts
///     the dictation helper and tries once more.
/// A warm start listens in ~0.2 s, a cold one in ~1–2 s. Every attempt is logged.
@MainActor
final class MacDictation {
    private let reader: Reader
    private var pressedAt = Date.distantPast
    private var check: Timer?
    private var checkID = 0
    private var tap: CFMachPort?
    private var lastControl = Date.distantPast
    /// Whether dictation is on, as last seen (kept current while it's on).
    private var isOn = false

    init(reader: Reader) {
        self.reader = reader
    }

    // MARK: ⌃⌥D

    func pressed() {
        pressedAt = Date()
        if isOn || Self.dictationOn() {
            isOn = false
            stop()
        } else {
            start()
        }
    }

    /// A long press is hold-to-talk: letting go finishes.
    func released() {
        if Date().timeIntervalSince(pressedAt) > 0.45, Self.menuItem(starting: false) != nil { stop() }
    }

    private func start() {
        getOutOfTheWay()
        guard let item = Self.menuItem(starting: true) else {
            reader.flash("This app has no dictation menu — use the 🎤 key")
            Log.write("mac-dictation: no Start Dictation menu in \(Self.frontName)")
            return
        }
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        Log.write("mac-dictation: started with ⌃⌥D in \(Self.frontName)")
        expected = true
        verify(true, since: Date(), step: 0)
    }

    private func stop() {
        check?.invalidate()
        checkID += 1
        if let item = Self.menuItem(starting: false) {
            AXUIElementPerformAction(item, kAXPressAction as CFString)
            Log.write("mac-dictation: stopped")
        }
    }

    private func getOutOfTheWay() {
        if reader.isActive { reader.stop() }
        reader.ducker.stopNow()
    }

    // MARK: Watching every dictation start

    /// Listens (without changing anything) for the keys that start dictation,
    /// so a deaf start is fixed whichever key you used. Needs Accessibility.
    func watchKeys() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue) | (1 << 14)  // 14 = system-defined
        let me = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                eventsOfInterest: CGEventMask(mask), callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let this = Unmanaged<MacDictation>.fromOpaque(refcon).takeUnretainedValue()
            var code = event.getIntegerValueField(.keyboardEventKeycode)
            if type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 {
                code = Int64((ns.data1 & 0xFFFF0000) >> 16)  // NX key type of a special key
            } else if type.rawValue == 14 {
                return Unmanaged.passUnretained(event)
            }
            let flags = event.flags
            // Never work inside the key path: keystrokes must not wait on us.
            DispatchQueue.main.async { MainActor.assumeIsolated { this.saw(type: type, keyCode: code, flags: flags) } }
            return Unmanaged.passUnretained(event)
        }, userInfo: me)
        guard let tap else { Log.write("mac-dictation: can't watch keys (no permission)"); return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func saw(type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            // Control pressed on its own, twice in a row.
            guard keyCode == 59 || keyCode == 62, flags.contains(.maskControl),
                  flags.intersection([.maskCommand, .maskAlternate, .maskShift]).isEmpty else { return }
            let now = Date()
            if now.timeIntervalSince(lastControl) < 0.5 { dictationKey("Control twice", sure: false) }
            lastControl = now
        case .keyDown:
            lastControl = .distantPast
            if keyCode == 176 { dictationKey("🎤 key", sure: true) }  // the dictation key on Apple keyboards
        default:
            // System-defined events: the 🎤 key on some keyboards, media keys.
            // Volume, brightness and play keys are known; anything else may be 🎤.
            if type.rawValue == 14, ![0, 1, 2, 3, 7, 16, 17, 18, 19, 20, 21, 22, 23].contains(keyCode) {
                dictationKey("special key \(keyCode)", sure: false)
            }
        }
    }

    /// A key that toggles dictation. macOS sometimes ignores a press — to
    /// start or to stop — so nothing is assumed: the state before the press
    /// is known, the real state is checked a moment later, and an ignored
    /// press is completed (stopped or started). Another press while checking
    /// simply flips what's expected, so it never fights you.
    private func dictationKey(_ which: String, sure: Bool) {
        // Tracked state only: by now macOS may already have acted on the press.
        let before = expected ?? isOn
        guard sure else {
            // Control twice / other keys: only notice if dictation came on.
            if !before { observe() }
            return
        }
        let want = !before
        expected = want
        Log.write("mac-dictation: \(which) pressed in \(Self.frontName) — \(want ? "turning on" : "turning off")")
        if want { getOutOfTheWay() }
        verify(want, since: Date(), step: 0)
    }

    private let probeQueue = DispatchQueue(label: "earshot.dictation", qos: .userInitiated)
    private var probing = false

    /// Reads dictation's state (mic, menu) off the main thread, so a busy app
    /// can never freeze Earshot, then hands it back here.
    private func probe(_ done: @escaping @MainActor (_ hearing: Bool, _ menuOn: Bool) -> Void) {
        guard !probing else { return }
        probing = true
        probeQueue.async {
            let hearing = Self.dictationHearing()
            let menuOn = Self.menuItem(starting: false) != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.probing = false
                    done(hearing, menuOn)
                }
            }
        }
    }

    /// The press's expected result while it's being checked.
    private var expected: Bool?

    /// On means the dictation menu says so or its microphone is open.
    nonisolated private static func dictationOn() -> Bool { dictationHearing() || menuItem(starting: false) != nil }

    /// Checks the press did what was expected, and finishes it if it didn't.
    /// Turning on: waits for the microphone (a cold start takes ~1–2 s); if
    /// nothing came on by 1.3 s it starts dictation; if it's on but the mic
    /// stays closed, turns it off and on. Turning off: if it's still on after
    /// 1 s, stops it.
    private func verify(_ want: Bool, since started: Date, step: Int) {
        check?.invalidate()
        checkID += 1
        let id = checkID
        var seenOn = false
        check = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, id == self.checkID else { t.invalidate(); return }
                self.probe { hearing, menuOn in
                    guard id == self.checkID, t.isValid else { return }
                    let elapsed = Date().timeIntervalSince(started)
                    if want {
                        if hearing {
                            t.invalidate()
                            self.expected = nil
                            Log.write("mac-dictation: listening after \(Int(elapsed * 1000)) ms\(step > 0 ? " (fixed)" : "")")
                            self.follow()
                        } else if menuOn {
                            seenOn = true
                            if elapsed > (step == 0 ? 1.6 : 2.5) {
                                t.invalidate()
                                self.recover(step: step)
                            }
                        } else if elapsed > 1.3 {
                            t.invalidate()
                            guard step == 0, !seenOn, let item = Self.menuItem(starting: true) else {
                                self.expected = nil
                                self.isOn = false
                                Log.write("mac-dictation: didn't come on")
                                return
                            }
                            Log.write("mac-dictation: the press was ignored — starting dictation")
                            AXUIElementPerformAction(item, kAXPressAction as CFString)
                            self.verify(true, since: Date(), step: 1)
                        }
                    } else {
                        if !hearing && !menuOn {
                            t.invalidate()
                            self.expected = nil
                            self.isOn = false
                            Log.write("mac-dictation: off")
                        } else if elapsed > 1.0 {
                            t.invalidate()
                            self.expected = nil
                            if let item = Self.menuItem(starting: false) {
                                Log.write("mac-dictation: the press was ignored — stopping dictation")
                                AXUIElementPerformAction(item, kAXPressAction as CFString)
                            }
                            self.isOn = false
                        }
                    }
                }
            }
        }
    }

    /// Dictation started by something else (Control twice): keep track of it.
    private func observe() {
        check?.invalidate()
        checkID += 1
        let id = checkID
        let started = Date()
        check = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, id == self.checkID else { t.invalidate(); return }
                self.probe { hearing, menuOn in
                    guard id == self.checkID, t.isValid else { return }
                    if hearing || menuOn { t.invalidate(); self.follow() }
                    else if Date().timeIntervalSince(started) > 2 { t.invalidate() }
                }
            }
        }
    }

    /// While dictation is on, checks twice a second that it still is, so the
    /// next press is known to be a stop.
    private func follow() {
        isOn = true
        let id = checkID
        check = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, id == self.checkID else { t.invalidate(); return }
                self.probe { hearing, menuOn in
                    guard id == self.checkID, !hearing, !menuOn else { return }
                    t.invalidate()
                    self.isOn = false
                }
            }
        }
    }

    private func recover(step: Int) {
        guard step < 2 else {
            Log.write("mac-dictation: still not listening, giving up")
            reader.flash("Dictation isn't hearing you — press the 🎤 key again")
            return
        }
        Log.write("mac-dictation: on but not listening — \(step == 0 ? "turning it off and on" : "restarting the dictation helper")")
        reader.flash("Dictation stuck — restarting it")
        if let item = Self.menuItem(starting: false) { AXUIElementPerformAction(item, kAXPressAction as CFString) }
        if step == 1 {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.inputmethod.ironwood").forEach { $0.forceTerminate() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (step == 0 ? 0.35 : 0.8)) { [weak self] in
            guard let self, let item = Self.menuItem(starting: true) else { return }
            AXUIElementPerformAction(item, kAXPressAction as CFString)
            self.verify(true, since: Date(), step: step + 1)
        }
    }

    // MARK: Helpers

    nonisolated private static var frontName: String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "?" }

    /// The front app's "Start Dictation" (or, while dictating, "Stop Dictation") menu item.
    nonisolated static func menuItem(starting: Bool) -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)  // a busy app must not hold us up
        guard let bar = element(root, kAXMenuBarAttribute) else { return nil }
        let wanted = starting ? "start dictation" : "stop dictation"
        for top in children(bar) {
            for menu in children(top) {
                for item in children(menu) {
                    var t: CFTypeRef?
                    AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &t)
                    if (t as? String)?.lowercased().hasPrefix(wanted) == true { return item }
                }
            }
        }
        return nil
    }

    /// True once the speech service has the microphone open.
    nonisolated static func dictationHearing() -> Bool {
        listeningApps().contains("com.apple.CoreSpeech")
    }

    /// Bundle ids of other processes with a microphone open.
    nonisolated static func listeningApps() -> [String] {
        let me = ProcessInfo.processInfo.processIdentifier
        return CoreAudioQuery.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
            .compactMap { obj -> String? in
                let input: UInt32 = CoreAudioQuery.get(obj, kAudioProcessPropertyIsRunningInput, 0) ?? 0
                let pid: pid_t = CoreAudioQuery.get(obj, kAudioProcessPropertyPID, pid_t(0)) ?? 0
                guard input != 0, pid != me else { return nil }
                return CoreAudioQuery.string(obj, kAudioProcessPropertyBundleID) ?? "pid \(pid)"
            }
    }

    nonisolated private static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    nonisolated private static func children(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v)
        return v as? [AXUIElement] ?? []
    }
}
