import AppKit
import EarshotCore

/// Speed while a single key is held: one key (fn by default) reads at the
/// boost speed, another (Control) at the slow speed, and letting go returns
/// to normal. Only while something is being read, and only when the key is
/// held on its own for a moment, so shortcuts like ⌃C never change the speed.
/// Listens without blocking any key (needs Accessibility).
@MainActor
final class HoldKeys {
    private let settings: Settings
    private let reader: Reader
    private var tap: CFMachPort?
    /// The held key waiting to count as a hold, or already changing the speed.
    private var pending: DispatchWorkItem?
    private var active: Reader.SpeedMode?

    init(settings: Settings, reader: Reader) {
        self.settings = settings
        self.reader = reader
    }

    func start() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                eventsOfInterest: CGEventMask(mask), callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let this = Unmanaged<HoldKeys>.fromOpaque(refcon).takeUnretainedValue()
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            MainActor.assumeIsolated { this.saw(type: type, keyCode: code, flags: flags) }
            return Unmanaged.passUnretained(event)
        }, userInfo: me)
        guard let tap else { Log.write("hold keys: can't watch keys (no permission)"); return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private static let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift, .maskSecondaryFn]

    private static func flag(of key: HoldKey) -> CGEventFlags {
        switch key {
        case .none: []
        case .fn: .maskSecondaryFn
        case .control: .maskControl
        case .option, .rightOption: .maskAlternate
        case .rightCommand: .maskCommand
        case .shift: .maskShift
        }
    }

    private func saw(type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            release()  // another key joined: it's a shortcut, not a hold
        case .flagsChanged:
            let held = flags.intersection(Self.modifiers)
            for (key, mode) in [(settings.holdFasterKey, Reader.SpeedMode.boost), (settings.holdSlowerKey, .slow)] where key != .none {
                let f = Self.flag(of: key)
                if key.keyCodes.contains(keyCode), held == f {
                    press(mode)  // this key went down, and nothing else is held
                    return
                }
            }
            release()  // the key went up, or another modifier joined
        default:
            break
        }
    }

    private func press(_ mode: Reader.SpeedMode) {
        guard reader.isActive, active == nil else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.reader.isActive else { return }
            self.active = mode
            self.reader.setSpeedMode(mode, quiet: true)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func release() {
        pending?.cancel()
        pending = nil
        guard active != nil else { return }
        active = nil
        reader.setSpeedMode(.normal, quiet: true)
    }
}
