import AVFoundation
import EarshotCore
import ServiceManagement
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case voice, output, media, shortcuts, gestures, reading, general
}

struct SettingsView: View {
    @State var initialTab: SettingsTab

    var body: some View {
        TabView(selection: $initialTab) {
            VoiceTab().tabItem { Label("Voice", systemImage: "waveform") }.tag(SettingsTab.voice)
            OutputTab().tabItem { Label("Output", systemImage: "headphones") }.tag(SettingsTab.output)
            MediaTab().tabItem { Label("Media", systemImage: "play.rectangle") }.tag(SettingsTab.media)
            ShortcutsTab().tabItem { Label("Shortcuts", systemImage: "keyboard") }.tag(SettingsTab.shortcuts)
            GesturesTab().tabItem { Label("Gestures", systemImage: "hand.tap") }.tag(SettingsTab.gestures)
            ReadingTab().tabItem { Label("Reading", systemImage: "text.alignleft") }.tag(SettingsTab.reading)
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
        }
        .padding(20)
        .frame(width: 640, height: 520)
    }
}

// MARK: Voice

private struct VoiceTab: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var kokoro: KokoroEngine
    @EnvironmentObject var reader: Reader

    var body: some View {
        Form {
            Picker("Engine", selection: $settings.engine) {
                ForEach(EngineChoice.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            LabeledContent("Status") { Text(statusText).foregroundStyle(.secondary) }

            if settings.engine == .kokoro {
                Picker("Voice", selection: $settings.voice) {
                    ForEach(voiceGroups, id: \.0) { group, voices in
                        Section(group) {
                            ForEach(voices, id: \.self) { Text(Self.displayName($0)).tag($0) }
                        }
                    }
                }
            } else {
                Picker("Voice", selection: $settings.appleVoiceID) {
                    Text("Best available").tag("")
                    ForEach(AppleEngine.englishVoices, id: \.identifier) { v in
                        Text("\(v.name) (\(v.language)\(v.quality == .premium ? ", premium" : v.quality == .enhanced ? ", enhanced" : ""))").tag(v.identifier)
                    }
                }
                Text("Download better Apple voices in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            LabeledContent("Speed") {
                HStack {
                    Slider(value: $settings.speed, in: 0.7...4.0, step: 0.05)
                    Text(String(format: "%.2f×", settings.speed)).monospacedDigit().frame(width: 52)
                }
            }
            LabeledContent("Volume") {
                HStack {
                    Slider(value: $settings.volume, in: 0.2...2.0, step: 0.05)
                    Text("\(Int(settings.volume * 100))%").monospacedDigit().frame(width: 52)
                }
            }
            Text("Above 100% boosts speech louder than the system volume, so it stands out over other sounds.")
                .font(.caption).foregroundStyle(.secondary)

            Button("Play a sample") {
                reader.read("Hi! This is how I sound at \(String(format: "%.2g", settings.speed)) times speed. I'll read anything under your pointer.", source: "sample")
            }
        }
        .formStyle(.grouped)
    }

    private var statusText: String {
        switch kokoro.status {
        case .ready: "Ready (\(kokoro.voices.count) voices)"
        case .starting: "Starting… the Apple voice is used until it's ready"
        case .notInstalled: "Not installed — run scripts/install-engine.sh"
        case .failed(let m): "Failed: \(m)"
        }
    }

    private var voiceGroups: [(String, [String])] {
        let voices = kokoro.voices.isEmpty ? [settings.voice] : kokoro.voices
        let order = [("af", "American · female"), ("am", "American · male"), ("bf", "British · female"), ("bm", "British · male")]
        return order.compactMap { prefix, title in
            let v = voices.filter { $0.hasPrefix(prefix + "_") }
            return v.isEmpty ? nil : (title, v)
        }
    }

    static func displayName(_ id: String) -> String {
        let name = id.split(separator: "_").dropFirst().joined(separator: " ").capitalized
        return id == "af_heart" ? "\(name) (default)" : name
    }
}

// MARK: Output

private struct OutputTab: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var audio: AudioOutput

    var body: some View {
        Form {
            Picker("Speak through", selection: $settings.outputPolicy) {
                ForEach(OutputPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Text("When no allowed device is connected, Earshot stays silent and shows a reminder instead of using the Mac speakers.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Pause when headphones disconnect, resume when they're back", isOn: $settings.pauseOnDisconnect)

            Section("Connected outputs") {
                ForEach(audio.devices) { d in
                    HStack {
                        Image(systemName: d.isHeadphones ? "headphones" : d.isBuiltIn ? "laptopcomputer" : "hifispeaker")
                            .frame(width: 20)
                        VStack(alignment: .leading) {
                            Text(d.name)
                            Text(d.kind + (d.id == audio.defaultDeviceID ? " · system output" : "")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if settings.outputPolicy == .chosenDevices {
                            Toggle("", isOn: Binding(
                                get: { settings.allowedDeviceUIDs.contains(d.uid) },
                                set: { on in
                                    settings.allowedDeviceUIDs.removeAll { $0 == d.uid }
                                    if on { settings.allowedDeviceUIDs.append(d.uid) }
                                }))
                            .labelsHidden()
                        } else {
                            Image(systemName: audio.isAllowed(d, settings: settings) ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundStyle(audio.isAllowed(d, settings: settings) ? .green : .secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { audio.refreshDevices() }
    }
}

// MARK: Media

private struct MediaTab: View {
    @EnvironmentObject var settings: Settings
    @State private var playing: [String] = []

    var body: some View {
        Form {
            Picker("When a video or music is playing", selection: $settings.mediaPolicy) {
                ForEach(MediaPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Text("Earshot presses the system play/pause key, which YouTube in your browser, Spotify, Music and most players follow. It only resumes what it paused.")
                .font(.caption).foregroundStyle(.secondary)
            Section("Playing right now") {
                if playing.isEmpty {
                    Text("Nothing").foregroundStyle(.secondary)
                } else {
                    ForEach(playing, id: \.self) { Text($0) }
                }
                Button("Refresh") { playing = MediaControl.playingApps() }
            }
        }
        .formStyle(.grouped)
        .onAppear { playing = MediaControl.playingApps() }
    }
}

// MARK: Shortcuts

private struct ShortcutsTab: View {
    @EnvironmentObject var settings: Settings
    private let actions: [ReadAction] = ReadAction.allCases.filter { $0 != .none }

    var body: some View {
        Form {
            Section {
                ForEach(actions) { action in
                    LabeledContent(action.title) {
                        ShortcutRecorder(combo: Binding(
                            get: { settings.shortcuts[action] },
                            set: { settings.shortcuts[action] = $0 }))
                    }
                }
            } footer: {
                Text("Click a shortcut, then press the new keys. Delete clears it, Esc cancels.").font(.caption)
            }
            Toggle("Esc stops reading (only while reading)", isOn: $settings.escapeStops)
            Button("Restore defaults") { settings.resetShortcuts() }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Press keys…" : combo.map(HotKeys.describe) ?? "Record") {
            recording ? end() : begin()
        }
        .frame(minWidth: 110)
        .onDisappear { end() }
    }

    private func begin() {
        recording = true
        AppDelegate.shared.hotKeys.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            switch Int(e.keyCode) {
            case 53: end()  // Esc
            case 51, 117: combo = nil; end()  // Delete
            default:
                let mods = HotKeys.carbonModifiers(e.modifierFlags)
                if mods != 0 || (122...135).contains(Int(e.keyCode)) {  // modifiers, or an F-key alone
                    combo = KeyCombo(keyCode: UInt32(e.keyCode), modifiers: mods)
                    end()
                }
            }
            return nil
        }
    }

    private func end() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        AppDelegate.shared.hotKeys.register(Settings.shared.shortcuts)
    }
}

// MARK: Gestures

private struct GesturesTab: View {
    @EnvironmentObject var settings: Settings

    var body: some View {
        Form {
            Toggle("Trackpad gestures", isOn: $settings.gesturesEnabled)
            Section {
                ForEach(TrackpadTap.all, id: \.self) { g in
                    Picker(g.label, selection: Binding(
                        get: { settings.gestures[g] ?? .none },
                        set: { settings.gestures[g] = $0 == .none ? nil : $0 })) {
                        ForEach(ReadAction.allCases) { Text($0.title).tag($0) }
                    }
                }
            } footer: {
                Text("Point at text, then tap. Four-finger taps don't clash with macOS swipes. A three-finger single tap is the system Look Up gesture if you have it turned on, so it's left free by default.")
                    .font(.caption)
            }
            .disabled(!settings.gesturesEnabled)
            Button("Restore defaults") { settings.resetGestures() }
        }
        .formStyle(.grouped)
    }
}

// MARK: Reading

private struct ReadingTab: View {
    @EnvironmentObject var settings: Settings

    var body: some View {
        Form {
            Section("Skip while reading") {
                Toggle("Web addresses (URLs)", isOn: $settings.skipURLs)
                Toggle("Citation marks like [12]", isOn: $settings.skipCitations)
                Toggle("Emoji", isOn: $settings.skipEmoji)
            }
            Section("Feedback") {
                Toggle("Show the now-reading bar", isOn: $settings.showHUD)
                Toggle("Outline the text that was picked up", isOn: $settings.highlightSource)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: General

private struct GeneralTab: View {
    @ObservedObject private var permissions = Permissions.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Permissions") {
                row("Accessibility", "Required: reads text under the pointer and pauses media.", permissions.accessibility) {
                    permissions.requestAccessibility()
                }
                row("Screen Recording", "Optional: reads text in images, PDFs and apps that don't expose it.", permissions.screenRecording) {
                    permissions.requestScreenRecording()
                }
            }
            Toggle("Open at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() } catch {
                        Log.write("login item: \(error.localizedDescription)")
                    }
                }
            LabeledContent("Log") {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Log.url]) }
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.startWatching() }
        .onDisappear { permissions.stopWatching() }
    }

    private func row(_ title: String, _ detail: String, _ granted: Bool, request: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Grant…", action: request)
            }
        }
    }
}
