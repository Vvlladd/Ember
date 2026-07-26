import Foundation
import FoundationModels
import os

/// Extracts durable USER facts from a completed exchange via guided generation, in a throwaway
/// session so it never pollutes the chat transcript. Returns nil on any failure (caller falls
/// back to saving nothing). An empty array means "nothing worth remembering".
enum MemoryExtractor {
    @Generable(description: "Durable facts about the USER extracted from one chat exchange.")
    struct ExtractedMemories {
        @Guide(description: "One durable fact about the USER (a stable preference, plan, or personal detail). Omit if nothing qualifies. At most 5.", .maximumCount(5))
        var facts: [String]
    }

    @MainActor
    static func generate(userText: String) async -> [String]? {
        // USER text only: feeding the assistant's reply in as well made the model launder its own
        // suggestions into "user facts" (on-device it saved "likes exploring different European
        // cities" — the assistant's idea, not the user's).
        let session = LanguageModelSession(
            instructions: """
                You extract durable facts ABOUT THE USER from one chat message, for long-term memory.

                Rules:
                - Only stable facts about the USER: preferences, plans, goals, personal details \
                (e.g. "wants to travel to Ghent in December", "likes the color red").
                - Write each fact in the THIRD PERSON about the user, as a short statement. Never \
                start a fact with "I".
                - Use ONLY what the user wrote. Never introduce places, names, or details the \
                user did not write themselves.
                - IGNORE: greetings, small talk, acknowledgements, and bare questions.
                - If nothing durable qualifies, return an empty list.
                """)
        let prompt = """
            From this user message, list durable facts about the user (third person). \
            If there are none, return an empty list.
            User: \(userText)
            """
        do {
            let response = try await session.respond(
                to: prompt,
                generating: ExtractedMemories.self,
                options: UtilityGenerationOptions.extraction)
            let facts = durableFacts(from: response.content.facts, groundedIn: userText)
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

    /// Hard cap on facts kept per exchange — mirrors the `.maximumCount(5)` guide so a model
    /// that over-produces can't flood the note store on a single turn.
    static let maxFactsPerExchange = 5

    /// Pure post-filter on extracted facts: trims, drops empties, greetings/acknowledgements,
    /// assistant-self-referential lines, and facts containing UNGROUNDED proper nouns, then caps
    /// to `maxFactsPerExchange`. Deterministic so it can be unit-tested off-device.
    static func durableFacts(from raw: [String], groundedIn userText: String) -> [String] {
        Array(raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { fact in
                let normalized = fact.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
                if greetings.contains(normalized) { return false }
                let lower = fact.lowercased()
                if assistantMarkers.contains(where: { lower.contains($0) }) { return false }
                return isGrounded(fact, in: userText)
            }
            .prefix(maxFactsPerExchange))
    }

    /// Case- and diacritic-insensitive fold, so "Junín" matches "junin" but not "juns".
    private static func folded(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    /// Entity-grounding guard: every capitalized token AFTER the fact's first word (candidate
    /// proper noun) must literally appear in what the user typed. The model can rephrase, but it
    /// cannot INVENT places or names — on-device it turned the Romanian fragment "Juns în Paris?"
    /// into a saved fact about Junín, Peru. The first token is exempt (sentence casing).
    static func isGrounded(_ fact: String, in userText: String) -> Bool {
        let foldedUser = folded(userText)
        let tokens = fact.split(whereSeparator: { !$0.isLetter && $0 != "-" }).dropFirst()
        return tokens.allSatisfy { token in
            guard let first = token.first, first.isUppercase else { return true }
            return foldedUser.contains(folded(String(token)))
        }
    }
}
