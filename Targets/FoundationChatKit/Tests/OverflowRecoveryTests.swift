import Testing
@testable import FoundationChatKit

struct OverflowRecoveryTests {
    @Test func keepsFirstAndLast() {
        let entries = [
            ContextEntry(kind: .userPrompt, text: "first"),
            ContextEntry(kind: .modelResponse, text: "mid1"),
            ContextEntry(kind: .userPrompt, text: "mid2"),
            ContextEntry(kind: .modelResponse, text: "last"),
        ]
        #expect(OverflowRecovery.condense(entries).map(\.text) == ["first", "last"])
    }

    @Test func singleEntryUnchanged() {
        let entries = [ContextEntry(kind: .userPrompt, text: "only")]
        #expect(OverflowRecovery.condense(entries).map(\.text) == ["only"])
    }

    @Test func emptyStaysEmpty() {
        #expect(OverflowRecovery.condense([]).isEmpty)
    }
}
