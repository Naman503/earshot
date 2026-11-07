import Foundation

/// Everything a shortcut or gesture can trigger.
public enum ReadAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case smartRead, paragraph, sentence, fromHere, section, visible, selection, window
    case clipboard, readAgain
    case pauseResume, stop, nextSentence, previousSentence, nextParagraph, previousParagraph, faster, slower, boost
    case readNotification, summarize, autoReadToggle, dictate
    case none

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .smartRead: "Read selection, or the paragraph under the pointer"
        case .paragraph: "Read paragraph under pointer"
        case .sentence: "Read sentence under pointer"
        case .fromHere: "Read from pointer to the end"
        case .section: "Read the whole section under the pointer"
        case .visible: "Read everything visible on screen"
        case .selection: "Read selected text"
        case .window: "Read the whole window"
        case .pauseResume: "Pause / resume"
        case .stop: "Stop"
        case .clipboard: "Read the clipboard"
        case .readAgain: "Read the last thing again"
        case .nextParagraph: "Skip to next paragraph"
        case .previousParagraph: "Back one paragraph"
        case .nextSentence: "Skip to next sentence"
        case .previousSentence: "Back one sentence"
        case .faster: "Speed up"
        case .slower: "Slow down"
        case .boost: "Boost speed: tap to switch, hold for a burst"
        case .readNotification: "Read the latest notification (or answer yes)"
        case .summarize: "Summarize the page (or selection), then offer to read it"
        case .autoReadToggle: "Auto-read new text on this page (on / off)"
        case .dictate: "Mac dictation: hold to talk, or tap to start and stop"
        case .none: "Nothing"
        }
    }
}

/// A key plus Carbon modifier flags (cmdKey, optionKey, controlKey, shiftKey).
public struct KeyCombo: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }
}

/// Where speech may play.
public enum OutputPolicy: String, CaseIterable, Codable, Sendable {
    case headphonesOnly, chosenDevices, anyDevice

    public var title: String {
        switch self {
        case .headphonesOnly: "Headphones and earbuds only"
        case .chosenDevices: "Only the devices I pick"
        case .anyDevice: "Any output, including Mac speakers"
        }
    }
}

/// What to do with other audio (videos, music) while reading.
/// Colour of the word highlight at normal speed.
public enum HighlightColor: String, CaseIterable, Codable, Sendable {
    case yellow, green, pink, blue, accent

    public var title: String {
        switch self {
        case .yellow: "Yellow"
        case .green: "Green"
        case .pink: "Pink"
        case .blue: "Blue"
        case .accent: "System accent colour"
        }
    }
}

/// A single key that does something only while it's held down on its own.
public enum HoldKey: String, CaseIterable, Codable, Sendable {
    case none, fn, control, option, rightOption, rightCommand, shift

    public var title: String {
        switch self {
        case .none: "Off"
        case .fn: "fn / 🌐"
        case .control: "Control ⌃"
        case .option: "Option ⌥ (either)"
        case .rightOption: "Right Option ⌥"
        case .rightCommand: "Right Command ⌘"
        case .shift: "Shift ⇧"
        }
    }

    /// Virtual key codes of the physical keys.
    public var keyCodes: Set<Int64> {
        switch self {
        case .none: []
        case .fn: [63]
        case .control: [59, 62]
        case .option: [58, 61]
        case .rightOption: [61]
        case .rightCommand: [54]
        case .shift: [56, 60]
        }
    }
}

/// Where reading "to the end" stops on web pages and chat apps.
public enum ReadScope: String, CaseIterable, Codable, Sendable {
    case message, conversation, page

    public var title: String {
        switch self {
        case .message: "End of this reply or post"
        case .conversation: "End of the conversation (not side panels or the message box)"
        case .page: "End of the whole page"
        }
    }
}

public enum MediaPolicy: String, CaseIterable, Codable, Sendable {
    case duck, pauseAndResume, keepPlaying

    public var title: String {
        switch self {
        case .duck: "Turn it down while reading, back up after"
        case .pauseAndResume: "Pause it, resume when done"
        case .keepPlaying: "Keep playing"
        }
    }
}

public enum EngineChoice: String, CaseIterable, Codable, Sendable {
    case kokoro, apple

    public var title: String {
        switch self {
        case .kokoro: "Kokoro (natural, local)"
        case .apple: "Apple system voice"
        }
    }
}

/// Splits a user speed into what the model generates natively and what the
/// player time-stretches: model speed sounds most natural up to ~1.35x.
public func speedSplit(_ speed: Double, modelCap: Double = 1.35) -> (model: Double, stretch: Double) {
    let model = min(max(speed, 0.7), modelCap)
    return (model, speed / model)
}

/// How a notification is spoken.
public enum NotificationMode: String, CaseIterable, Codable, Sendable {
    case ask, full, brief, mute

    public var title: String {
        switch self {
        case .ask: "Say who it's from, ask before reading"
        case .full: "Read it in full"
        case .brief: "Just say who it's from"
        case .mute: "Stay silent"
        }
    }
}

/// A notification banner as read from Notification Center.
public struct BannerNote: Equatable, Sendable {
    public var id: String
    public var app: String
    public var title: String
    public var subtitle: String
    public var body: String

    public init(id: String, app: String, title: String, subtitle: String, body: String) {
        self.id = id; self.app = app; self.title = title; self.subtitle = subtitle; self.body = body
    }

    /// Banner accessibility descriptions read "App, Title, Subtitle, Body"; the
    /// app is whatever comes before the title.
    public static func appName(description: String, title: String) -> String {
        if !title.isEmpty, let r = description.range(of: ", " + title) {
            return String(description[..<r.lowerBound])
        }
        return description.components(separatedBy: ", ").first ?? description
    }

    /// "Rahul" style sender line: the title, plus the subtitle when there is one.
    public var who: String { subtitle.isEmpty ? title : "\(title), \(subtitle)" }
}

/// True when `hour` (0–23) falls in a quiet window that may wrap midnight.
public func inQuietHours(_ hour: Int, start: Int, end: Int) -> Bool {
    start == end ? false : start < end ? (hour >= start && hour < end) : (hour >= start || hour < end)
}
