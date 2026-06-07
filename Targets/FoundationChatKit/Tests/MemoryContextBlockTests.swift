import Testing
import Foundation
@testable import FoundationChatKit

@MainActor
struct MemoryContextBlockTests {
    private func hits() -> [MemoryHit] {
        let e = MockEmbedder()
        return [
            MemoryHit(record: MemoryRecord(messageID: UUID(), conversationID: UUID(),
                                           conversationTitle: "Trip", role: .user,
                                           text: "trip to paris", vector: e.embed("trip to paris")!),
                      score: 0.9),
            MemoryHit(record: MemoryRecord(messageID: UUID(), conversationID: UUID(),
                                           conversationTitle: "Code", role: .assistant,
                                           text: "debugging swift code", vector: e.embed("debugging swift code")!),
                      score: 0.6),
        ]
    }

    @Test func augmentThenSplitRoundTrips() {
        let prompt = "what's my plan?"
        let augmented = MemoryContextBlock.augment(prompt: prompt, with: hits())
        let parts = MemoryContextBlock.split(augmented)
        #expect(parts.userText == prompt)
        #expect(parts.memory != nil)
        #expect(parts.memory!.contains("trip to paris"))
        #expect(parts.memory!.contains("Trip"))
        // memory payload is the inner block, WITHOUT marker lines
        #expect(!parts.memory!.contains("\u{27E6}memory\u{27E7}"))
        #expect(!parts.memory!.contains("\u{27E6}/memory\u{27E7}"))
    }

    @Test func augmentWithEmptyReturnsPromptUnchanged() {
        let prompt = "just a question"
        #expect(MemoryContextBlock.augment(prompt: prompt, with: []) == prompt)
    }

    @Test func splitOfPlainPromptReturnsNilMemory() {
        let prompt = "no markers here"
        let parts = MemoryContextBlock.split(prompt)
        #expect(parts.memory == nil)
        #expect(parts.userText == prompt)
    }

    @Test func formatHitUserRole() {
        let e = MockEmbedder()
        let rec = MemoryRecord(messageID: UUID(), conversationID: UUID(),
                               conversationTitle: "Trip", role: .user,
                               text: "trip to paris", vector: e.embed("trip to paris")!)
        let hit = MemoryHit(record: rec, score: 1)
        #expect(MemoryContextBlock.formatHit(hit) == "From 'Trip' — You: trip to paris")
    }

    @Test func formatHitAssistantRole() {
        let e = MockEmbedder()
        let rec = MemoryRecord(messageID: UUID(), conversationID: UUID(),
                               conversationTitle: "Code", role: .assistant,
                               text: "debugging swift code", vector: e.embed("debugging swift code")!)
        let hit = MemoryHit(record: rec, score: 1)
        #expect(MemoryContextBlock.formatHit(hit) == "From 'Code' — Assistant: debugging swift code")
    }

    @Test func truncateLeavesShortTextUntouched() {
        #expect(MemoryContextBlock.truncate("short fact", maxChars: 240) == "short fact")
    }

    @Test func truncateClampsLongTextWithEllipsis() {
        let long = String(repeating: "a", count: 300)
        let out = MemoryContextBlock.truncate(long, maxChars: 240)
        #expect(out.count == 241)            // 240 chars + the single ellipsis Character (U+2026)
        #expect(out.hasSuffix("\u{2026}"))
    }

    @Test func truncateAtExactBoundaryIsUnchanged() {
        let exact = String(repeating: "b", count: 240)
        #expect(MemoryContextBlock.truncate(exact, maxChars: 240) == exact)
    }

    @Test func truncateTrimsTrailingWhitespaceBeforeEllipsis() {
        let text = String(repeating: "c", count: 238) + "   xyz"   // 244 chars
        let out = MemoryContextBlock.truncate(text, maxChars: 240)
        #expect(out.hasSuffix("\u{2026}"))
        #expect(!out.contains("  \u{2026}"))   // no double-space before ellipsis
    }
}
