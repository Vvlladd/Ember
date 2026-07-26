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
        #expect(MemoryContextBlock.formatHit(hit) == "From 'Trip' — the user said: trip to paris")
    }

    @Test func formatHitAssistantRole() {
        let e = MockEmbedder()
        let rec = MemoryRecord(messageID: UUID(), conversationID: UUID(),
                               conversationTitle: "Code", role: .assistant,
                               text: "debugging swift code", vector: e.embed("debugging swift code")!)
        let hit = MemoryHit(record: rec, score: 1)
        #expect(MemoryContextBlock.formatHit(hit) == "From 'Code' — you (the assistant) said: debugging swift code")
    }

    /// Past QUESTIONS carry no facts — label them so the model can't read "What I like to eat?"
    /// as background information.
    @Test func formatHitUserQuestionIsLabeledAsQuestion() {
        let rec = MemoryRecord(messageID: UUID(), conversationID: UUID(),
                               conversationTitle: "Food", role: .user,
                               text: "What I like to eat?", vector: [])
        let hit = MemoryHit(record: rec, score: 1)
        #expect(MemoryContextBlock.formatHit(hit) == "From 'Food' — the user asked: What I like to eat?")
    }

    /// The header must frame snippets as facts ABOUT the user and pin the answering voice —
    /// on-device the 3B model otherwise mirrors "You: I like apples" back in first person.
    @Test func wrapHeaderFramesUserFactsAndVoice() {
        let block = MemoryContextBlock.wrap([hit("likes apples", score: 0.9)])
        #expect(block.contains("Background about the user from earlier chats"))
        #expect(block.contains("never speak as them"))
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

    private func hit(_ text: String, score: Float, source: MemoryRecord.Source = .conversation) -> MemoryHit {
        MemoryHit(record: MemoryRecord(
            messageID: UUID(), conversationID: UUID(), conversationTitle: "Past",
            role: .user, text: text, vector: [], source: source), score: score)
    }

    @Test func wrapLimitsToMaxHits() {
        let hits = [hit("first", score: 0.9), hit("second", score: 0.8), hit("third", score: 0.7),
                    hit("fourth", score: 0.6)]
        let block = MemoryContextBlock.wrap(hits, maxHits: 2, maxCharsPerHit: 240)
        #expect(block.contains("first"))
        #expect(block.contains("second"))
        #expect(!block.contains("third"))
        #expect(!block.contains("fourth"))
    }

    /// Near-identical snippets from different conversations must not burn injection slots —
    /// on-device the same past question was injected twice ("Where I told you I want to travel?"
    /// from 'Paris Travel Plans' AND 'Travel Plans') while distinct facts were pushed out.
    @Test func wrapCollapsesNearDuplicateHits() {
        let hits = [hit("Where I told you I want to travel?", score: 0.9),
                    hit("Where I told you I want to travel?", score: 0.8),
                    hit("wants to travel to Ghent and Lisbon", score: 0.7)]
        let block = MemoryContextBlock.wrap(hits, maxHits: 2, maxCharsPerHit: 240)
        let bullets = block.components(separatedBy: "\n- ").count - 1
        #expect(bullets == 2)
        #expect(block.contains("Ghent"))   // the dup slot went to a distinct fact instead
    }

    @Test func wrapCollapsesContainedShorterHit() {
        let hits = [hit("trip to paris in september with friends", score: 0.9),
                    hit("trip to paris", score: 0.8),           // >=3-word fragment of the first
                    hit("has a golden retriever named Rex", score: 0.7)]
        let block = MemoryContextBlock.wrap(hits, maxHits: 3, maxCharsPerHit: 240)
        let bullets = block.components(separatedBy: "\n- ").count - 1
        #expect(bullets == 2)
        #expect(block.contains("golden retriever"))
    }

    @Test func wrapKeepsShortDistinctHits() {
        // One/two-word texts never containment-match (>=3-word rule) — distinct short facts all
        // survive, matching saveNoteIfNovel's calibration.
        let hits = [hit("likes teal", score: 0.9), hit("likes tea", score: 0.8)]
        let block = MemoryContextBlock.wrap(hits, maxHits: 3, maxCharsPerHit: 240)
        let bullets = block.components(separatedBy: "\n- ").count - 1
        #expect(bullets == 2)
    }

    @Test func wrapTruncatesEachHit() {
        let long = String(repeating: "z", count: 300)
        let block = MemoryContextBlock.wrap([hit(long, score: 0.9)], maxHits: 3, maxCharsPerHit: 50)
        #expect(block.contains("\u{2026}"))
        #expect(!block.contains(long))
    }

    @Test func wrapDefaultsMatchCanonical() {
        // Zero-arg-defaulted overload still works (maxHits 3, maxCharsPerHit 240).
        let hits = (0..<5).map { hit("fact\($0)", score: Float(5 - $0) / 5) }
        let block = MemoryContextBlock.wrap(hits)
        #expect(block.contains("fact0"))
        #expect(block.contains("fact2"))
        #expect(!block.contains("fact3"))   // capped at 3
    }

    @Test func augmentPrependsLimitedBlock() {
        let hits = [hit("alpha", score: 0.9), hit("beta", score: 0.8), hit("gamma", score: 0.7),
                    hit("delta", score: 0.6)]
        let out = MemoryContextBlock.augment(prompt: "What now?", with: hits,
                                             maxHits: 2, maxCharsPerHit: 240)
        #expect(out.contains("alpha"))
        #expect(out.contains("beta"))
        #expect(!out.contains("gamma"))
        #expect(out.hasSuffix("What now?"))
    }

    @Test func augmentWithNoHitsReturnsPrompt() {
        #expect(MemoryContextBlock.augment(prompt: "hi", with: [], maxHits: 3, maxCharsPerHit: 240) == "hi")
    }

    @Test func augmentThenSplitStillRoundTripsShortHits() {
        // Short hits never trigger truncation, so the existing split() contract is preserved.
        let hits = [hit("User loves Lisbon", score: 0.9), hit("User has a dog", score: 0.8)]
        let augmented = MemoryContextBlock.augment(prompt: "Where to?", with: hits)
        let parts = MemoryContextBlock.split(augmented)
        #expect(parts.memory?.contains("User loves Lisbon") == true)
        #expect(parts.userText == "Where to?")   // CORRECTED: split returns .userText, not .prompt
    }
}
