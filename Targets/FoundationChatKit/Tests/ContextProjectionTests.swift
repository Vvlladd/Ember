import Testing
import Foundation
@testable import FoundationChatKit

struct ContextProjectionTests {
    let now = { Date(timeIntervalSince1970: 0) }

    @Test func keepsOnlyPromptsAndResponsesInOrder() {
        let entries = [
            ContextEntry(kind: .instructions, text: "system"),
            ContextEntry(kind: .userPrompt, text: "hi"),
            ContextEntry(kind: .modelResponse, text: "hello"),
            ContextEntry(kind: .toolOutput, text: "{}"),
        ]
        let msgs = ContextProjection.bubbles(from: entries, now: now)
        #expect(msgs.map(\.role) == [.user, .assistant])
        #expect(msgs.map(\.text) == ["hi", "hello"])
    }

    @Test func emptyWhenNoConversational() {
        let msgs = ContextProjection.bubbles(from: [ContextEntry(kind: .instructions, text: "x")], now: now)
        #expect(msgs.isEmpty)
    }
}
