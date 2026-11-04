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
        // Screen-reader labels chat apps put before each message.
        s = dropChatLabels(s)
        // Hidden keyboard hints chat apps give screen readers.
        s = s.replacingOccurrences(of: #"(?m)^\s*Use the up and down arrow keys to move between messages\.?\s*$"#, with: "", options: .regularExpression)
        s = speakableSymbols(s)
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

    /// Chat apps put a hidden heading before each message, "Claude responded:
    /// <its first sentence>". When the message itself follows, the heading only
    /// repeats it (the first sentence was read twice): drop it. Otherwise keep
    /// its text without the label.
    static func dropChatLabels(_ text: String) -> String {
        let label = #"^\s*(Claude|ChatGPT|Gemini|Copilot|You) (responded|said|wrote):\s*"#
        var lines = text.components(separatedBy: "\n")
        for i in lines.indices {
            guard let r = lines[i].range(of: label, options: .regularExpression) else { continue }
            let rest = String(lines[i][r.upperBound...])
            let next = lines[(i + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?.trimmingCharacters(in: .whitespaces) ?? ""
            let probe = String(rest.prefix(30))
            lines[i] = !probe.isEmpty && (next.hasPrefix(probe) || rest.hasPrefix(String(next.prefix(30))) && !next.isEmpty) ? "" : rest
        }
        return lines.joined(separator: "\n")
    }

    /// Key and arrow symbols the voice would say wrongly or not at all.
    public static func speakableSymbols(_ text: String) -> String {
        var s = text
        for (symbol, word) in [("⌃", "Control "), ("⌥", "Option "), ("⌘", "Command "), ("⇧", "Shift "), ("⎋", "Escape "),
                               ("⏎", "Return "), ("↩", "Return "), ("⌫", "Delete "), ("⇥", "Tab ")] {
            s = s.replacingOccurrences(of: symbol, with: word)
        }
        // "Settings → Reading" reads as "Settings, then Reading"; "A → B" in prose as "A to B".
        s = s.replacingOccurrences(of: #"\s*(→|⇒|➜|⟶|->)\s*"#, with: " to ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*(←|⇐|<-)\s*"#, with: " from ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\d)\s*×\s*(\d)"#, with: "$1 by $2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\d(?:\.\d+)?)×"#, with: "$1 times", options: .regularExpression)
        s = s.replacingOccurrences(of: "…", with: "...")
        // Bullets, box drawing and similar marks are read as nothing but can trip the voice.
        s = s.replacingOccurrences(of: #"[•·▪▸►◦‣⁃■□▶︎✓✔✗✘☐☑︎│┃─━┌┐└┘├┤]"#, with: " ", options: .regularExpression)
        return s
    }

    /// Splits text into sentence-sized chunks for streaming synthesis. Long
    /// sentences are broken at punctuation so the first audio starts quickly.
    public static func chunks(_ text: String, maxLength: Int = 220, firstMaxLength: Int = 60) -> [String] {
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

extension TextUnits {
    /// Widens a paragraph with the `before` paragraphs above it and `after`
    /// below it (`after` < 0 means to the end). Only real paragraphs (≥ `minLength`
    /// characters) count; headings and short lines between them come along.
    public static func expand(current: String, before: String, after: String,
                              paragraphsBefore: Int, paragraphsAfter: Int, minLength: Int = 30) -> String {
        func lines(_ s: String) -> [String] {
            s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        var head: [String] = []
        if paragraphsBefore > 0 {
            var count = 0
            for line in lines(before).reversed() {
                head.insert(line, at: 0)
                if line.count >= minLength { count += 1 }
                if count == paragraphsBefore { break }
            }
        }
        var tail: [String] = []
        if paragraphsAfter != 0 {
            var count = 0
            for line in lines(after) {
                if paragraphsAfter > 0, count == paragraphsAfter, line.count >= minLength { break }
                tail.append(line)
                if line.count >= minLength { count += 1 }
            }
            // Don't end on a dangling heading.
            while paragraphsAfter > 0, let last = tail.last, last.count < minLength { tail.removeLast() }
        }
        return (head + [current.trimmingCharacters(in: .whitespacesAndNewlines)] + tail).joined(separator: "\n")
    }
}

/// A word the voice gets wrong and how to say it instead.
public struct Pronunciation: Codable, Hashable, Sendable, Identifiable {
    public var word: String
    public var say: String
    public var id: String { word }
    public init(word: String, say: String) { self.word = word; self.say = say }
}

extension TextPrep {
    /// Replaces whole words (case-insensitive) with how they should be said.
    public static func apply(_ fixes: [Pronunciation], to text: String) -> String {
        fixes.reduce(text) { s, fix in
            let word = fix.word.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { return s }
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])"
            return s.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: fix.say),
                                          options: [.regularExpression, .caseInsensitive])
        }
    }

    /// Chunks plus the paragraph each one starts in (for skipping by paragraph).
    public static func chunksWithParagraphs(_ text: String) -> [(text: String, paragraph: Int)] {
        pieces(text, technical: .read).map { ($0.text, $0.paragraph) }
    }

    /// What to do with code, commands, file paths and tool-call lines.
    public enum TechnicalText: String, CaseIterable, Codable, Sendable {
        case fast, skip, read

        public var title: String {
            switch self {
            case .fast: "Read them very fast, with long paths shortened"
            case .skip: "Skip them (just say “code”)"
            case .read: "Read them like everything else"
            }
        }
    }

    /// One piece to speak: its text, the paragraph it starts in, and whether
    /// it's technical (to be read at the fast speed).
    public struct Piece: Equatable, Sendable {
        public var text: String
        public var paragraph: Int
        public var technical: Bool
    }

    /// Chunks with code and commands handled as asked. Consecutive technical
    /// lines become one block; when skipped, the block is just "Code."
    public static func pieces(_ text: String, technical mode: TechnicalText) -> [Piece] {
        var out: [Piece] = []
        var lastWasSkippedCode = false
        for (i, line) in text.components(separatedBy: "\n").filter({ !$0.isEmpty }).enumerated() {
            guard mode != .read, isTechnical(line) else {
                // A short first piece makes reading start sooner (~0.3 s less).
                out += chunks(line, firstMaxLength: out.isEmpty ? 60 : 220).map { Piece(text: $0, paragraph: i, technical: false) }
                lastWasSkippedCode = false
                continue
            }
            if mode == .skip {
                if !lastWasSkippedCode { out.append(Piece(text: "Code.", paragraph: i, technical: false)) }
                lastWasSkippedCode = true
                continue
            }
            let spoken = speakableCode(line)
            guard spoken.rangeOfCharacter(from: .alphanumerics) != nil else { continue }
            out += split(spoken, limit: 220).map { Piece(text: $0, paragraph: i, technical: true) }
        }
        return out
    }

    private static let commands: Set<String> = [
        "git", "npm", "npx", "yarn", "pnpm", "bun", "cd", "ls", "cat", "grep", "rg", "sed", "awk", "find", "curl", "wget",
        "sudo", "brew", "pip", "pip3", "python", "python3", "node", "deno", "swift", "xcodebuild", "xcrun", "docker",
        "kubectl", "ssh", "scp", "rsync", "rm", "mv", "cp", "mkdir", "touch", "chmod", "chown", "echo", "export", "make",
        "cargo", "go", "uv", "gh", "defaults", "pkill", "killall", "ps", "tail", "head", "launchctl", "codesign", "ditto",
        "osascript", "sh", "bash", "zsh", "source", "tar", "unzip", "jq", "wc", "sort", "diff", "systemctl", "journalctl",
        "gradle", "gradlew", "./gradlew", "adb", "flutter", "pod", "vim", "nano", "tmux", "kill", "lsof", "env", "which",
    ]

    /// Claude / agent tool rows: "Ran 3 commands", "Read TextPrep.swift", "Edited AppDelegate.swift".
    private static let toolVerbs: Set<String> = [
        "ran", "running", "read", "reading", "edited", "editing", "wrote", "writing", "searched", "searching",
        "listed", "created", "updated", "fetched", "called", "viewed", "opened", "explored", "grepped", "globbed",
    ]

    /// True for lines of code, shell commands, file paths, logs and tool rows:
    /// text that's there to look at, not to listen to.
    public static func isTechnical(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { return false }
        if t.hasPrefix("$ ") || t.hasPrefix("% ") || t.hasPrefix(">>> ") || t.hasPrefix("#!") { return true }
        let words = t.split(separator: " ").map(String.init)
        let first = words.first?.lowercased() ?? ""
        let endsLikeProse = t.last.map { ".!?:”\"".contains($0) } ?? false
        // Shell commands: a known program, then flags, paths or arguments.
        if commands.contains(first), words.count >= 2, !endsLikeProse || t.contains(" -") || t.contains("/") { return true }
        // Tool-call rows, which are short and never end like a sentence.
        if toolVerbs.contains(first), !endsLikeProse, t.count < 140,
           t.range(of: #"\b(commands?|files?|lines?|results?)\b|[\w-]+\.\w{1,6}\b|/"#, options: .regularExpression) != nil { return true }
        // Mostly symbols: code, JSON, regexes, logs.
        let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        let symbols = t.unicodeScalars.filter { "{}[]()<>=;$|\\`_*#@&~^/:\"'".unicodeScalars.contains($0) }.count
        if t.count > 6, Double(symbols) > Double(max(letters, 1)) * 0.22 { return true }
        // Code shapes: calls, assignments, declarations, arrows.
        if t.range(of: #"^(let|var|const|func|def|class|struct|enum|import|return|if|for|while|public|private|static|async|await|fn|val|guard|case|switch)\b.*[({=:;]"#,
                   options: .regularExpression) != nil { return true }
        if t.range(of: #"[\w\])]\.[a-zA-Z_]\w*\(|\w+\(.*\)\s*[;{]?$|\s=>\s|->\s|\s:=\s|==|!=|&&|\|\|"#, options: .regularExpression) != nil,
           words.count <= 14, !endsLikeProse { return true }
        // A bare path or file name on its own line.
        if words.count <= 2, t.range(of: #"^[~./\w-]*/[\w./-]+$|^[\w-]+\.(swift|py|js|ts|tsx|json|md|sh|yml|yaml|toml|kt|java|go|rs|c|h|m|plist|txt|log|html|css)$"#,
                                     options: .regularExpression) != nil { return true }
        return false
    }

    /// Technical text made quick to hear: paths shortened to the file name,
    /// symbols and punctuation runs dropped, identifiers split into words.
    public static func speakableCode(_ line: String) -> String {
        var s = line
        // /Users/naman/…/Sources/Earshot/TextGrabber.swift → TextGrabber.swift
        s = s.replacingOccurrences(of: #"(?:~|\.{1,2})?(?:/[\w.@-]+)+/([\w.@-]+)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[{}\[\]()<>=;$|\\`*#@&~^"'%+]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<=\w)_(?=\w)"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<=[a-z])(?=[A-Z])"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }
}

/// Finds the sentence / paragraph / rest-of-text around a character index.
public enum TextUnits {
    public enum Unit: Sendable { case sentence, paragraph, fromHere, section, all }

    public static func range(of unit: Unit, in text: String, at offset: Int) -> NSRange {
        let ns = text as NSString
        let i = max(0, min(offset, max(ns.length - 1, 0)))
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        switch unit {
        case .all:
            return NSRange(location: 0, length: ns.length)
        case .section:
            // Plain text has no markup: a heading is a short line without end punctuation.
            func isHeading(_ r: NSRange) -> Bool {
                let line = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
                return !line.isEmpty && line.count < 80 && !".!?:;,".contains(line.last!)
            }
            var start = ns.paragraphRange(for: NSRange(location: i, length: 0))
            while start.location > 0, !isHeading(start) {
                start = ns.paragraphRange(for: NSRange(location: start.location - 1, length: 0))
            }
            var end = ns.paragraphRange(for: NSRange(location: i, length: 0))
            while NSMaxRange(end) < ns.length {
                let next = ns.paragraphRange(for: NSRange(location: NSMaxRange(end), length: 0))
                if isHeading(next) { break }
                end = next
            }
            return NSRange(location: start.location, length: NSMaxRange(end) - start.location)
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
