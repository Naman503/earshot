import AppKit
import EarshotCore
import ScreenCaptureKit
import SwiftUI

/// A small floating "now reading" bar at the bottom of the screen, plus a
/// brief outline around the text that was picked up.
@MainActor
final class HUD {
    private let panel: NSPanel
    private let reader: Reader
    private let settings: Settings
    private var highlight: NSWindow?
    private let marker = WordMarker()
    private let finder = DispatchQueue(label: "earshot.words", qos: .userInteractive)
    private var busy = false
    private var pending: (String, String, WordLocator)?
    private var missedSince: Date?

    private var scrollMonitor: Any?

    /// Earshot's overlays (bar, word marker, outline) show over whatever app
    /// you're in: on every desktop, over full-screen apps, and with Stage
    /// Manager, which otherwise hides them because they aren't the front app's.
    nonisolated(unsafe) static var overlayBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .canJoinAllApplications, .auxiliary]

    init(reader: Reader, settings: Settings) {
        self.reader = reader
        self.settings = settings
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 64),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = HUD.overlayBehavior
        panel.contentView = NSHostingView(rootView: HUDView(reader: reader, settings: settings))
        // While you scroll or drag a window, the marker stays on the word that
        // was being read and moves with the page, so you can scroll back to it;
        // reading carries on, and the marker catches up when you stop.
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .leftMouseDragged]) { [weak self] e in
            MainActor.assumeIsolated { self?.pageMoved(e) }
        }
        // Paging with the keyboard (Page Up/Down, arrows, Space, Home/End) is you
        // moving the page too: auto-scroll waits.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard [116, 121, 125, 126, 115, 119, 49].contains(Int(e.keyCode)) else { return }
            MainActor.assumeIsolated { self?.lastUserScroll = Date() }
        }
        // Switching apps or desktops: hide the marker unless the app being read
        // is the one in front; coming back, the next word shows it again.
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.marker.hide()
                    if self.sourceInFront { self.findNext() }
                }
            }
        }
    }

    /// Shows the bar while reading or while a notice is up.
    func update() {
        let visible = settings.showHUD && reader.isActive || reader.notice != nil
        if visible {
            if !panel.isVisible { place() }
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 24))
    }

    // MARK: Follow-along word highlight

    /// Moves the marker to `word` on the page. Lookups run one at a time off
    /// the main thread; if the page is slow, words in between are skipped.
    func showWord(_ word: String?, next: String, locator: WordLocator?) {
        guard let word, let locator, settings.highlightWords else {
            if word == nil || locator == nil { hideWord() }
            return
        }
        pending = (word, next, locator)
        lastLocator = locator
        if scrollEnd == nil { findNext() }
    }

    private var lastLocator: WordLocator?
    /// Pending "you stopped scrolling" moment; non-nil while scrolling.
    private var scrollEnd: DispatchWorkItem?
    private var lastFollow = Date.distantPast

    private let scroller = SmoothScroller()

    /// Teleprompter-style following: keep the spoken line at a set height in
    /// the window. When the voice moves to a lower line, the page glides up by
    /// the difference (a line at a time while reading); when the word is above
    /// the window, it glides down to it.
    private func follow(_ box: CGRect, in view: CGRect) {
        let target = view.minY + view.height * settings.autoScrollAnchor
        let dy = box.midY - target
        let below = dy > box.height * 0.8
        let above = box.minY < view.minY + 4
        guard below || above, !scroller.isBusy || abs(dy) > view.height * 0.5 else { return }
        lastAutoScroll = Date()
        stats.scrolled += 1
        let duration = min(0.6, 0.22 + abs(dy) / 3000)
        // Aim the scroll at a point inside the window even when the word is off-screen.
        let at = CGPoint(x: min(max(box.midX, view.minX + 20), view.maxX - 20), y: view.midY)
        scroller.scroll(by: dy, at: at, duration: duration) { [weak self] step in
            self?.marker.shift(by: step)  // the highlight rides along with the text
        }
    }

    /// When you last scrolled or paged yourself (auto-scroll waits after it).
    private var lastUserScroll = Date.distantPast
    private var lastAutoScroll = Date.distantPast
    private var keyMonitor: Any?

    private func pageMoved(_ e: NSEvent) {
        // Earshot's own smooth scrolling isn't you taking over.
        if e.cgEvent?.getIntegerValueField(.eventSourceUserData) == SmoothScroller.tag { return }
        lastUserScroll = Date()
        scrollEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scrollEnd = nil
            self.findNext()  // back to the word being spoken now
        }
        scrollEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: end)
        // Keep the marker on the last word read as the page moves (~30 times a second).
        guard !busy, Date().timeIntervalSince(lastFollow) > 0.033, let locator = lastLocator else { return }
        lastFollow = Date()
        busy = true
        finder.async {
            let box = locator.remeasure()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = false
                    if let box, self.sourceInFront { self.marker.show(box) }
                    if self.scrollEnd == nil { self.findNext() }
                }
            }
        }
    }

    private func findNext() {
        guard !busy, scrollEnd == nil, let (word, next, locator) = pending else { return }
        pending = nil
        busy = true
        // Follow the reading by scrolling — unless you're scrolling (or paged)
        // yourself recently, the app isn't in front, or it scrolled just now.
        let userRecently = Date().timeIntervalSince(lastUserScroll) <= settings.autoScrollPause
        if settings.autoScroll, userRecently { stats.waitedForYou += 1 }
        let mayScroll = settings.autoScroll && settings.highlightWords && sourceInFront && !userRecently

        finder.async {
            let box = locator.locate(word, next: next)
            let view = box != nil && mayScroll ? locator.visibleArea() : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = false
                    if let box {
                        self.place(box)
                        if let view { self.follow(box, in: view) }
                    } else { self.stats.missed += 1; self.missed() }
                    self.findNext()
                }
            }
        }
    }

    private func missed() {
        // Keep the last spot briefly so one unmatched word doesn't blink.
        if missedSince == nil { missedSince = Date() }
        if let t = missedSince, Date().timeIntervalSince(t) > 0.8 { marker.hide() }
    }

    /// Per reading, for the log: words placed, not found, hidden (app not in front).
    private var stats = (placed: 0, missed: 0, hidden: 0, scrolled: 0, waitedForYou: 0)

    private func hideWord() {
        if stats.placed + stats.missed + stats.hidden + stats.scrolled > 0 {
            Log.write("highlight: \(stats.placed) words shown, \(stats.missed) not found, \(stats.hidden) hidden (other app in front), \(stats.scrolled) auto-scrolls (\(stats.waitedForYou) words while you were scrolling)")
            if let v = lastLocator?.debugView { Log.write("highlight: \(v)") }
            stats = (0, 0, 0, 0, 0)
        }
        pending = nil
        lastLocator = nil
        missedSince = nil
        marker.hide()
    }

    /// Only over the app being read: not on top of whatever you switched to.
    private var sourceInFront: Bool {
        guard let pid = lastLocator?.pid, pid > 0 else { return true }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private func place(_ rect: CGRect) {
        missedSince = nil
        guard sourceInFront else { stats.hidden += 1; marker.hide(); return }
        stats.placed += 1
        marker.tint(for: reader.speedMode, normal: settings.highlightColor.color, style: settings.highlightStyle)
        marker.show(rect)
        captureIfAsked(rect)
    }

    /// Diagnostics: if ~/Library/Logs/Earshot/capture-next exists, the next
    /// placed word is photographed (with the marker) and the flag removed.
    private func captureIfAsked(_ rect: CGRect) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Earshot")
        let flag = dir.appendingPathComponent("capture-next")
        guard FileManager.default.fileExists(atPath: flag.path) else { return }
        try? FileManager.default.removeItem(at: flag)
        let state = marker.debugState
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Task {
                Log.write("capture: word at \(rect), marker \(state), front \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
                guard let content = try? await SCShareableContent.current, let d = content.displays.first else { Log.write("capture: no display"); return }
                let config = SCStreamConfiguration()
                config.sourceRect = rect.insetBy(dx: -220, dy: -120)
                config.width = Int(config.sourceRect.width * 2)
                config.height = Int(config.sourceRect.height * 2)
                guard let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: config) else {
                    Log.write("capture: screenshot failed"); return
                }
                let url = dir.appendingPathComponent("capture.png")
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: url)
                Log.write("capture: saved \(url.path)")
            }
        }
    }

    /// Debug: shows the word marker over `rect` (to check it's visible).
    func testMarker(_ rect: CGRect) { marker.show(rect) }

    /// Debug: shows the marker with a given look (not saved) and photographs it.
    func testMarkerLook(style: HighlightStyle, color: HighlightColor, rect: CGRect, file: URL) {
        marker.show(rect)
        marker.tint(for: .normal, normal: color.color, style: style)
        marker.show(rect)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Task {
                guard let content = try? await SCShareableContent.current, let d = content.displays.first else { return }
                let config = SCStreamConfiguration()
                config.sourceRect = rect.insetBy(dx: -40, dy: -14)
                config.width = Int(config.sourceRect.width * 2)
                config.height = Int(config.sourceRect.height * 2)
                if let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: config) {
                    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: file)
                }
                Log.write("marker-look: \(style) \(color) — \(self.marker.debugState)")
                self.marker.hide()
            }
        }
    }
    func testMarkerHide() { marker.hide() }

    /// Outlines `rect` (top-left screen coordinates) for a moment.
    func flash(rect: CGRect) {
        guard settings.highlightSource, rect.width > 4, rect.height > 4 else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let frame = NSRect(x: rect.minX - 4, y: primaryHeight - rect.maxY - 4, width: rect.width + 8, height: rect.height + 8)
        let w = highlight ?? {
            let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.level = .statusBar
            w.collectionBehavior = HUD.overlayBehavior
            let v = NSView()
            v.wantsLayer = true
            v.layer?.borderWidth = 2.5
            v.layer?.cornerRadius = 6
            v.layer?.borderColor = NSColor.controlAccentColor.cgColor
            v.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
            w.contentView = v
            highlight = w
            return w
        }()
        w.setFrame(frame, display: true)
        w.alphaValue = 1
        w.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; w.animator().alphaValue = 0 }) { w.orderOut(nil) }
        }
    }
}

private struct HUDView: View {
    @ObservedObject var reader: Reader
    @ObservedObject var settings: Settings

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 22)
                .symbolEffect(.variableColor.iterative, isActive: reader.state == .speaking)
            VStack(alignment: .leading, spacing: 2) {
                Text(reader.notice.map { AttributedString($0) } ?? spokenText)
                    .font(.system(size: 13, weight: reader.notice == nil ? .regular : .medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if reader.notice == nil, reader.total > 0 {
                    Text("\(reader.position) of \(reader.total) · \(String(format: "%.2g", reader.speed))×\(reader.speedMode == .boost ? " ⚡" : reader.speedMode == .slow ? " 🐢" : "")")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            if reader.isActive {
                HStack(spacing: 4) {
                    button("backward.fill") { reader.skip(-1) }
                    button(reader.state == .paused ? "play.fill" : "pause.fill") { reader.togglePause() }
                    button("forward.fill") { reader.skip(1) }
                    button("xmark") { reader.stop() }
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 520, height: 64)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// The sentence with the spoken word lit up. Long sentences are shown
    /// from a little before the word so it's always in view.
    private var spokenText: AttributedString {
        let text = reader.currentText as NSString
        guard settings.highlightWordsInBar, let r = reader.spokenRange, NSMaxRange(r) <= text.length else {
            return AttributedString(reader.currentText)
        }
        var start = 0
        if text.length > 110, r.location > 50 {
            start = min(r.location - 40, max(0, text.length - 110))
            let space = text.range(of: " ", range: NSRange(location: start, length: r.location - start))
            if space.location != NSNotFound { start = space.location + 1 }
        }
        let prefix = start > 0 ? "…" : ""
        var out = AttributedString(prefix + text.substring(with: NSRange(location: start, length: r.location - start)))
        var word = AttributedString(text.substring(with: r))
        word.backgroundColor = Color.yellow.opacity(0.45)
        word.font = .system(size: 13, weight: .semibold)
        out += word
        out += AttributedString(text.substring(from: NSMaxRange(r)))
        return out
    }

    private var icon: String {
        if reader.notice != nil && !reader.isActive { return "headphones" }
        switch reader.state {
        case .preparing: return "ellipsis"
        case .paused: return "pause.circle"
        default: return "waveform"
        }
    }

    private func button(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26)
        }
        .buttonStyle(.borderless)
    }
}

/// The follow-along marker: a soft highlight with an accent underline that
/// glides from word to word. It lives in one transparent, click-through
/// window over the screen and moves as a Core Animation layer, so each step
/// is a GPU transform rather than a window move.
@MainActor
final class WordMarker {
    private var window: NSWindow?
    private let fill = CALayer()
    private let underline = CALayer()
    private var visible = false
    private var lastRect: CGRect?

    func show(_ rect: CGRect) {
        // Accessibility rects are top-left based; skip off-screen or odd ones.
        guard rect.width > 1, rect.height > 4, rect.height < 120,
              let screen = NSScreen.screens.first(where: { topLeftFrame($0).intersects(rect) }) else { hide(); return }
        let w = window(for: screen)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let pad: CGFloat = 3
        let local = CGRect(x: rect.minX - screen.frame.minX - pad,
                           y: primaryHeight - rect.maxY - screen.frame.minY - 1,
                           width: rect.width + pad * 2, height: rect.height + 2)
        let sameLine = visible && lastRect.map { abs($0.midY - rect.midY) < rect.height * 0.5 } == true
        CATransaction.begin()
        if sameLine {
            CATransaction.setAnimationDuration(0.07)  // quick, so it never looks smeared between words
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)  // new line: jump, then fade in
        }
        layout(local)
        CATransaction.commit()
        if !visible {
            w.orderFrontRegardless()
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            fill.opacity = 1
            underline.opacity = 1
            CATransaction.commit()
            visible = true
        } else if !sameLine {
            fadeIn()
        }
        lastRect = rect
    }

    /// Accent colour at normal speed, orange while fast, teal while slow.
    /// Bold enough to follow at a glance on dark and light pages (the old 22%
    /// accent tint all but vanished on dark backgrounds): a strong fill, a
    /// solid underline and a thin border. Normal speed uses the chosen colour,
    /// fast is orange, slow is teal.
    func tint(for mode: Reader.SpeedMode, normal: NSColor = .systemYellow, style: HighlightStyle = .bold) {
        let color: NSColor = switch mode {
        case .normal: normal
        case .boost: .systemOrange
        case .slow: .systemTeal
        }
        guard color != tintColor || style != tintStyle else { return }
        tintColor = color
        tintStyle = style
        let bold = style == .bold
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        // Soft is the original look: a light tint and a thin underline.
        fill.backgroundColor = color.withAlphaComponent(bold ? 0.42 : 0.22).cgColor
        fill.borderColor = color.withAlphaComponent(0.95).cgColor
        fill.borderWidth = bold ? 1.5 : 0
        underline.backgroundColor = color.withAlphaComponent(bold ? 1 : 0.95).cgColor
        underlineHeight = bold ? 3 : 2.5
        CATransaction.commit()
    }
    private var tintStyle: HighlightStyle?
    private var underlineHeight: CGFloat = 3
    private var tintColor: NSColor?

    /// Moves the marker up by `dy` points (as the page scrolls under it).
    func shift(by dy: CGFloat) {
        guard visible else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame.origin.y += dy
        underline.frame.origin.y += dy
        CATransaction.commit()
        lastRect = lastRect?.offsetBy(dx: 0, dy: -dy)
    }

    /// Debug: what the marker window is doing.
    var debugState: String {
        guard let w = window else { return "no window yet" }
        return "window visible \(w.isVisible), on active space \(w.isOnActiveSpace), frame \(w.frame), level \(w.level.rawValue), layer frame \(fill.frame), opacity \(fill.opacity)"
    }

    func hide() {
        guard visible else { return }
        visible = false
        lastRect = nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { if self?.visible == false { self?.window?.orderOut(nil) } }
        }
        fill.opacity = 0
        underline.opacity = 0
        CATransaction.commit()
    }

    private func layout(_ r: CGRect) {
        fill.frame = r
        fill.cornerRadius = min(6, r.height * 0.3)
        underline.frame = CGRect(x: r.minX + 1, y: r.minY - 2, width: r.width - 2, height: underlineHeight)
    }

    private func fadeIn() {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0.2
        a.toValue = 1
        a.duration = 0.12
        fill.add(a, forKey: "fade")
        underline.add(a, forKey: "fade")
    }

    private func window(for screen: NSScreen) -> NSWindow {
        if let w = window, w.frame == screen.frame { return w }
        let w = window ?? {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: true)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.level = .floating
            w.isReleasedWhenClosed = false
            w.collectionBehavior = HUD.overlayBehavior
            let v = NSView()
            v.wantsLayer = true
            // Colours come from tint(for:) only — setting a default here used to
            // overwrite the chosen colour the first time the window was made.
            fill.opacity = 0
            underline.cornerRadius = 1.5
            underline.opacity = 0
            v.layer?.addSublayer(fill)
            v.layer?.addSublayer(underline)
            w.contentView = v
            window = w
            return w
        }()
        w.setFrame(screen.frame, display: false)
        return w
    }

    private func topLeftFrame(_ s: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: s.frame.minX, y: primaryHeight - s.frame.maxY, width: s.frame.width, height: s.frame.height)
    }
}

/// Scrolls the app under a point smoothly, like a trackpad: many small pixel
/// scroll steps over a short time with ease-in-out, tagged so Earshot's own
/// scroll watcher can tell them from yours.
@MainActor
final class SmoothScroller {
    static let tag: Int64 = 0x4541_5253  // "EARS"
    private var timer: Timer?
    private(set) var isBusy = false

    /// `dy` > 0 moves the content up (shows what's below).
    func scroll(by dy: CGFloat, at point: CGPoint, duration: Double, step: @escaping (CGFloat) -> Void) {
        timer?.invalidate()
        let start = Date()
        var sent: CGFloat = 0
        isBusy = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                let p = min(1, Date().timeIntervalSince(start) / duration)
                let eased = p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
                let goal = (dy * eased).rounded()
                let delta = goal - sent
                if delta != 0 {
                    Self.post(-delta, at: point)
                    sent = goal
                    step(delta)
                }
                if p >= 1 { t.invalidate(); self?.isBusy = false }
            }
        }
    }

    private static func post(_ pixels: CGFloat, at point: CGPoint) {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                              wheel1: Int32(pixels), wheel2: 0, wheel3: 0) else { return }
        e.location = point
        e.setIntegerValueField(.eventSourceUserData, value: tag)
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)  // trackpad-style: apps don't add their own animation
        e.post(tap: .cghidEventTap)
    }
}
