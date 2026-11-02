import AppKit
import Carbon.HIToolbox
import EarshotCore

/// Global shortcuts via Carbon's RegisterEventHotKey, which needs no
/// permission (unlike watching all key presses).
@MainActor
final class HotKeys {
    private var refs: [EventHotKeyRef] = []
    private var escapeRef: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static var actions: [UInt32: ReadAction] = [:]
    private static let escapeID: UInt32 = 999
    static var onAction: ((ReadAction) -> Void)?
    /// Key released (for hold-to-talk dictation).
    static var onRelease: ((ReadAction) -> Void)?

    func register(_ shortcuts: [ReadAction: KeyCombo]) {
        unregisterAll()
        installHandler()
        for (i, (action, combo)) in shortcuts.sorted(by: { $0.key.rawValue < $1.key.rawValue }).enumerated() where action != .none {
            let id = UInt32(i + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                Self.actions[id] = action
            } else {
                Log.write("hotkeys: \(Self.describe(combo)) for \(action.rawValue) is taken (\(status))")
            }
        }
    }

    /// Esc stops reading, but only while something is being read, so Esc
    /// works normally everywhere else.
    func setEscapeActive(_ active: Bool) {
        if active, escapeRef == nil {
            installHandler()
            RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: Self.signature, id: Self.escapeID),
                                GetApplicationEventTarget(), 0, &escapeRef)
            Self.actions[Self.escapeID] = .stop
        } else if !active, let ref = escapeRef {
            UnregisterEventHotKey(ref)
            escapeRef = nil
        }
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        Self.actions = Self.actions.filter { $0.key == Self.escapeID }
    }

    private static let signature = OSType(0x4541_5253)  // "EARS"

    private func installHandler() {
        guard handler == nil else { return }
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let action = HotKeys.actions[id.id] else { return }
                    if released { HotKeys.onRelease?(action) } else { HotKeys.onAction?(action) }
                }
            }
            return noErr
        }, 2, &specs, nil, &handler)
    }

    // MARK: Display

    static func describe(_ combo: KeyCombo) -> String {
        var s = ""
        if combo.modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if combo.modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if combo.modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if combo.modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName(combo.keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Escape: "⎋", kVK_Tab: "⇥", kVK_Delete: "⌫",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let s = special[Int(code)] { return s }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            UCKeyTranslate(raw.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(code), UInt16(kUCKeyActionDisplay),
                           0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        return status == noErr && len > 0 ? String(utf16CodeUnits: chars, count: len).uppercased() : "#\(code)"
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }
}
