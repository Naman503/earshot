import Foundation

/// Everything a shortcut or gesture can trigger.
public enum ReadAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case smartRead, paragraph, sentence, fromHere, selection, window
    case pauseResume, stop, nextSentence, previousSentence, faster, slower
    case none

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .smartRead: "Read selection, or the paragraph under the pointer"
        case .paragraph: "Read paragraph under pointer"
        case .sentence: "Read sentence under pointer"
        case .fromHere: "Read from pointer to the end"
        case .selection: "Read selected text"
        case .window: "Read the whole window"
        case .pauseResume: "Pause / resume"
        case .stop: "Stop"
        case .nextSentence: "Skip to next sentence"
        case .previousSentence: "Back one sentence"
        case .faster: "Speed up"
        case .slower: "Slow down"
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
public enum MediaPolicy: String, CaseIterable, Codable, Sendable {
    case pauseAndResume, keepPlaying

    public var title: String {
        switch self {
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
