import EarshotCore
import FoundationModels
import Foundation

/// Short spoken summaries from Apple's on-device model (Apple Intelligence).
/// Free, offline; returns nil when the model isn't available.
@MainActor
enum Summarizer {
    static var available: Bool {
        guard #available(macOS 26, *) else { return false }
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static func summarize(_ text: String, from sender: String) async -> String? {
        guard #available(macOS 26, *), available else { return nil }
        let session = LanguageModelSession(instructions: """
            You turn a message into one or two short sentences to be read aloud to its recipient. \
            Speak to the listener in the second person ("Rahul asks you to…"). \
            Keep names, times, dates, amounts and codes exactly. No preamble, no quotes.
            """)
        do {
            let response = try await session.respond(to: "From \(sender):\n\(text)")
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            Log.write("summarize failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// The model sees ~4k tokens, so long pages are summarized section by
    /// section and the section summaries combined.
    static let sectionSize = 7000
    static let maxSections = 6

    /// A 3–5 sentence spoken summary of a page. `progress(done, total)` reports sections.
    static func summarizePage(_ text: String, progress: @escaping (Int, Int) -> Void) async -> String? {
        guard #available(macOS 26, *), available else { return nil }
        let sections = Array(TextPrep.sections(text, size: sectionSize).prefix(maxSections))
        guard !sections.isEmpty else { return nil }
        let rules = "Lead with the main point. Keep key names, numbers and dates. Ignore menus, ads, cookie notices and links. Plain sentences only, no lists, no preamble."
        if sections.count == 1 {
            progress(0, 1)
            return await respond("Summarize this page for someone listening, in 3 to 5 short sentences. \(rules)", sections[0])
        }
        var partials: [String] = []
        for (i, section) in sections.enumerated() {
            progress(i, sections.count)
            if let s = await respond("This is part \(i + 1) of \(sections.count) of a page. Summarize it in 2 or 3 short sentences. \(rules)", section) {
                partials.append(s)
            }
        }
        guard !partials.isEmpty else { return nil }
        progress(sections.count, sections.count)
        return await respond("These are summaries of consecutive parts of one page. Merge them into one summary of 3 to 5 short sentences for someone listening. \(rules)",
                             partials.joined(separator: "\n"))
    }

    @available(macOS 26, *)
    private static func respond(_ instructions: String, _ text: String) async -> String? {
        do {
            let session = LanguageModelSession(instructions: instructions)
            let r = try await session.respond(to: text, options: GenerationOptions(temperature: 0.3))
            return TextPrep.dropPreamble(r.content)
        } catch {
            Log.write("summarize page failed: \(error)")
            return nil
        }
    }
}
