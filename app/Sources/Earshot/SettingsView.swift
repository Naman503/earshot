import AVFoundation
import EarshotCore
import ServiceManagement
import Speech
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case howTo, general, voice, reading, highlight, gestures, shortcuts, notifications, autoRead, output, media
    var id: String { rawValue }

    var title: String {
        switch self {
        case .howTo: "How to use"
        case .general: "General"
        case .voice: "Voice & speed"
        case .reading: "Reading"
        case .highlight: "Highlight"
        case .gestures: "Trackpad gestures"
        case .shortcuts: "Keyboard shortcuts"
        case .notifications: "Notifications"
        case .autoRead: "Auto-read"
        case .output: "Headphones & output"
        case .media: "Other audio"
        }
    }

    var icon: String {
        switch self {
        case .howTo: "questionmark.circle"
        case .general: "gearshape"
        case .voice: "waveform"
        case .reading: "text.alignleft"
        case .highlight: "highlighter"
        case .gestures: "hand.tap"
        case .shortcuts: "keyboard"
        case .notifications: "bell.badge"
        case .autoRead: "text.badge.plus"
        case .output: "headphones"
        case .media: "speaker.wave.2"
        }
    }

    var detail: String {
        switch self {
        case .howTo: "Every gesture and shortcut at a glance"
        case .general: "Permissions, start at login, engine status"
        case .voice: "Voice, speed and loudness"
        case .reading: "How much a tap reads, what to skip, pronunciations, calls"
        case .highlight: "The marker that follows each spoken word"
        case .gestures: "What each multi-finger tap does"
        case .shortcuts: "Change any keyboard shortcut"
        case .notifications: "Which notifications are read and how"
        case .autoRead: "Read new text on chosen sites and apps"
        case .output: "Only speak into headphones, and which ones"
        case .media: "Turn videos and music down while reading"
        }
    }
}

/// Which page the settings window shows (shared so menu items and debug tools can switch it).
@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var tab: SettingsTab = .howTo
}

struct SettingsView: View {
    @ObservedObject private var nav = SettingsNavigation.shared

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: Binding(get: { nav.tab }, set: { if let t = $0 { nav.tab = t } })) { tab in
                Label(tab.title, systemImage: tab.icon).tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(nav.tab.title).font(.title2.weight(.semibold))
                    Text(nav.tab.detail).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 4)
                page(nav.tab)
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 820, minHeight: 600)
    }

    @ViewBuilder private func page(_ tab: SettingsTab) -> some View {
        switch tab {
        case .howTo: HowToTab()
        case .general: GeneralTab()
        case .voice: VoiceTab()
        case .reading: ReadingTab()
        case .highlight: HighlightTab()
        case .gestures: GesturesTab()
        case .shortcuts: ShortcutsTab()
        case .notifications: NotificationsTab()
        case .autoRead: AutoReadTab()
        case .output: OutputTab()
        case .media: MediaTab()
        }
    }
}

// MARK: How to use

private struct HowToTab: View {
    @EnvironmentObject var settings: Settings

    var body: some View {
        Form {
            Section("Reading") {
                row(.paragraph, "Point at text and tap with four fingers. Tap on selected text to read just the selection.")
                row(.fromHere, "Reads from the pointer to the end of the page.")
                row(.section, "Reads from the heading above the pointer to the next heading.")
                row(.visible, "Reads everything currently on screen.")
                row(.smartRead, "The selection, or else the paragraph under the pointer.")
                row(.summarize, "A short spoken summary, then asks if you want the rest.")
                row(.window, nil)
                row(.clipboard, nil)
                row(.readAgain, nil)
            }
            Section("While it's reading") {
                row(.pauseResume, nil)
                row(.stop, "Esc also stops, only while something is being read.")
                row(.nextSentence, nil)
                row(.previousSentence, nil)
                row(.nextParagraph, nil)
                row(.previousParagraph, nil)
                row(.faster, nil)
                row(.slower, nil)
                row(.boost, "Jumps to your boost speed and back, smoothly. Or hold fn alone to go fast and Control alone to go slow, only while held (Voice & speed).")
            }
            Section("Dictation") {
                row(.dictate, "Starts the Mac's own dictation: hold the keys and talk, then let go, or tap to start and stop. Earshot stops reading and gets out of the audio path first, and starts dictation again if the microphone doesn't open.")
            }
            Section("Notifications and pages") {
                row(.readNotification, "When it asks “Read it?”, this — or a four-finger tap, or saying “yes” — reads it.")
                row(.autoReadToggle, "Keeps reading new text on this page as it appears.")
            }
            Section {
                Text("Everything here can be changed under Keyboard shortcuts and Trackpad gestures.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ action: ReadAction, _ hint: String?) -> some View {
        let gestures = settings.gestures.filter { $0.value == action }.keys.sorted().map(\.label)
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let combo = settings.shortcuts[action] {
                    Text(HotKeys.describe(combo)).font(.system(.body, design: .rounded).weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }
                ForEach(gestures, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
        }
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
                LabeledContent("Speed") {
                    HStack {
                        Slider(value: $settings.speed, in: 0.7...4.0, step: 0.05)
                        Text(String(format: "%.2f×", settings.speed)).monospacedDigit().frame(width: 52)
                    }
                }
                LabeledContent("Boost speed") {
                    HStack {
                        Slider(value: $settings.boostSpeed, in: 1.0...4.0, step: 0.05)
                        Text(String(format: "%.2f×", settings.boostSpeed)).monospacedDigit().frame(width: 52)
                    }
                }
                LabeledContent("Slow speed") {
                    HStack {
                        Slider(value: $settings.slowSpeed, in: 0.7...3.0, step: 0.05)
                        Text(String(format: "%.2f×", settings.slowSpeed)).monospacedDigit().frame(width: 52)
                    }
                }
                Picker("Hold to speed up", selection: $settings.holdFasterKey) {
                    ForEach(HoldKey.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Hold to slow down", selection: $settings.holdSlowerKey) {
                    ForEach(HoldKey.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("While reading, hold the key on its own for the boost or slow speed; let go to return to normal. The voice switches cleanly at the next word, re-voiced at the new speed (never stretched). Pressing it with another key (⌃C, fn+F1…) does nothing. The boost shortcut (\(settings.shortcuts[.boost].map(HotKeys.describe) ?? "not set")) still switches until pressed again.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Click a voice to hear it at this speed.").font(.caption).foregroundStyle(.secondary)
                ForEach(VoiceCatalog.grouped(available: kokoro.voices), id: \.title) { group in
                    Section {
                        ForEach(group.voices, id: \.self) { id in
                            Button {
                                settings.voice = id
                                preview()
                            } label: {
                                HStack {
                                    Image(systemName: settings.voice == id ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(settings.voice == id ? Color.accentColor : .secondary)
                                    Text(VoiceCatalog.label(id))
                                    Spacer()
                                    Image(systemName: "play.circle").foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.title)
                            if !group.detail.isEmpty { Text(group.detail).font(.caption).foregroundStyle(.secondary) }
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

            if settings.engine != .kokoro {
                LabeledContent("Speed") {
                    HStack {
                        Slider(value: $settings.speed, in: 0.7...4.0, step: 0.05)
                        Text(String(format: "%.2f×", settings.speed)).monospacedDigit().frame(width: 52)
                    }
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

            Button("Play a sample", action: preview)
        }
        .formStyle(.grouped)
    }

    private var statusText: String {
        switch kokoro.status {
        case .ready: "Ready (\(kokoro.voices.count) voices)"
        case .starting: "Starting… the Apple voice is used until it's ready"
        case .asleep: "Asleep to save memory — wakes when you read"
        case .notInstalled: "Not installed — run scripts/install-engine.sh"
        case .failed(let m): "Failed: \(m)"
        }
    }

    private func preview() {
        reader.read("This is \(VoiceCatalog.label(settings.voice).components(separatedBy: " ·").first ?? "me") at \(String(format: "%.2g", settings.speed)) times speed. The quarterly report shows revenue grew by eighteen percent this year.", source: "sample")
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

// MARK: Notifications

private struct NotificationsTab: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var announcer: Announcer
    @State private var voiceAuthorized = VoiceReply.authorized

    var body: some View {
        Form {
            Toggle("Announce notifications", isOn: $settings.notificationsEnabled)
            Group {
                Picker("Usually", selection: $settings.notificationMode) {
                    ForEach(NotificationMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Read short messages in full without asking", isOn: $settings.readShortInFull)
                Toggle("Summarize long messages first", isOn: $settings.summarizeLong)
                    .disabled(!Summarizer.available)
                if !Summarizer.available {
                    Text("Summaries use Apple Intelligence's on-device model, which isn't available on this Mac right now.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Pause what I'm listening to for a notification, then continue", isOn: $settings.interruptReading)

                Section("Answering \"Read it?\"") {
                    HStack {
                        Toggle("Answer by voice (yes / no)", isOn: $settings.voiceReplies)
                        Spacer()
                        if settings.voiceReplies && !voiceAuthorized {
                            Button("Allow microphone…") {
                                Task { voiceAuthorized = await VoiceReply.requestPermissions() }
                            }
                        }
                    }
                    Text("Listens for 6 seconds with on-device recognition, using the Mac's own microphone so your earbuds keep full sound quality.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("A four-finger tap means yes", isOn: $settings.tapAnswersPrompt)
                    LabeledContent("Shortcut") {
                        Text(settings.shortcuts[.readNotification].map(HotKeys.describe) ?? "None").foregroundStyle(.secondary)
                    }
                }

                Section("Quiet hours") {
                    Toggle("Stay silent at night", isOn: $settings.quietHours)
                    HStack {
                        Picker("From", selection: $settings.quietStart) { ForEach(0..<24, id: \.self) { Text(Self.hour($0)).tag($0) } }
                        Picker("to", selection: $settings.quietEnd) { ForEach(0..<24, id: \.self) { Text(Self.hour($0)).tag($0) } }
                    }
                    .disabled(!settings.quietHours)
                }

                Section("Per app") {
                    if settings.knownApps.isEmpty {
                        Text("Apps show up here after their first notification.").foregroundStyle(.secondary)
                    }
                    ForEach(settings.knownApps.sorted(), id: \.self) { app in
                        Picker(app, selection: Binding(
                            get: { settings.appModes[app].map { ModeChoice.mode($0) } ?? .usual },
                            set: { settings.appModes[app] = $0.mode })) {
                            Text("Usual").tag(ModeChoice.usual)
                            ForEach(NotificationMode.allCases, id: \.self) { Text($0.title).tag(ModeChoice.mode($0)) }
                        }
                    }
                }
                Button("Send a test notification") {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    p.arguments = ["-e", "display notification \"Hey, the vendor meeting moved to 4 pm tomorrow because their team is travelling. Please bring the updated price sheet and the signed contract copy, and confirm on the group once you've seen this.\" with title \"Rahul\" subtitle \"Vendor meeting\""]
                    try? p.run()
                }
            }
            .disabled(!settings.notificationsEnabled)
        }
        .formStyle(.grouped)
        .onAppear { voiceAuthorized = VoiceReply.authorized }
    }

    enum ModeChoice: Hashable {
        case usual, mode(NotificationMode)
        var mode: NotificationMode? { if case .mode(let m) = self { m } else { nil } }
    }

    static func hour(_ h: Int) -> String { h == 0 ? "12 am" : h < 12 ? "\(h) am" : h == 12 ? "12 pm" : "\(h - 12) pm" }
}

// MARK: Auto-read

private struct AutoReadTab: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var watcher: PageWatcher
    @State private var newPattern = ""

    var body: some View {
        Form {
            Section {
                Toggle("Auto-read on these sites and apps", isOn: $settings.autoReadEnabled)
                Text("Earshot checks the page you're looking at once a second. When new text appears and stops changing — a chat reply, a new message, a search answer — it reads just the new part. Your own typing is never read.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Any other page") {
                    Text("Press \(settings.shortcuts[.autoReadToggle].map(HotKeys.describe) ?? "the auto-read shortcut") to auto-read it until you press it again")
                        .foregroundStyle(.secondary)
                }
                if let pinned = watcher.pinnedTitle {
                    LabeledContent("Auto-reading now") { Text(pinned).lineLimit(1) }
                }
            }
            Section("Rules") {
                ForEach($settings.autoReadRules) { $rule in
                    HStack(spacing: 10) {
                        Toggle("", isOn: $rule.enabled).labelsHidden()
                        Text(rule.pattern.hasPrefix("app:") ? "\(rule.pattern.dropFirst(4)) (app)" : rule.pattern)
                            .frame(width: 150, alignment: .leading)
                        Toggle("New text", isOn: $rule.newContent)
                        Picker("New page", selection: $rule.newPage) {
                            ForEach(NewPageAction.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .frame(maxWidth: 300)
                        Button {
                            settings.autoReadRules.removeAll { $0.pattern == rule.pattern }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                    .disabled(!settings.autoReadEnabled)
                }
                HStack {
                    TextField("example.com, or app:WhatsApp", text: $newPattern)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let host = watcher.lastHost, !settings.autoReadRules.contains(where: { $0.pattern == host }) {
                        Button("Add \(host)") { newPattern = host; add() }
                    }
                }
                Text("“New page” is for search engines: when a results page finishes loading, read its top answer or a summary.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        var p = newPattern.trimmingCharacters(in: .whitespaces).lowercased()
        if !p.hasPrefix("app:"), let host = URL(string: p.contains("://") ? p : "https://" + p)?.host { p = host }
        if p.hasPrefix("www.") { p.removeFirst(4) }
        guard !p.isEmpty, !settings.autoReadRules.contains(where: { $0.pattern == p }) else { return }
        // Keep app names' capitalization as typed.
        if newPattern.lowercased().hasPrefix("app:") { p = "app:" + newPattern.trimmingCharacters(in: .whitespaces).dropFirst(4) }
        settings.autoReadRules.append(AutoReadRule(pattern: p, enabled: true, newContent: true, newPage: .nothing))
        newPattern = ""
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
            if settings.mediaPolicy == .duck {
                LabeledContent("Turn others down to") {
                    HStack {
                        Slider(value: $settings.duckLevel, in: 0...0.6, step: 0.05)
                        Text("\(Int(settings.duckLevel * 100))%").monospacedDigit().frame(width: 44)
                    }
                }
                Text("Works for every app, including videos in your browser. macOS asks once for permission to \"record this computer's audio\": Earshot needs that to turn other apps down, and nothing is recorded or saved. If you say no, Earshot pauses instead.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Try it: play a video, then click here") {
                    AppDelegate.shared.reader.ducker.resetAvailability()
                    AppDelegate.shared.reader.read("Your video should be quieter while I'm talking, and come back up as soon as I finish this sentence.", source: "duck test")
                }
            } else {
                Text("Earshot presses the system play/pause key, which YouTube in your browser, Spotify, Music and most players follow. It only resumes what it paused.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
        Button(recording ? "Press keys…" : combo.map(HotKeys.describe) ?? "Set…") {
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
                        get: { settings.gestures[g] ?? ReadAction.none },
                        set: { (new: ReadAction) in settings.gestures[g] = new == ReadAction.none ? nil : new })) {
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
            Section {
                Picker("Paragraphs above", selection: $settings.paragraphsBefore) {
                    Text("None").tag(0)
                    ForEach(1...10, id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Paragraphs below", selection: $settings.paragraphsAfter) {
                    Text("None").tag(0)
                    ForEach(1...10, id: \.self) { Text("\($0)").tag($0) }
                    Text("To the end").tag(-1)
                }
                Picker("“To the end” and “Read from here” stop at", selection: $settings.readScope) {
                    ForEach(ReadScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("If text is selected, a tap reads the selection", isOn: $settings.tapReadsSelection)
            } header: {
                Text("How much “Read paragraph” reads")
            } footer: {
                Text("Applies to “Read paragraph” from a tap or shortcut. Headings and short lines in between come along but don't count. For other amounts, give a gesture “Read the whole section”, “Read from pointer to the end” or “Read everything visible on screen” under Trackpad gestures.")
                    .font(.caption)
            }
            Section("Skip while reading") {
                Toggle("Web addresses (URLs)", isOn: $settings.skipURLs)
                Toggle("Citation marks like [12]", isOn: $settings.skipCitations)
                Toggle("Emoji", isOn: $settings.skipEmoji)
                Toggle("Say IDs, hashes, IP addresses, keys and long numbers briefly", isOn: $settings.shortenIDs)
            }
            Section("Code, commands and file paths") {
                Picker("When reading them", selection: $settings.technicalText) {
                    ForEach(TextPrep.TechnicalText.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if settings.technicalText == .fast {
                    LabeledContent("Fast speed") {
                        HStack {
                            Slider(value: $settings.technicalSpeed, in: 2.0...4.0, step: 0.25)
                            Text(String(format: "%.2g×", settings.technicalSpeed)).monospacedDigit().frame(width: 40)
                        }
                    }
                }
                Text("Lines like shell commands, code, JSON, long file paths and agent rows such as “Ran 3 commands” or “Read Reader.swift”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Feedback") {
                Toggle("Show the now-reading bar", isOn: $settings.showHUD)
                Toggle("Outline the text that was picked up", isOn: $settings.highlightSource)
            }
            Section("Calls") {
                Toggle("Pause reading and hold notifications while another app uses the microphone", isOn: $settings.pauseForCalls)
            }
            PronunciationsSection()
        }
        .formStyle(.grouped)
    }
}

private struct PronunciationsSection: View {
    @EnvironmentObject var settings: Settings
    @State private var word = ""
    @State private var say = ""

    var body: some View {
        Section {
            ForEach(settings.pronunciations) { fix in
                HStack {
                    Text(fix.word).frame(width: 160, alignment: .leading)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text(fix.say)
                    Spacer()
                    Button { AppDelegate.shared.reader.read(fix.word, source: "sample") } label: { Image(systemName: "play.circle") }
                        .buttonStyle(.borderless)
                    Button { settings.pronunciations.removeAll { $0 == fix } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Word", text: $word).frame(width: 160)
                TextField("Say it like", text: $say)
                Button("Test") { AppDelegate.shared.reader.read(say.isEmpty ? word : say, source: "sample") }
                    .disabled(word.isEmpty && say.isEmpty)
                Button("Add") {
                    settings.pronunciations.removeAll { $0.word.caseInsensitiveCompare(word) == .orderedSame }
                    settings.pronunciations.append(Pronunciation(word: word, say: say))
                    word = ""
                    say = ""
                }
                .disabled(word.trimmingCharacters(in: .whitespaces).isEmpty || say.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Pronunciations")
        } footer: {
            Text("Whole words, any capitalization. Spell it the way it sounds, e.g. Eazeebox → easy box, SQL → sequel, Naman → nuh-mun.")
                .font(.caption)
        }
    }
}

// MARK: General

private struct GeneralTab: View {
    @ObservedObject private var permissions = Permissions.shared
    @EnvironmentObject var kokoro: KokoroEngine
    @EnvironmentObject var settings: Settings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var speech = SFSpeechRecognizer.authorizationStatus() == .authorized

    var body: some View {
        Form {
            Section("Permissions") {
                row("Accessibility", "Required: reads text under the pointer and pauses media.", permissions.accessibility) {
                    permissions.requestAccessibility()
                }
                row("Screen Recording", "Optional: reads text in images, PDFs and apps that don't expose it.", permissions.screenRecording) {
                    permissions.requestScreenRecording()
                }
                row("Microphone", "For answering “Read it?” by voice.", mic) {
                    AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { mic = ok } }
                }
                row("Speech recognition", "For answering “Read it?” by voice (on this Mac).", speech) {
                    SFSpeechRecognizer.requestAuthorization { s in DispatchQueue.main.async { speech = s == .authorized } }
                }
                LabeledContent {
                    Text("macOS asks the first time other audio is turned down").foregroundStyle(.secondary)
                } label: {
                    VStack(alignment: .leading) {
                        Text("System audio")
                        Text("For turning videos and music down while reading.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Voice engine") {
                LabeledContent("Kokoro voice") {
                    switch kokoro.status {
                    case .ready: Label("Running", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .starting: Label("Starting…", systemImage: "hourglass").foregroundStyle(.secondary)
                    case .asleep: Label("Asleep (memory freed)", systemImage: "moon.zzz").foregroundStyle(.secondary)
                    case .notInstalled: Text("Not installed — run scripts/install-engine.sh").foregroundStyle(.orange)
                    case .failed(let m): Text(m).foregroundStyle(.red)
                    }
                }
                Toggle("Free the voice's memory when it isn't being used", isOn: $settings.sleepVoiceWhenIdle)
                if settings.sleepVoiceWhenIdle {
                    Picker("After", selection: $settings.sleepVoiceAfterMinutes) {
                        ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) minutes without reading").tag($0) }
                    }
                }
                Text("The voice uses about 0.8 GB while it's ready. Freeing it saves that memory; the first reading afterwards takes about 5 seconds to start (you'll see “Waking the voice…”). Runs entirely on this Mac. Nothing you read or hear leaves it.")
                    .font(.caption).foregroundStyle(.secondary)
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

// MARK: Highlight look

/// Style (Soft / Bold) and colour for the word highlight, with a live preview
/// drawn the same way as the marker on the page.
private struct HighlightLookPicker: View {
    @EnvironmentObject var settings: Settings

    var body: some View {
        LabeledContent("Highlight style") {
            Picker("", selection: $settings.highlightStyle) {
                Text("Soft").tag(HighlightStyle.soft)
                Text("Bold").tag(HighlightStyle.bold)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
        }
        LabeledContent("Highlight colour") {
            HStack(spacing: 12) {
                ForEach(HighlightColor.allCases, id: \.self) { c in
                    swatch(c)
                }
            }
        }
        VStack(alignment: .leading, spacing: 10) {
            preview(color: Color(nsColor: settings.highlightColor.color), label: "Normal speed")
            HStack(spacing: 24) {
                preview(color: .orange, label: "Fast")
                preview(color: .teal, label: "Slow")
            }
        }
        .padding(.vertical, 4)
    }

    private func swatch(_ c: HighlightColor) -> some View {
        let selected = settings.highlightColor == c
        return Button {
            settings.highlightColor = c
        } label: {
            ZStack {
                Circle().fill(Color(nsColor: c.color)).frame(width: 22, height: 22)
                Circle().strokeBorder(Color.primary.opacity(selected ? 0.9 : 0.15), lineWidth: selected ? 2.5 : 1)
                    .frame(width: 30, height: 30)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: 1)
                }
            }
            .frame(width: 30, height: 30)
            .overlay(alignment: .bottom) {
                Text(c == .accent ? "System" : c.title)
                    .font(.system(size: 9.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .fixedSize()
                    .offset(y: 15)
            }
            .padding(.bottom, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(c.title)
        .accessibilityLabel(c.title + (selected ? ", selected" : ""))
    }

    /// A sample line with one word marked exactly like the page marker.
    private func preview(color: Color, label: String) -> some View {
        let bold = settings.highlightStyle == .bold
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("Earshot")
                Text("follows")
                    .padding(.horizontal, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(bold ? 0.42 : 0.22)))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(bold ? 0.95 : 0), lineWidth: 1.5))
                    .overlay(alignment: .bottom) {
                        Capsule().fill(color.opacity(bold ? 1 : 0.95)).frame(height: bold ? 3 : 2.5).padding(.horizontal, 1).offset(y: 2)
                    }
                Text("each word")
            }
            .font(.system(size: 14))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct HighlightTab: View {
    @EnvironmentObject var settings: Settings

    var body: some View {
        Form {
            Section {
                Toggle("Highlight each word on the page as it's spoken", isOn: $settings.highlightWords)
                Toggle("Also highlight it in the now-reading bar", isOn: $settings.highlightWordsInBar)
            } footer: {
                Text("Short words are lit together with the next one. Works in browsers, Electron apps like Claude, and Mac text views.")
                    .font(.caption)
            }
            Section("Look") {
                HighlightLookPicker()
            }
            .disabled(!settings.highlightWords)
            Section {
                Toggle("Scroll the page as it reads", isOn: $settings.autoScroll)
                Picker("Glide", selection: $settings.autoScrollGlide) {
                    Text("Quick").tag(0.6)
                    Text("Smooth").tag(0.9)
                    Text("Gentle").tag(1.2)
                }
                .pickerStyle(.segmented)
                .disabled(!settings.autoScroll)
                Picker("After you scroll yourself, wait", selection: $settings.autoScrollPause) {
                    ForEach([2.0, 3, 5, 10, 20], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                }
                .disabled(!settings.autoScroll)
            } header: {
                Text("Follow along")
            } footer: {
                Text("Read down the window as usual; when the spoken line nears the bottom, the page glides up a few lines and the highlight moves with it. Keep the pointer over the page for smooth glides. Scroll or page yourself and it leaves the page alone; once you stop for the time above, it glides back to the spoken line.")
                    .font(.caption)
            }
            .disabled(!settings.highlightWords)
            Section {
                LabeledContent("Timing") {
                    HStack {
                        Text("Earlier").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $settings.highlightOffset, in: -0.3...0.6, step: 0.05)
                        Text("Later").font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "%+.2f s", settings.highlightOffset)).monospacedDigit().frame(width: 56)
                    }
                }
            } footer: {
                Text("If the marker runs ahead of the voice or behind it, move it here.").font(.caption)
            }
            .disabled(!settings.highlightWords)
        }
        .formStyle(.grouped)
    }
}
