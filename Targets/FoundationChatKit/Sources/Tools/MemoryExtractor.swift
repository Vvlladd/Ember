import Foundation
import FoundationModels
import os

/// Extracts durable USER facts from a completed exchange via guided generation, in a throwaway
/// session so it never pollutes the chat transcript. Returns nil on any failure (caller falls
/// back to saving nothing). An empty array means "nothing worth remembering".
enum MemoryExtractor {
    @Generable
    struct ExtractedMemories {
        @Guide(description: "One durable fact about the USER (a stable preference, plan, or personal detail). Omit if nothing qualifies.")
        var facts: [String]
    }

    @MainActor
    static func generate(userText: String, assistantText: String) async -> [String]? {
        let session = LanguageModelSession(
            instructions: """
                Extract only stable, durable facts ABOUT THE USER from the latest exchange \
                (preferences, plans, personal details). Ignore transient chit-chat, the \
                assistant's own statements, and questions. Return nothing when none qualify. \
                If the user only asked a question or made small talk, return no facts.
                """)
        let prompt = """
            Extract durable facts about the user from this exchange.
            User: \(userText)
            Assistant: \(assistantText)
            """
        do {
            let response = try await session.respond(to: prompt, generating: ExtractedMemories.self)
            let facts = response.content.facts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            EmberLog.extraction.info("MemoryExtractor: generated \(facts.count, privacy: .public) fact(s): [\(facts.joined(separator: " || "), privacy: .public)]")
            return facts
        } catch {
            EmberLog.extraction.error("MemoryExtractor: generation FAILED — \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
