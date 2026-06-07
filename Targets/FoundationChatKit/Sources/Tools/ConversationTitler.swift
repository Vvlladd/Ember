import Foundation
import FoundationModels

/// Generates a short conversation title via guided generation, in a throwaway session so it
/// never pollutes the chat transcript. Returns nil on any failure (caller falls back to the
/// deterministic title).
enum ConversationTitler {
    @Generable(description: "A short, descriptive chat title.")
    struct ConversationTitle {
        @Guide(description: "A concise 3-5 word title for the conversation topic")
        var title: String
    }

    @MainActor
    static func generate(from seed: TitleSeed) async -> String? {
        let session = LanguageModelSession(
            instructions: "You write very short, descriptive chat titles. No quotes, 3-5 words.")
        let prompt = """
            Summarize this conversation's topic as a 3-5 word title.
            User: \(seed.userText)
            Assistant: \(seed.assistantText)
            """
        do {
            let response = try await session.respond(
                to: prompt,
                generating: ConversationTitle.self,
                options: UtilityGenerationOptions.title)
            let title = clampTitle(response.content.title)
            return title.isEmpty ? nil : title
        } catch {
            return nil
        }
    }

    /// Belt-and-suspenders cap: trim whitespace and keep at most 5 words, so a chatty model
    /// can't blow past the intended title length even if the guide is loosely honored.
    static func clampTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        return words.prefix(5).joined(separator: " ")
    }
}
