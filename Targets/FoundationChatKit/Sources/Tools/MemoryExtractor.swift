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
                You extract durable facts ABOUT THE USER from one chat exchange, for long-term memory.

                Rules:
                - Only stable facts about the USER: preferences, plans, goals, personal details \
                (e.g. "wants to travel to Ghent in December", "likes the color red").
                - Write each fact in the THIRD PERSON about the user, as a short statement. Never \
                start a fact with "I", and never describe what the assistant can do or offer.
                - IGNORE: greetings, small talk, acknowledgements, the user's questions, and \
                anything the ASSISTANT said about itself or its capabilities.
                - If nothing durable qualifies, return an empty list.
                """)
        let prompt = """
            From this exchange, list durable facts about the user (third person). \
            If there are none, return an empty list.
            User: \(userText)
            Assistant: \(assistantText)
            """
        do {
            let response = try await session.respond(to: prompt, generating: ExtractedMemories.self)
            let facts = durableFacts(from: response.content.facts)
            EmberLog.extraction.info("MemoryExtractor: kept \(facts.count, privacy: .public) of \(response.content.facts.count, privacy: .public) fact(s): [\(facts.joined(separator: " || "), privacy: .public)]")
            return facts
        } catch {
            EmberLog.extraction.error("MemoryExtractor: generation FAILED — \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Greetings / acknowledgements that are never durable facts (normalized to letters only).
    private static let greetings: Set<String> = [
        "hello", "hi", "hey", "thanks", "thank you", "ok", "okay", "yes", "no",
        "yep", "nope", "sure", "cool", "great", "nice"
    ]

    /// Substrings that betray ASSISTANT-authored text the small model wrongly saved as a user fact.
    private static let assistantMarkers: [String] = [
        "i can help", "help you", "happy to", "let me know", "feel free", "i'm here to",
        "i am here to", "assist you", "suggesting", "i can suggest", "i can provide",
        "i can offer", "based on my interests", "as an ai"
    ]

    /// Pure post-filter on extracted facts: trims, drops empties, greetings/acknowledgements, and
    /// assistant-self-referential lines. Deterministic so it can be unit-tested off-device.
    static func durableFacts(from raw: [String]) -> [String] {
        raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { fact in
                let normalized = fact.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
                if greetings.contains(normalized) { return false }
                let lower = fact.lowercased()
                if assistantMarkers.contains(where: { lower.contains($0) }) { return false }
                return true
            }
    }
}
