import Foundation

/// What changed between two snapshots of a page's text.
public enum TextChange: Equatable, Sendable {
    case none
    /// New text appeared (a chat reply, a new message, an answer box).
    case inserted(String)
    /// Mostly different text: a new page.
    case replaced
}

public enum TextDiff {
    /// Compares by common prefix and suffix; good enough for "something was
    /// added somewhere" and cheap on pages of tens of thousands of characters.
    public static func change(from old: String, to new: String, minOverlap: Double = 0.3) -> TextChange {
        guard old != new else { return .none }
        let a = Array(old.unicodeScalars), b = Array(new.unicodeScalars)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let kept = prefix + suffix
        if !old.isEmpty, Double(kept) < Double(max(a.count, b.count)) * minOverlap { return .replaced }
        guard b.count - suffix > prefix else { return .none }  // only deletions
        // Widen to whole lines so a reply isn't cut mid-word.
        var start = prefix, end = b.count - suffix
        while start > 0, b[start - 1] != "\n" { start -= 1 }
        if end > start, b[end - 1] == "\n" {
            end -= 1  // already ends on a line break
        } else {
            while end < b.count, b[end] != "\n" { end += 1 }
        }
        var s = String.UnicodeScalarView()
        s.append(contentsOf: b[start..<end])
        return .inserted(String(s))
    }

    /// Lines of UI chrome that chat apps add next to a reply.
    static let chrome: Set<String> = [
        "copy", "share", "retry", "edit", "like", "dislike", "good response", "bad response", "regenerate",
        "read aloud", "more actions", "thumbs up", "thumbs down", "reply", "react", "delivered", "seen", "sent",
    ]

    /// Inserted text minus what the user typed and minus UI chrome; nil when
    /// nothing worth reading is left.
    public static func speakable(_ inserted: String, typed: String?, minLength: Int = 12) -> String? {
        var text = inserted
        if let typed, typed.count >= 4 { text = text.replacingOccurrences(of: typed, with: "\n") }
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !chrome.contains($0.lowercased()) }
            .filter { $0.range(of: #"^\d{1,2}:\d{2}(\s?[AaPp][Mm])?$"#, options: .regularExpression) == nil }  // timestamps
        let joined = lines.joined(separator: "\n")
        return joined.count >= minLength ? joined : nil
    }
}

/// What to do on a newly opened page.
public enum NewPageAction: String, CaseIterable, Codable, Sendable {
    case nothing, firstParagraph, summary

    public var title: String {
        switch self {
        case .nothing: "Nothing"
        case .firstParagraph: "Read the top answer / first paragraph"
        case .summary: "Read a short summary"
        }
    }
}

/// A site (by host) or app (pattern "app:Name") to auto-read.
public struct AutoReadRule: Codable, Hashable, Sendable, Identifiable {
    public var pattern: String
    public var enabled: Bool
    public var newContent: Bool
    public var newPage: NewPageAction
    public var id: String { pattern }

    public init(pattern: String, enabled: Bool, newContent: Bool, newPage: NewPageAction) {
        self.pattern = pattern; self.enabled = enabled; self.newContent = newContent; self.newPage = newPage
    }

    public func matches(host: String?, app: String) -> Bool {
        if pattern.hasPrefix("app:") { return String(pattern.dropFirst(4)).caseInsensitiveCompare(app) == .orderedSame }
        guard let host = host?.lowercased() else { return false }
        let p = pattern.lowercased()
        return host == p || host.hasSuffix("." + p)
    }

    /// The most specific enabled rule that matches.
    public static func match(_ rules: [AutoReadRule], host: String?, app: String) -> AutoReadRule? {
        rules.filter { $0.enabled && $0.matches(host: host, app: app) }.max { $0.pattern.count < $1.pattern.count }
    }

    public static let defaults: [AutoReadRule] = [
        AutoReadRule(pattern: "google.com", enabled: true, newContent: false, newPage: .firstParagraph),
        AutoReadRule(pattern: "chatgpt.com", enabled: false, newContent: true, newPage: .nothing),
        AutoReadRule(pattern: "gemini.google.com", enabled: false, newContent: true, newPage: .nothing),
        AutoReadRule(pattern: "claude.ai", enabled: false, newContent: true, newPage: .nothing),
        AutoReadRule(pattern: "web.whatsapp.com", enabled: false, newContent: true, newPage: .nothing),
    ]
}
