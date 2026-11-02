import AVFoundation
import EarshotCore
import ServiceManagement
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case voice, dictation, notifications, autoRead, output, media, shortcuts, gestures, reading, general
}

struct SettingsView: View {
    @State var initialTab: SettingsTab

    var body: some View {
        TabView(selection: $initialTab) {
            VoiceTab().tabItem { Label("Voice", systemImage: "waveform") }.tag(SettingsTab.voice)
            DictationTab().tabItem { Label("Dictation", systemImage: "mic") }.tag(SettingsTab.dictation)
            NotificationsTab().tabItem { Label("Notifications", systemImage: "bell.badge") }.tag(SettingsTab.notifications)
            AutoReadTab().tabItem { Label("Auto-read", systemImage: "text.badge.plus") }.tag(SettingsTab.autoRead)
            OutputTab().tabItem { Label("Output", systemImage: "headphones") }.tag(SettingsTab.output)
            MediaTab().tabItem { Label("Media", systemImage: "play.rectangle") }.tag(SettingsTab.media)
            ShortcutsTab().tabItem { Label("Shortcuts", systemImage: "keyboard") }.tag(SettingsTab.shortcuts)
            GesturesTab().tabItem { Label("Gestures", systemImage: "hand.tap") }.tag(SettingsTab.gestures)
            ReadingTab().tabItem { Label("Reading", systemImage: "text.alignleft") }.tag(SettingsTab.reading)
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
        }
        .padding(20)
        .frame(width: 760, height: 580)
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

// MARK: Dictation

private struct DictationTab: View {
    @EnvironmentObject var settings: Settings
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        Form {
            Toggle("Dictation", isOn: $settings.dictationEnabled)
            Group {
                LabeledContent("Shortcut") {
                    Text(settings.shortcuts[.dictate].map(HotKeys.describe) ?? "None").foregroundStyle(.secondary)
                }
                Text("Hold the shortcut and talk, then let go — or tap it once to start and again to stop. Esc cancels. Your words are typed wherever the cursor is.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Recognizer", selection: $settings.dictationModel) {
                    Text("Parakeet — English, fastest and most accurate").tag("parakeet")
                    Text("Whisper — Hindi and mixed Hindi-English").tag("whisper")
                }
                if settings.dictationModel == "whisper" {
                    Picker("Language", selection: $settings.dictationLanguage) {
                        Text("English").tag("en")
                        Text("Hindi").tag("hi")
                        Text("Detect automatically").tag("")
                    }
                }
                Toggle("Use the Mac's own microphone (keeps earbuds in full sound quality)", isOn: $settings.dictationBuiltInMic)
                Toggle("Play a sound when listening starts and stops", isOn: $settings.dictationSounds)
                if micStatus != .authorized {
                    Button("Allow microphone…") {
                        AVCaptureDevice.requestAccess(for: .audio) { ok in
                            DispatchQueue.main.async { micStatus = ok ? .authorized : .denied }
                        }
                    }
                }
                Text("Runs entirely on this Mac: about 0.1 seconds to transcribe 15 seconds of speech on an M4.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!settings.dictationEnabled)
        }
        .formStyle(.grouped)
        .onAppear { micStatus = AVCaptureDevice.authorizationStatus(for: .audio) }
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
                Picker("Paragraphs above", selection: $settings.paragraphsBefore) {
                    Text("None").tag(0)
                    ForEach(1...10, id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Paragraphs below", selection: $settings.paragraphsAfter) {
                    Text("None").tag(0)
                    ForEach(1...10, id: \.self) { Text("\($0)").tag($0) }
                    Text("To the end").tag(-1)
                }
                Toggle("If text is selected, a tap reads the selection", isOn: $settings.tapReadsSelection)
            } header: {
                Text("How much “Read paragraph” reads")
            } footer: {
                Text("Applies to the paragraph tap and shortcut. Headings and short lines in between come along but don't count. For other amounts, give a gesture “Read the whole section”, “Read from pointer to the end” or “Read everything visible on screen”.")
                    .font(.caption)
            }
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
