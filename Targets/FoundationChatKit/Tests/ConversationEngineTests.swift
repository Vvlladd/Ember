import Testing
import Foundation
@testable import FoundationChatKit

@MainActor
struct ConversationEngineTests {
    func makeEngine(_ provider: MockModelProvider) -> ConversationEngine {
        ConversationEngine(provider: provider, settings: GenerationSettings(instructions: "sys"),
                           now: { Date(timeIntervalSince1970: 0) })
    }

    @Test func sendProducesOneGrowingAssistantBubble() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["He", "Hello", "Hello!"]
        let engine = makeEngine(provider)
        await engine.send("hi")
        #expect(engine.messages.map(\.role) == [.user, .assistant])
        #expect(engine.messages.last?.text == "Hello!")
        #expect(engine.messages.last?.isStreaming == false)
        #expect(engine.isResponding == false)
    }

    @Test func budgetUpdatesAfterTurn() async {
        let provider = MockModelProvider()
        provider.exactCounts = true
        provider.session.scriptedSnapshots = ["abcd"]
        let engine = makeEngine(provider)
        await engine.send("xy")
        // instructions "sys"(3) + user "xy"(2) + assistant "abcd"(4) = 9
        #expect(engine.budget.usedTokens == 9)
        #expect(engine.budget.isExact == true)
    }

    @Test func overflowTriggersRecoveryAndNotice() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["partial"]
        provider.session.scriptedError = ChatError.contextOverflow
        provider.session.errorAfter = 1
        let engine = makeEngine(provider)
        await engine.send("hi")
        #expect(engine.messages.contains { $0.role == .systemNotice })
        #expect(engine.lastError == nil)
    }

    @Test func guardrailErrorIsSurfaced() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["x"]
        provider.session.scriptedError = ChatError.guardrailViolation
        provider.session.errorAfter = 1
        let engine = makeEngine(provider)
        await engine.send("hi")
        #expect(engine.lastError == .guardrailViolation)
    }

    @Test func ignoresSendWhileResponding() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["done"]
        let engine = makeEngine(provider)
        engine.isResponding = true
        await engine.send("hi")
        #expect(engine.messages.isEmpty)
    }
}
