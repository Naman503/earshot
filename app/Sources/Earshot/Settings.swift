import Carbon.HIToolbox
import EarshotCore
import Foundation
import SwiftUI

/// All user preferences, persisted to UserDefaults.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    // Voice
    @Published var engine: EngineChoice { didSet { save("engine", engine.rawValue) } }
    @Published var voice: String { didSet { save("voice", voice) } }
    @Published var appleVoiceID: String { didSet { save("appleVoiceID", appleVoiceID) } }
    @Published var speed: Double { didSet { save("speed", speed) } }
    /// The speed the boost shortcut switches to.
    @Published var boostSpeed: Double { didSet { save("boostSpeed", boostSpeed) } }
    /// The speed while the slow-down key is held.
    @Published var slowSpeed: Double { didSet { save("slowSpeed", slowSpeed) } }
    /// Single keys that change speed only while held down.
    @Published var holdFasterKey: HoldKey { didSet { save("holdFasterKey", holdFasterKey.rawValue) } }
    @Published var holdSlowerKey: HoldKey { didSet { save("holdSlowerKey", holdSlowerKey.rawValue) } }
    /// 0...2, where values above 1 boost loudness through a limiter.
    @Published var volume: Double { didSet { save("volume", volume) } }

    // Text
    @Published var skipURLs: Bool { didSet { save("skipURLs", skipURLs) } }
    @Published var skipCitations: Bool { didSet { save("skipCitations", skipCitations) } }
    @Published var skipEmoji: Bool { didSet { save("skipEmoji", skipEmoji) } }
    @Published var highlightSource: Bool { didSet { save("highlightSource", highlightSource) } }
    /// Follow-along: light up the word being spoken on the page and in the bar.
    /// Follow-along marker on the page itself.
    @Published var highlightWords: Bool { didSet { save("highlightWords", highlightWords) } }
    /// Also light up the word in the now-reading bar (off: the page is enough).
    @Published var highlightWordsInBar: Bool { didSet { save("highlightWordsInBar", highlightWordsInBar) } }
    /// Stop the voice engine (freeing ~0.8 GB) after this many idle minutes.
    @Published var sleepVoiceWhenIdle: Bool { didSet { save("sleepVoiceWhenIdle", sleepVoiceWhenIdle) } }
    @Published var sleepVoiceAfterMinutes: Int { didSet { save("sleepVoiceAfterMinutes", sleepVoiceAfterMinutes) } }
    /// Seconds to move the word highlight later (+) or earlier (−) than measured.
    @Published var highlightOffset: Double { didSet { save("highlightOffset", highlightOffset) } }
    /// Code, commands, paths and tool rows: read fast, skip, or read normally.
    @Published var technicalText: TextPrep.TechnicalText { didSet { save("technicalText", technicalText.rawValue) } }
    /// Speed for technical text when read fast (never slower than normal).
    @Published var technicalSpeed: Double { didSet { save("technicalSpeed", technicalSpeed) } }
    @Published var showHUD: Bool { didSet { save("showHUD", showHUD) } }

    /// How far a paragraph tap reaches: paragraphs above, and below (-1 = to the end).
    @Published var paragraphsBefore: Int { didSet { save("paragraphsBefore", paragraphsBefore) } }
    @Published var paragraphsAfter: Int { didSet { save("paragraphsAfter", paragraphsAfter) } }
    /// Where "to the end" and "read from here" stop.
    @Published var readScope: ReadScope { didSet { save("readScope", readScope.rawValue) } }
    /// A tap on selected text reads the selection.
    @Published var tapReadsSelection: Bool { didSet { save("tapReadsSelection", tapReadsSelection) } }
    @Published var pronunciations: [Pronunciation] { didSet { saveJSON("pronunciations", pronunciations) } }
    /// Pause reading (and hold notifications) while another app uses a microphone.
    @Published var pauseForCalls: Bool { didSet { save("pauseForCalls", pauseForCalls) } }

    // Output and media
    @Published var outputPolicy: OutputPolicy { didSet { save("outputPolicy", outputPolicy.rawValue) } }
    @Published var allowedDeviceUIDs: [String] { didSet { save("allowedDeviceUIDs", allowedDeviceUIDs) } }
    @Published var mediaPolicy: MediaPolicy { didSet { save("mediaPolicy", mediaPolicy.rawValue) } }
    /// How loud other audio stays while ducked (0…1).
    @Published var duckLevel: Double { didSet { save("duckLevel", duckLevel) } }
    /// Pause reading (instead of stopping) when headphones disconnect mid-read.
    @Published var pauseOnDisconnect: Bool { didSet { save("pauseOnDisconnect", pauseOnDisconnect) } }

    // Input
    @Published var shortcuts: [ReadAction: KeyCombo] { didSet { saveJSON("shortcuts", shortcuts) } }
    @Published var gestures: [TrackpadTap: ReadAction] { didSet { saveJSON("gestures", gestures.map { GestureEntry(gesture: $0.key, action: $0.value) }) } }
    @Published var gesturesEnabled: Bool { didSet { save("gesturesEnabled", gesturesEnabled) } }
    @Published var escapeStops: Bool { didSet { save("escapeStops", escapeStops) } }

    // Notifications
    @Published var notificationsEnabled: Bool { didSet { save("notificationsEnabled", notificationsEnabled) } }
    @Published var notificationMode: NotificationMode { didSet { save("notificationMode", notificationMode.rawValue) } }
    @Published var appModes: [String: NotificationMode] { didSet { saveJSON("appModes", appModes) } }
    @Published var knownApps: [String] { didSet { save("knownApps", knownApps) } }
    @Published var readShortInFull: Bool { didSet { save("readShortInFull", readShortInFull) } }
    @Published var summarizeLong: Bool { didSet { save("summarizeLong", summarizeLong) } }
    @Published var voiceReplies: Bool { didSet { save("voiceReplies", voiceReplies) } }
    @Published var tapAnswersPrompt: Bool { didSet { save("tapAnswersPrompt", tapAnswersPrompt) } }
    @Published var interruptReading: Bool { didSet { save("interruptReading", interruptReading) } }
    @Published var quietHours: Bool { didSet { save("quietHours", quietHours) } }
    @Published var quietStart: Int { didSet { save("quietStart", quietStart) } }
    @Published var quietEnd: Int { didSet { save("quietEnd", quietEnd) } }

    // Auto-read
    @Published var autoReadEnabled: Bool { didSet { save("autoReadEnabled", autoReadEnabled) } }
    @Published var autoReadRules: [AutoReadRule] { didSet { saveJSON("autoReadRules", autoReadRules) } }


    func mode(for app: String) -> NotificationMode { appModes[app] ?? notificationMode }

    struct GestureEntry: Codable { var gesture: TrackpadTap; var action: ReadAction }

    static let defaultShortcuts: [ReadAction: KeyCombo] = {
        let ctrlOpt = UInt32(controlKey | optionKey)
        return [
            .smartRead: KeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: ctrlOpt),
            .fromHere: KeyCombo(keyCode: UInt32(kVK_ANSI_A), modifiers: ctrlOpt),
            .window: KeyCombo(keyCode: UInt32(kVK_ANSI_W), modifiers: ctrlOpt),
            .section: KeyCombo(keyCode: UInt32(kVK_ANSI_B), modifiers: ctrlOpt),
            .visible: KeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: ctrlOpt),
            .pauseResume: KeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: ctrlOpt),
            .stop: KeyCombo(keyCode: UInt32(kVK_ANSI_S), modifiers: ctrlOpt),
            .nextSentence: KeyCombo(keyCode: UInt32(kVK_RightArrow), modifiers: ctrlOpt),
            .previousSentence: KeyCombo(keyCode: UInt32(kVK_LeftArrow), modifiers: ctrlOpt),
            .faster: KeyCombo(keyCode: UInt32(kVK_UpArrow), modifiers: ctrlOpt),
            .slower: KeyCombo(keyCode: UInt32(kVK_DownArrow), modifiers: ctrlOpt),
            .nextParagraph: KeyCombo(keyCode: UInt32(kVK_RightArrow), modifiers: ctrlOpt | UInt32(shiftKey)),
            .previousParagraph: KeyCombo(keyCode: UInt32(kVK_LeftArrow), modifiers: ctrlOpt | UInt32(shiftKey)),
            .clipboard: KeyCombo(keyCode: UInt32(kVK_ANSI_C), modifiers: ctrlOpt),
            .readAgain: KeyCombo(keyCode: UInt32(kVK_ANSI_Z), modifiers: ctrlOpt),
            .readNotification: KeyCombo(keyCode: UInt32(kVK_ANSI_N), modifiers: ctrlOpt),
            .summarize: KeyCombo(keyCode: UInt32(kVK_ANSI_G), modifiers: ctrlOpt),
            .autoReadToggle: KeyCombo(keyCode: UInt32(kVK_ANSI_L), modifiers: ctrlOpt),
            .dictate: KeyCombo(keyCode: UInt32(kVK_ANSI_D), modifiers: ctrlOpt),
            .boost: KeyCombo(keyCode: UInt32(kVK_ANSI_F), modifiers: ctrlOpt),
        ]
    }()

    static let defaultGestures: [TrackpadTap: ReadAction] = [
        TrackpadTap(fingers: 4, taps: 1): .paragraph,
        TrackpadTap(fingers: 4, taps: 2): .fromHere,
        TrackpadTap(fingers: 4, taps: 3): .summarize,
        TrackpadTap(fingers: 3, taps: 2): .pauseResume,
        TrackpadTap(fingers: 5, taps: 1): .stop,
    ]

    private init() {
        engine = EngineChoice(rawValue: d.string(forKey: "engine") ?? "") ?? .kokoro
        voice = d.string(forKey: "voice") ?? "af_heart"
        appleVoiceID = d.string(forKey: "appleVoiceID") ?? ""
        speed = d.object(forKey: "speed") as? Double ?? 1.8
        boostSpeed = d.object(forKey: "boostSpeed") as? Double ?? 3.0
        slowSpeed = d.object(forKey: "slowSpeed") as? Double ?? 1.3
        holdFasterKey = d.string(forKey: "holdFasterKey").flatMap(HoldKey.init) ?? .fn
        holdSlowerKey = d.string(forKey: "holdSlowerKey").flatMap(HoldKey.init) ?? .control
        volume = d.object(forKey: "volume") as? Double ?? 1.0
        skipURLs = d.object(forKey: "skipURLs") as? Bool ?? true
        skipCitations = d.object(forKey: "skipCitations") as? Bool ?? true
        skipEmoji = d.object(forKey: "skipEmoji") as? Bool ?? true
        highlightSource = d.object(forKey: "highlightSource") as? Bool ?? true
        highlightWords = d.object(forKey: "highlightWords") as? Bool ?? true
        highlightWordsInBar = d.object(forKey: "highlightWordsInBar") as? Bool ?? false
        sleepVoiceWhenIdle = d.object(forKey: "sleepVoiceWhenIdle") as? Bool ?? false
        sleepVoiceAfterMinutes = d.object(forKey: "sleepVoiceAfterMinutes") as? Int ?? 10
        highlightOffset = d.object(forKey: "highlightOffset") as? Double ?? 0
        technicalText = d.string(forKey: "technicalText").flatMap(TextPrep.TechnicalText.init) ?? .fast
        technicalSpeed = d.object(forKey: "technicalSpeed") as? Double ?? 4.0
        paragraphsBefore = d.object(forKey: "paragraphsBefore") as? Int ?? 0
        paragraphsAfter = d.object(forKey: "paragraphsAfter") as? Int ?? 0
        readScope = d.string(forKey: "readScope").flatMap(ReadScope.init) ?? .message
        tapReadsSelection = d.object(forKey: "tapReadsSelection") as? Bool ?? true
        pronunciations = Self.loadJSON("pronunciations", from: d) ?? []
        pauseForCalls = d.object(forKey: "pauseForCalls") as? Bool ?? true
        showHUD = d.object(forKey: "showHUD") as? Bool ?? true
        outputPolicy = OutputPolicy(rawValue: d.string(forKey: "outputPolicy") ?? "") ?? .headphonesOnly
        allowedDeviceUIDs = d.stringArray(forKey: "allowedDeviceUIDs") ?? []
        mediaPolicy = MediaPolicy(rawValue: d.string(forKey: "mediaPolicy") ?? "") ?? .duck
        duckLevel = d.object(forKey: "duckLevel") as? Double ?? 0.2
        pauseOnDisconnect = d.object(forKey: "pauseOnDisconnect") as? Bool ?? true
        gesturesEnabled = d.object(forKey: "gesturesEnabled") as? Bool ?? true
        escapeStops = d.object(forKey: "escapeStops") as? Bool ?? true
        notificationsEnabled = d.object(forKey: "notificationsEnabled") as? Bool ?? true
        notificationMode = NotificationMode(rawValue: d.string(forKey: "notificationMode") ?? "") ?? .ask
        appModes = Self.loadJSON("appModes", from: d) ?? [:]
        knownApps = d.stringArray(forKey: "knownApps") ?? []
        readShortInFull = d.object(forKey: "readShortInFull") as? Bool ?? true
        summarizeLong = d.object(forKey: "summarizeLong") as? Bool ?? true
        voiceReplies = d.object(forKey: "voiceReplies") as? Bool ?? true
        tapAnswersPrompt = d.object(forKey: "tapAnswersPrompt") as? Bool ?? true
        interruptReading = d.object(forKey: "interruptReading") as? Bool ?? true
        quietHours = d.object(forKey: "quietHours") as? Bool ?? false
        quietStart = d.object(forKey: "quietStart") as? Int ?? 22
        quietEnd = d.object(forKey: "quietEnd") as? Int ?? 8
        autoReadEnabled = d.object(forKey: "autoReadEnabled") as? Bool ?? true
        autoReadRules = Self.loadJSON("autoReadRules", from: d) ?? AutoReadRule.defaults
        var loaded: [ReadAction: KeyCombo] = Self.loadJSON("shortcuts", from: d) ?? Self.defaultShortcuts
        // Shortcuts added in later versions get their defaults.
        for (action, combo) in Self.defaultShortcuts where loaded[action] == nil && !loaded.values.contains(combo) {
            loaded[action] = combo
        }
        shortcuts = loaded
        let entries: [GestureEntry]? = Self.loadJSON("gestures", from: d)
        var g = entries.map { Dictionary($0.map { ($0.gesture, $0.action) }, uniquingKeysWith: { a, _ in a }) } ?? Self.defaultGestures
        // Gestures added in later versions get their defaults when still free.
        for (tap, action) in Self.defaultGestures where g[tap] == nil && !g.values.contains(action) { g[tap] = action }
        gestures = g
    }

    var textOptions: TextPrep.Options {
        var o = TextPrep.Options()
        o.skipURLs = skipURLs
        o.skipCitations = skipCitations
        o.skipEmoji = skipEmoji
        return o
    }

    func resetShortcuts() { shortcuts = Self.defaultShortcuts }
    func resetGestures() { gestures = Self.defaultGestures }

    private func save(_ key: String, _ value: Any) { d.set(value, forKey: key) }
    private func saveJSON<T: Encodable>(_ key: String, _ value: T) { d.set(try? JSONEncoder().encode(value), forKey: key) }
    private static func loadJSON<T: Decodable>(_ key: String, from d: UserDefaults) -> T? {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}

enum Log {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Earshot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("earshot.log")
    }()
    private static let queue = DispatchQueue(label: "earshot.log")
    private static let formatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(line.data(using: .utf8)!)
                try? h.close()
            } else {
                try? line.data(using: .utf8)!.write(to: url)
            }
        }
    }
}
