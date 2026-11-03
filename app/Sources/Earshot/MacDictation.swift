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
    /// Last time dictation was seen with the microphone open.
    private var lastHeard = Date.distantPast

    init(reader: Reader) {
        self.reader = reader
    }

    // MARK: ⌃⌥D

    func pressed() {
        pressedAt = Date()
        if Self.menuItem(starting: false) != nil {
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
        watch(since: Date(), step: 0, sure: true)
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
            MainActor.assumeIsolated { this.saw(type: type, keyCode: code, flags: flags) }
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

    /// A key that may have started dictation. `sure`: it's a dictation key
    /// for certain, so if nothing comes on, the press was lost and is redone.
    private func dictationKey(_ which: String, sure: Bool) {
        // Already dictating: this press turns it off. macOS often switches it
        // off before we look, so the microphone still being open (it closes a
        // moment later) or having heard you recently counts as "was on".
        let wasOn = Self.menuItem(starting: false) != nil || Self.dictationHearing()
            || Date().timeIntervalSince(lastHeard) < 1.5
        guard !wasOn else {
            check?.invalidate()
            checkID += 1
            lastHeard = .distantPast
            if sure { Log.write("mac-dictation: \(which) pressed — stopped") }
            return
        }
        if sure { Log.write("mac-dictation: \(which) pressed in \(Self.frontName)") }
        if sure { getOutOfTheWay() }
        watch(since: Date(), step: 0, sure: sure)
    }

    /// Waits for the microphone to open; if it doesn't, step 0 turns dictation
    /// off and on again, step 1 restarts the dictation helper first.
    private func watch(since started: Date, step: Int, sure: Bool) {
        check?.invalidate()
        checkID += 1
        let id = checkID
        let limit = step == 0 ? 1.6 : 2.5
        var seenOn = false
        check = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, id == self.checkID else { t.invalidate(); return }
                let elapsed = Date().timeIntervalSince(started)
                if Self.dictationHearing() {
                    t.invalidate()
                    self.lastHeard = Date()
                    self.followUntilOff()
                    if !sure { self.getOutOfTheWay() }
                    Log.write("mac-dictation: listening after \(Int(elapsed * 1000)) ms\(step > 0 ? " (fixed)" : "")")
                } else if Self.menuItem(starting: false) != nil {
                    if !seenOn, !sure { Log.write("mac-dictation: turned on by \(Self.frontName) key") }
                    seenOn = true
                    if elapsed > limit {
                        t.invalidate()
                        self.recover(step: step)
                    }
                } else if seenOn || elapsed > limit {
                    // You turned it off, or it never came on (its menu shows up ~0.5–1 s in).
                    t.invalidate()
                    guard !seenOn, sure else { return }
                    if step == 0, let item = Self.menuItem(starting: true) {
                        Log.write("mac-dictation: the press didn't register — starting it")
                        self.reader.flash("Starting dictation…")
                        AXUIElementPerformAction(item, kAXPressAction as CFString)
                        self.watch(since: Date(), step: 1, sure: true)
                    } else {
                        Log.write("mac-dictation: didn't turn on")
                    }
                }
            }
        }
    }

    /// While dictation listens, notes every second that it's on, so a stop
    /// press is never mistaken for a lost start. Ends when it switches off.
    private func followUntilOff() {
        let id = checkID
        check = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, id == self.checkID, Self.dictationHearing() else { t.invalidate(); return }
                self.lastHeard = Date()
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
            self.watch(since: Date(), step: step + 1, sure: true)
        }
    }

    // MARK: Helpers

    private static var frontName: String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "?" }

    /// The front app's "Start Dictation" (or, while dictating, "Stop Dictation") menu item.
    static func menuItem(starting: Bool) -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
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
    static func dictationHearing() -> Bool {
        listeningApps().contains("com.apple.CoreSpeech")
    }

    /// Bundle ids of other processes with a microphone open.
    static func listeningApps() -> [String] {
        let me = ProcessInfo.processInfo.processIdentifier
        return CoreAudioQuery.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
            .compactMap { obj -> String? in
                let input: UInt32 = CoreAudioQuery.get(obj, kAudioProcessPropertyIsRunningInput, 0) ?? 0
                let pid: pid_t = CoreAudioQuery.get(obj, kAudioProcessPropertyPID, pid_t(0)) ?? 0
                guard input != 0, pid != me else { return nil }
                return CoreAudioQuery.string(obj, kAudioProcessPropertyBundleID) ?? "pid \(pid)"
            }
    }

    private static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v)
        return v as? [AXUIElement] ?? []
    }
}
