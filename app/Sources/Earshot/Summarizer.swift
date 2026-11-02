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
}
