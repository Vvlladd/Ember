import Testing
import Foundation
@testable import FoundationChatKit

/// Tests the PURE post-processing of extracted facts (no on-device model). The generation itself
/// is exercised on-device; here we lock the deterministic filtering that keeps junk out of memory.
struct MemoryExtractorTests {
    // MARK: - Proper-noun grounding (entities the user never typed are hallucinations)

    /// On-device regression: the extractor turned the Romanian fragment "Juns în Paris?" into
    /// "wants to travel to Junín" — a city the user never mentioned.
    @Test func groundingDropsInventedProperNouns() {
        let kept = MemoryExtractor.durableFacts(from: ["wants to travel to Junín"],
                                                groundedIn: "Juns în Paris?")
        #expect(kept.isEmpty)
    }

    @Test func groundingKeepsEntitiesTheUserTyped() {
        let kept = MemoryExtractor.durableFacts(from: ["wants to travel to Ghent in December"],
                                                groundedIn: "I want to travel to Ghent in December")
        #expect(kept == ["wants to travel to Ghent in December"])
    }

    @Test func groundingIsDiacriticAndCaseInsensitive() {
        let kept = MemoryExtractor.durableFacts(from: ["loves São Paulo"],
                                                groundedIn: "sao paulo is amazing")
        #expect(kept == ["loves São Paulo"])
    }

    @Test func groundingIgnoresFactInitialCapitalAndEntityFreeFacts() {
        // A capitalized first word is sentence casing, not an entity; entity-free facts always pass.
        let kept = MemoryExtractor.durableFacts(from: ["Wants to travel in december"],
                                                groundedIn: "i want to travel in december")
        #expect(kept == ["Wants to travel in december"])
    }

    @Test func dropsGreetingsAndTrivialFragments() {
        let raw = ["Hello", "  hi ", "Thanks!", "ok", "Yes", "  ", "No."]
        #expect(MemoryExtractor.durableFacts(from: raw, groundedIn: raw.joined(separator: " ")).isEmpty)
    }

    @Test func keepsRealDurableFacts() {
        let raw = ["wants to travel to Ghent in December", "likes the color red"]
        let kept = MemoryExtractor.durableFacts(from: raw, groundedIn: raw.joined(separator: " "))
        #expect(kept == ["wants to travel to Ghent in December", "likes the color red"])
    }

    @Test func trimsAndDropsEmpties() {
        let raw = ["  wants to rent a boat  ", "", "   "]
        #expect(MemoryExtractor.durableFacts(from: raw, groundedIn: raw.joined(separator: " ")) == ["wants to rent a boat"])
    }

    @Test func dropsAssistantSelfReferentialFraming() {
        // The small model sometimes saves its OWN offer as a "user fact"; drop the giveaways.
        let raw = ["I'm interested in planning or suggesting destinations based on my interests",
                   "I can help you plan your trip"]
        #expect(MemoryExtractor.durableFacts(from: raw, groundedIn: raw.joined(separator: " ")).isEmpty)
    }

    @Test func durableFactsCapsToFive() {
        let raw = [
            "User likes the color red",
            "User is planning a trip to Lisbon in December",
            "User has a dog named Pixel",
            "User works as an iOS engineer",
            "User prefers tea over coffee",
            "User wants to learn Portuguese",   // 6th — must be dropped
            "User is vegetarian"                // 7th — must be dropped
        ]
        let kept = MemoryExtractor.durableFacts(from: raw, groundedIn: raw.joined(separator: " "))
        #expect(kept.count == 5)
        #expect(kept.first == "User likes the color red")
        #expect(!kept.contains("User wants to learn Portuguese"))
    }

    @Test func durableFactsStillFiltersAndStaysUnderCap() {
        let raw = ["hello", "User likes hiking", "I can help you with that"]
        let kept = MemoryExtractor.durableFacts(from: raw, groundedIn: raw.joined(separator: " "))
        #expect(kept == ["User likes hiking"])
    }
}
