import Testing
import Foundation
@testable import FoundationChatKit

@MainActor
struct ExactBudgetTests {
    @Test func turnRefreshesToExactWhenAvailable() async {
        let provider = MockModelProvider()
        provider.exactAsyncCount = true
        provider.session.scriptedSnapshots = ["hello"]
        let engine = ConversationEngine(provider: provider,
                                        settings: GenerationSettings(instructions: "sys"),
                                        now: { Date(timeIntervalSince1970: 0) })
        await engine.send("hi")
        #expect(engine.budget.isExact == true)
        #expect(engine.budget.usedTokens > 0)
    }
    @Test func turnStaysEstimatedWhenExactUnavailable() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["hello"]
        let engine = ConversationEngine(provider: provider,
                                        settings: GenerationSettings(instructions: "sys"),
                                        now: { Date(timeIntervalSince1970: 0) })
        await engine.send("hi")
        #expect(engine.budget.isExact == false)
    }
}
