import Testing
import Foundation
@testable import FoundationChatKit

/// Tests the PURE post-processing of extracted facts (no on-device model). The generation itself
/// is exercised on-device; here we lock the deterministic filtering that keeps junk out of memory.
struct MemoryExtractorTests {
    @Test func dropsGreetingsAndTrivialFragments() {
        let raw = ["Hello", "  hi ", "Thanks!", "ok", "Yes", "  ", "No."]
        #expect(MemoryExtractor.durableFacts(from: raw).isEmpty)
    }

    @Test func keepsRealDurableFacts() {
        let raw = ["wants to travel to Ghent in December", "likes the color red"]
        let kept = MemoryExtractor.durableFacts(from: raw)
        #expect(kept == ["wants to travel to Ghent in December", "likes the color red"])
    }

    @Test func trimsAndDropsEmpties() {
        let raw = ["  wants to rent a boat  ", "", "   "]
        #expect(MemoryExtractor.durableFacts(from: raw) == ["wants to rent a boat"])
    }

    @Test func dropsAssistantSelfReferentialFraming() {
        // The small model sometimes saves its OWN offer as a "user fact"; drop the giveaways.
        let raw = ["I'm interested in planning or suggesting destinations based on my interests",
                   "I can help you plan your trip"]
        #expect(MemoryExtractor.durableFacts(from: raw).isEmpty)
    }
}
