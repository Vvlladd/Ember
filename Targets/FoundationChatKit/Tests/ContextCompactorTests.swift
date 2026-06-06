import Testing
import Foundation
@testable import FoundationChatKit

@MainActor
struct ContextCompactorTests {
    private func entries(_ n: Int) -> [ContextEntry] {
        (0..<n).map { ContextEntry(kind: $0 % 2 == 0 ? .userPrompt : .modelResponse, text: "msg\($0)") }
    }
    @Test func summarizesOlderKeepsRecent() async {
        let p = MockModelProvider(); p.summarizeResult = "RECAP"
        let result = await ContextCompactor.compact(entries(10), keepingRecent: 4, using: p)
        #expect(result.count == 5)                       // 1 recap + 4 recent
        #expect(result.first?.kind == .instructions)
        #expect(result.first?.text.contains("RECAP") == true)
        #expect(result.last?.text == "msg9")
    }
    @Test func fallsBackToCondenseWhenSummaryNil() async {
        let p = MockModelProvider(); p.summarizeResult = nil
        let input = entries(10)
        let result = await ContextCompactor.compact(input, keepingRecent: 4, using: p)
        #expect(result == OverflowRecovery.condense(input))
    }
    @Test func shortInputUnchanged() async {
        let p = MockModelProvider(); p.summarizeResult = "RECAP"
        let input = entries(3)
        #expect(await ContextCompactor.compact(input, keepingRecent: 4, using: p) == input)
    }

    /// Recalled memory is mixed-provenance and re-injected fresh each turn, so it must NOT be folded
    /// into the instructions-channel recap. The summary the compactor builds should contain the
    /// older user/assistant text but NOT the `.retrievedMemory` entry's text.
    @Test func excludesRetrievedMemoryFromSummaryInput() async {
        let p = MockModelProvider(); p.summarizeResult = "RECAP"
        let older: [ContextEntry] = [
            ContextEntry(kind: .userPrompt, text: "USER_OLD"),
            ContextEntry(kind: .retrievedMemory, text: "SECRET_MEMORY"),
            ContextEntry(kind: .modelResponse, text: "ASSISTANT_OLD"),
        ]
        let recent = entries(4)
        _ = await ContextCompactor.compact(older + recent, keepingRecent: 4, using: p)
        let captured = p.capturedSummarizeInput ?? ""
        #expect(captured.contains("USER_OLD"))
        #expect(captured.contains("ASSISTANT_OLD"))
        #expect(!captured.contains("SECRET_MEMORY"))
    }
}
