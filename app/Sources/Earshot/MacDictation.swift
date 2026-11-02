import AppKit
import ApplicationServices
import CoreAudio

/// Starts the Mac's own dictation from a shortcut (hold to talk, or tap to
/// start and stop) and makes sure it really listens:
///   • presses the front app's Edit ▸ Start Dictation directly, the same as
///     the 🎤 key, with no keyboard-shortcut timing to get wrong;
///   • stops Earshot's reading and audio ducking first, so nothing else is
///     holding the audio hardware while dictation starts;
///   • checks the microphone actually opened within 2.5 s (a cold start
///     takes about 1–2 s, a warm one about 0.5 s), and if not, quits
///     the stuck dictation helper (macOS starts a fresh one) and tries again.
/// Every attempt is logged with how long dictation took to start listening.
@MainActor
final class MacDictation {
    private let reader: Reader
    private var pressedAt = Date.distantPast
    private var listening = false
    private var attempt = 0
    private var watch: Timer?

    init(reader: Reader) {
        self.reader = reader
    }

    func pressed() {
        pressedAt = Date()
        if listening || Self.menuItem(starting: false) != nil {
            stop()
        } else {
            start(retry: false)
        }
    }

    /// A long press is hold-to-talk: letting go finishes.
    func released() {
        if listening, Date().timeIntervalSince(pressedAt) > 0.45 { stop() }
    }

    private func start(retry: Bool) {
        if reader.isActive { reader.stop() }
        reader.ducker.stopNow()
        let before = Set(Self.listeningApps())
        guard let item = Self.menuItem(starting: true) else {
            reader.flash("This app has no dictation menu — use the 🎤 key")
            Log.write("mac-dictation: no Start Dictation menu in \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
            return
        }
        let started = Date()
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        listening = true
        attempt += 1
        let id = attempt
        Log.write("mac-dictation: started in \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")\(retry ? " (retry)" : "")")
        // Watch for the microphone to open.
        watch?.invalidate()
        watch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, id == self.attempt, self.listening else { t.invalidate(); return }
                let now = Set(Self.listeningApps())
                let elapsed = Date().timeIntervalSince(started)
                if !now.subtracting(before).isEmpty {
                    t.invalidate()
                    Log.write("mac-dictation: listening after \(Int(elapsed * 1000)) ms (\(now.sorted().joined(separator: ", ")))")
                } else if elapsed > 2.5 {
                    t.invalidate()
                    Log.write("mac-dictation: microphone didn't open after 2.5 s (input: \(now.sorted().joined(separator: ", ")), stop item: \(Self.menuItem(starting: false) != nil))")
                    if retry {
                        self.listening = false
                        self.reader.flash("Dictation didn't start — try the 🎤 key")
                    } else {
                        self.restartHelper()
                    }
                }
            }
        }
    }

    private func stop() {
        watch?.invalidate()
        listening = false
        if let item = Self.menuItem(starting: false) {
            AXUIElementPerformAction(item, kAXPressAction as CFString)
            Log.write("mac-dictation: stopped")
        }
    }

    /// Quits the stuck dictation helper; macOS starts a new one on the next use.
    private func restartHelper() {
        if let item = Self.menuItem(starting: false) { AXUIElementPerformAction(item, kAXPressAction as CFString) }
        let helpers = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.inputmethod.ironwood")
        Log.write("mac-dictation: restarting \(helpers.compactMap(\.bundleIdentifier).joined(separator: ", "))")
        helpers.forEach { $0.forceTerminate() }
        listening = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.start(retry: true) }
    }

    // MARK: Helpers

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

    /// Bundle ids of Apple processes with a microphone open (dictation, Siri).
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
