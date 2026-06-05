import Testing
@testable import FoundationChatKit

struct AdvancedBudgetingTests {
    @Test func reservedReplyTokensDefaultAndCustom() {
        #expect(GenerationSettings().reservedReplyTokens == 512)
        #expect(GenerationSettings(reservedReplyTokens: 256).reservedReplyTokens == 256)
    }
    @Test func calculatorEstimateMatchesEstimator() {
        #expect(TokenBudgetCalculator().estimate("hello world") == TokenEstimator().estimate("hello world"))
    }
    @MainActor @Test func mockSummarizeReturnsScripted() async {
        let p = MockModelProvider()
        p.summarizeResult = "A short summary."
        #expect(await p.summarize("a long conversation") == "A short summary.")
        let q = MockModelProvider()
        #expect(await q.summarize("anything") == nil)
    }
}
