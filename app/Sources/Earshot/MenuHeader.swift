import SwiftUI

/// The card at the top of the menu-bar popup: status, what's being read,
/// playback controls and quick speed — live while the menu is open.
struct MenuHeader: View {
    @ObservedObject var reader: Reader
    @ObservedObject var kokoro: KokoroEngine
    @ObservedObject var settings: Settings
    let output: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if reader.speedMode != .normal {
                    Text(reader.speedMode == .boost ? "⚡ boost" : "🐢 slow")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(subtitle)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
            if reader.isActive, reader.total > 0 {
                ProgressView(value: Double(reader.position), total: Double(max(reader.total, 1)))
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }
            HStack(spacing: 14) {
                control("backward.fill", enabled: reader.isActive) { reader.skip(-1) }
                control(reader.state == .paused ? "play.fill" : "pause.fill", enabled: reader.isActive) { reader.togglePause() }
                control("stop.fill", enabled: reader.isActive) { reader.stop() }
                control("forward.fill", enabled: reader.isActive) { reader.skip(1) }
                Spacer()
                control(reader.speedMode == .slow ? "tortoise.fill" : "tortoise", enabled: true) {
                    reader.setSpeedMode(reader.speedMode == .slow ? .normal : .slow, quiet: true)
                }
                control(reader.speedMode == .boost ? "hare.fill" : "hare", enabled: true) {
                    reader.setSpeedMode(reader.speedMode == .boost ? .normal : .boost, quiet: true)
                }
            }
            HStack(spacing: 6) {
                Text("Speed").font(.caption).foregroundStyle(.secondary)
                ForEach([1.5, 2.0, 2.5, 3.0], id: \.self) { s in
                    chip(String(format: "%.3g×", s), on: abs(settings.speed - s) < 0.01) { settings.speed = s }
                }
                Spacer()
                Text(String(format: "%.2g×", settings.speed))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 300, alignment: .leading)
    }

    private var dotColor: Color {
        if reader.isActive { return .blue }
        switch kokoro.status {
        case .ready: return .green
        case .starting: return .orange
        case .asleep: return .gray
        case .notInstalled: return .orange
        case .failed: return .red
        }
    }

    private var title: String {
        if reader.isActive { return reader.state == .paused ? "Paused" : "Reading" }
        switch kokoro.status {
        case .ready: return "Ready"
        case .starting: return "Voice starting…"
        case .asleep: return "Ready (voice asleep)"
        case .notInstalled: return "Apple voice"
        case .failed: return "Voice failed — see Settings"
        }
    }

    private var subtitle: String {
        if reader.isActive, reader.total > 0 {
            return "Sentence \(min(reader.position + 1, reader.total)) of \(reader.total)"
        }
        return output.map { "Output: \($0)" } ?? "No allowed output — check Settings"
    }

    private func control(_ symbol: String, enabled: Bool, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.4))
        .disabled(!enabled)
    }

    private func chip(_ label: String, on: Bool, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(label)
                .font(.caption.weight(on ? .bold : .regular)).monospacedDigit()
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(on ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
