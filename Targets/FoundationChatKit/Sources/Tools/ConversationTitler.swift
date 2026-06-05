import Foundation
import FoundationModels

/// Generates a short conversation title via guided generation, in a throwaway session so it
/// never pollutes the chat transcript. Returns nil on any failure (caller falls back to the
/// deterministic title).
enum ConversationTitler {
    @Generable
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
            let response = try await session.respond(to: prompt, generating: ConversationTitle.self)
            let title = response.content.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : title
        } catch {
            return nil
        }
    }
}
