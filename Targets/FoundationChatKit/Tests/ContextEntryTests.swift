import Testing
import Foundation
@testable import FoundationChatKit

struct ContextEntryTests {
    @Test func entryHoldsKindAndText() {
        let e = ContextEntry(kind: .userPrompt, text: "How do I parse JSON?")
        #expect(e.kind == .userPrompt)
        #expect(e.text == "How do I parse JSON?")
        #expect(e.isInWindow == true)
    }
    @Test func outOfWindowFlag() {
        let e = ContextEntry(kind: .modelResponse, text: "old", isInWindow: false)
        #expect(e.isInWindow == false)
    }
}
