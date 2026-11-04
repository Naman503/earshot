import AppKit
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: HUDView(reader: reader, settings: settings))
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
        findNext()
    }

    private func findNext() {
        guard !busy, let (word, next, locator) = pending else { return }
        pending = nil
        busy = true
        finder.async {
            let box = locator.locate(word, next: next)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = false
                    if let box { self.place(box) } else { self.missed() }
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

    private func hideWord() {
        pending = nil
        missedSince = nil
        marker.hide()
    }

    private func place(_ rect: CGRect) {
        missedSince = nil
        marker.show(rect)
    }

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
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
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
            CATransaction.setAnimationDuration(0.12)
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
        underline.frame = CGRect(x: r.minX + 2, y: r.minY - 1, width: r.width - 4, height: 2.5)
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
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let v = NSView()
            v.wantsLayer = true
            let accent = NSColor.controlAccentColor
            fill.backgroundColor = accent.withAlphaComponent(0.20).cgColor
            fill.opacity = 0
            underline.backgroundColor = accent.withAlphaComponent(0.95).cgColor
            underline.cornerRadius = 1.25
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
