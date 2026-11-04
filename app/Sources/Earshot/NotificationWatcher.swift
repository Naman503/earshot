import AppKit
import ApplicationServices
import EarshotCore

/// Watches Notification Center's on-screen banners through Accessibility and
/// reports each new one once. (The notification database is locked on macOS 26,
/// and banners are what you'd see anyway.)
@MainActor
final class NotificationWatcher {
    var onBanner: ((BannerNote) -> Void)?

    private static let bundleID = "com.apple.notificationcenterui"
    private var observer: AXObserver?
    private var pid: pid_t = 0
    private var seen: [String] = []
    private var seenSet = Set<String>()
    private var timer: Timer?
    private var scanScheduled = false

    func start() {
        attach()
        // Fallback polling in case an AX event is missed; a scan is a small tree walk.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
        // Notification Center restarts occasionally; re-attach when it does.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Self.bundleID else { return }
            MainActor.assumeIsolated { self?.attach() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        detach()
    }

    private func attach() {
        detach()
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            Log.write("notifications: Notification Center not running")
            return
        }
        pid = app.processIdentifier
        // Banners already on screen (or in the open panel) are old news.
        for b in Self.banners(pid: pid) { markSeen(b.id) }

        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<NotificationWatcher>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.scheduleScan() }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        let root = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXCreatedNotification, kAXLayoutChangedNotification, kAXValueChangedNotification] {
            AXObserverAddNotification(obs, root, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        Log.write("notifications: watching Notification Center (pid \(pid))")
    }

    private func detach() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
    }

    /// AX events arrive before the banner's text is filled in; wait a moment.
    private func scheduleScan() {
        guard !scanScheduled else { return }
        scanScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.scanScheduled = false
            self?.scan()
        }
    }

    /// Reads the banners off the main thread (a slow Notification Center
    /// used to freeze reading), then reports new ones here.
    private func scan() {
        guard pid > 0, !scanning, AXIsProcessTrusted() else { return }
        scanning = true
        let pid = self.pid
        queue.async {
            let found = Self.banners(pid: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.scanning = false
                    self.report(found)
                }
            }
        }
    }

    private let queue = DispatchQueue(label: "earshot.notifications", qos: .utility)
    private var scanning = false

    private func report(_ found: [BannerNote]) {
        let fresh = found.filter { !seenSet.contains($0.id) }
        guard !fresh.isEmpty else { return }
        fresh.forEach { markSeen($0.id) }
        // Many at once means the user opened the Notification Center panel.
        guard fresh.count <= 3 else {
            Log.write("notifications: \(fresh.count) appeared at once (panel opened?), not announcing")
            return
        }
        for b in fresh {
            Log.write("notifications: new from \(b.app)")
            onBanner?(b)
        }
    }

    private func markSeen(_ id: String) {
        guard seenSet.insert(id).inserted else { return }
        seen.append(id)
        if seen.count > 500 { seenSet.remove(seen.removeFirst()) }
    }

    /// Every banner element in Notification Center's dialog windows.
    nonisolated private static func banners(pid: pid_t) -> [BannerNote] {
        let root = AXUIElementCreateApplication(pid)
        // A busy Notification Center must never hold us up for long.
        AXUIElementSetMessagingTimeout(root, 0.5)
        var out: [BannerNote] = []
        for window in children(root) where string(window, kAXSubroleAttribute) == "AXSystemDialog" {
            collect(window, depth: 0, into: &out)
        }
        return out
    }

    nonisolated private static func collect(_ el: AXUIElement, depth: Int, into out: inout [BannerNote]) {
        guard depth < 12 else { return }
        let subrole = string(el, kAXSubroleAttribute) ?? ""
        if subrole.hasPrefix("AXNotificationCenterBanner") || subrole == "AXNotificationCenterAlert",
           let note = parse(el) {
            out.append(note)
        }
        for c in children(el) { collect(c, depth: depth + 1, into: &out) }
    }

    nonisolated private static func parse(_ el: AXUIElement) -> BannerNote? {
        var fields: [String: String] = [:]
        for c in children(el) {
            if let id = string(c, kAXIdentifierAttribute), let v = string(c, kAXValueAttribute) { fields[id] = v }
        }
        let desc = string(el, kAXDescriptionAttribute) ?? ""
        let title = fields["title"] ?? ""
        let body = fields["body"] ?? ""
        guard !(title.isEmpty && body.isEmpty) else { return nil }
        let id = string(el, kAXIdentifierAttribute) ?? "\(desc.hashValue)"
        return BannerNote(id: id, app: BannerNote.appName(description: desc, title: title),
                          title: title, subtitle: fields["subtitle"] ?? "", body: body)
    }

    nonisolated private static func children(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v)
        return v as? [AXUIElement] ?? []
    }

    nonisolated private static func string(_ el: AXUIElement, _ name: String) -> String? {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, name as CFString, &v)
        return v as? String
    }
}
