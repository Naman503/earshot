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
    private var wordBox: NSWindow?
    private let finder = DispatchQueue(label: "earshot.words", qos: .userInteractive)
    private var busy = false
    private var pending: (String, WordLocator)?
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
    func showWord(_ word: String?, locator: WordLocator?) {
        guard let word, let locator, settings.highlightWords, settings.highlightWordsOnPage else {
            if word == nil || locator == nil { hideWord() }
            return
        }
        pending = (word, locator)
        findNext()
    }

    private func findNext() {
        guard !busy, let (word, locator) = pending else { return }
        pending = nil
        busy = true
        finder.async {
            let box = locator.locate(word)
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
        if let t = missedSince, Date().timeIntervalSince(t) > 0.8 { wordBox?.orderOut(nil) }
    }

    private func hideWord() {
        pending = nil
        missedSince = nil
        wordBox?.orderOut(nil)
    }

    private func place(_ rect: CGRect) {
        missedSince = nil
        guard rect.width > 1, rect.height > 4, rect.height < 120,
              NSScreen.screens.contains(where: { screenRect($0).intersects(rect) }) else { wordBox?.orderOut(nil); return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let frame = NSRect(x: rect.minX - 3, y: primaryHeight - rect.maxY - 2, width: rect.width + 6, height: rect.height + 4)
        let w = wordBox ?? {
            let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.level = .statusBar
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            let v = NSView()
            v.wantsLayer = true
            v.layer?.cornerRadius = 4
            v.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.35).cgColor
            v.layer?.borderWidth = 1.5
            v.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.9).cgColor
            w.contentView = v
            wordBox = w
            return w
        }()
        if w.isVisible, abs(w.frame.midY - frame.midY) < frame.height {
            // Same line: glide along it.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.08
                w.animator().setFrame(frame, display: true)
            }
        } else {
            w.setFrame(frame, display: true)
        }
        w.orderFrontRegardless()
    }

    /// A screen's frame in top-left coordinates, like accessibility rects.
    private func screenRect(_ s: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: s.frame.minX, y: primaryHeight - s.frame.maxY, width: s.frame.width, height: s.frame.height)
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
                    Text("\(reader.position) of \(reader.total) · \(String(format: "%.2g", reader.speed))×\(reader.boosted ? " ⚡" : "")")
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
        guard settings.highlightWords, let r = reader.spokenRange, NSMaxRange(r) <= text.length else {
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
