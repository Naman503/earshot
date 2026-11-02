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
                Text(reader.notice ?? reader.currentText)
                    .font(.system(size: 13, weight: reader.notice == nil ? .regular : .medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if reader.notice == nil, reader.total > 0 {
                    Text("\(reader.position) of \(reader.total) · \(String(format: "%.2g", settings.speed))×")
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
