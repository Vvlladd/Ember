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
}
