import Testing
import Foundation
import FoundationModels
@testable import FoundationChatKit

/// Tests the transcript -> ContextEntry projection, focusing on the auto-RAG split: an augmented
/// `.prompt` entry must surface as a `.retrievedMemory` entry followed by a clean `.userPrompt`.
///
/// These build a REAL `Transcript`: the `Transcript(entries:)`, `Transcript.Prompt(segments:)`,
/// `Transcript.TextSegment(content:)` and `Transcript.Entry.prompt(_:)` initializers are public
/// (iOS/macOS 26.0+), so no off-device session is needed to exercise the mapper.
struct TranscriptMappingTests {
    private func promptTranscript(_ text: String) -> Transcript {
        let segment = Transcript.Segment.text(Transcript.TextSegment(content: text))
        let prompt = Transcript.Prompt(segments: [segment])
        return Transcript(entries: [.prompt(prompt)])
    }

    private func makeHit() -> MemoryHit {
        let record = MemoryRecord(messageID: UUID(), conversationID: UUID(),
                                  conversationTitle: "Trip", role: .user,
                                  text: "trip to paris", vector: [1, 0, 0])
        return MemoryHit(record: record, score: 0.9)
    }

    @Test func augmentedPromptSplitsIntoMemoryThenUserPrompt() {
        let augmented = MemoryContextBlock.augment(prompt: "hello", with: [makeHit()])
        let entries = TranscriptMapping.entries(from: promptTranscript(augmented))

        #expect(entries.count == 2)
        #expect(entries.first?.kind == .retrievedMemory)
        #expect(entries.first?.text.contains("trip to paris") == true)
        #expect(entries.last?.kind == .userPrompt)
        #expect(entries.last?.text == "hello")
    }

    @Test func plainPromptMapsToSingleUserPrompt() {
        let entries = TranscriptMapping.entries(from: promptTranscript("just hello"))

        #expect(entries.count == 1)
        #expect(entries.first?.kind == .userPrompt)
        #expect(entries.first?.text == "just hello")
    }
}
