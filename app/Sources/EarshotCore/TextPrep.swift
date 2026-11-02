import Foundation
import NaturalLanguage

/// Turns raw on-screen text into short, speakable chunks.
public enum TextPrep {
    public struct Options: Equatable, Sendable {
        public var skipURLs = true
        public var skipCitations = true
        public var skipEmoji = true
        public init() {}
    }

    /// Removes things that sound bad read aloud and normalizes whitespace,
    /// keeping paragraph breaks.
    public static func clean(_ text: String, options: Options = Options()) -> String {
        // Web pages mark embedded objects (links, images, buttons) with U+FFFC;
        // treat them as breaks so menus don't run into the article.
        var s = text.replacingOccurrences(of: "\u{FFFC}", with: "\n")
        if options.skipURLs {
            s = s.replacingOccurrences(of: #"https?://\S+|www\.\S+"#, with: " ", options: .regularExpression)
        }
        if options.skipCitations {
            // [1], [12], [3, 4], [citation needed]
            s = s.replacingOccurrences(of: #"\[(\d+(,\s*\d+)*|citation needed|edit)\]"#, with: "", options: .regularExpression)
        }
        if options.skipEmoji {
            s = String(String.UnicodeScalarView(s.unicodeScalars.filter {
                !($0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C))
            }))
        }
        let paragraphs = s.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: #"[ \t\x{00A0}]+"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #" +([.,;:!?])"#, with: "$1", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return paragraphs.joined(separator: "\n")
    }

    /// Splits text into sentence-sized chunks for streaming synthesis. Long
    /// sentences are broken at punctuation so the first audio starts quickly.
    public static func chunks(_ text: String, maxLength: Int = 220, firstMaxLength: Int = 110) -> [String] {
        var out: [String] = []
        for paragraph in text.components(separatedBy: "\n") where !paragraph.isEmpty {
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = paragraph
            tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
                let sentence = paragraph[range].trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty {
                    out.append(contentsOf: split(sentence, limit: out.isEmpty ? firstMaxLength : maxLength))
                }
                return true
            }
        }
        return out
    }

    /// Breaks one sentence into pieces no longer than `limit`, preferring
    /// clause punctuation, then spaces.
    static func split(_ sentence: String, limit: Int) -> [String] {
        guard sentence.count > limit else { return [sentence] }
        var pieces: [String] = []
        var rest = Substring(sentence)
        while rest.count > limit {
            let window = rest.prefix(limit)
            let minCut = window.index(window.startIndex, offsetBy: limit / 3)
            let cut = window[minCut...].lastIndex(where: { ",;:—–)".contains($0) }).map { rest.index(after: $0) }
                ?? window[minCut...].lastIndex(of: " ")
                ?? window.endIndex
            pieces.append(rest[..<cut].trimmingCharacters(in: .whitespaces))
            rest = rest[cut...].drop(while: { $0 == " " })
        }
        if !rest.isEmpty { pieces.append(String(rest)) }
        return pieces.filter { !$0.isEmpty }
    }
}

extension TextPrep {
    /// Drops site chrome (menus, links, buttons) above the first real paragraph,
    /// keeping up to two short lines right before it (a headline, a byline).
    public static func mainContent(_ text: String, minParagraph: Int = 100) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).count >= minParagraph }) else { return text }
        var start = first
        while start > 0, first - start < 2 {
            let prev = lines[start - 1].trimmingCharacters(in: .whitespaces)
            guard prev.count >= 12, prev.count < minParagraph else { break }
            start -= 1
        }
        return lines[start...].joined(separator: "\n")
    }

    /// Strips the "Here is a summary of the page:" style openers models add.
    public static func dropPreamble(_ text: String) -> String {
        text.replacingOccurrences(of: #"^\s*(here(’|')?s|here is|this is)\s+(a|the|your)\s+(short\s+|brief\s+|quick\s+)?summary[^:\n]*:\s*"#,
                                  with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits text at paragraph breaks into sections of at most `size` characters.
    public static func sections(_ text: String, size: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for para in text.components(separatedBy: "\n") where !para.isEmpty {
            for piece in para.count > size ? split(para, limit: size) : [para] {
                if current.count + piece.count + 1 > size, !current.isEmpty {
                    out.append(current)
                    current = ""
                }
                current += current.isEmpty ? piece : "\n" + piece
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

/// Finds the sentence / paragraph / rest-of-text around a character index.
public enum TextUnits {
    public enum Unit: Sendable { case sentence, paragraph, fromHere, all }

    public static func range(of unit: Unit, in text: String, at offset: Int) -> NSRange {
        let ns = text as NSString
        let i = max(0, min(offset, max(ns.length - 1, 0)))
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        switch unit {
        case .all:
            return NSRange(location: 0, length: ns.length)
        case .paragraph:
            return ns.paragraphRange(for: NSRange(location: i, length: 0))
        case .sentence, .fromHere:
            let para = ns.paragraphRange(for: NSRange(location: i, length: 0))
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = text
            let sentence = NSRange(tokenizer.tokenRange(at: text.index(text.startIndex, offsetBy: i, limitedBy: text.endIndex) ?? text.startIndex), in: text)
            let start = max(para.location, sentence.location)
            if unit == .sentence {
                let end = min(NSMaxRange(para), NSMaxRange(sentence))
                return NSRange(location: start, length: max(end - start, 0))
            }
            return NSRange(location: start, length: ns.length - start)
        }
    }

    public static func substring(_ unit: Unit, in text: String, at offset: Int) -> String {
        let r = range(of: unit, in: text, at: offset)
        return (text as NSString).substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
