import Testing
@testable import FoundationChatKit

@Suite struct TokenBreakdownTests {
    @Test func totalSumsAllBuckets() {
        let b = TokenBreakdown(instructions: 10, tools: 20, history: 100,
                               retrievedMemory: 30, replyReserve: 512)
        #expect(b.total == 10 + 20 + 100 + 30 + 512)
    }

    @Test func breakdownIsEquatable() {
        let a = TokenBreakdown(instructions: 1, tools: 2, history: 3, retrievedMemory: 4, replyReserve: 5)
        let b = TokenBreakdown(instructions: 1, tools: 2, history: 3, retrievedMemory: 4, replyReserve: 5)
        #expect(a == b)
    }

    @Test func colorBucketsMatchThresholds() {
        #expect(TokenMeterColor.for(fraction: 0.0) == .green)
        #expect(TokenMeterColor.for(fraction: 0.49) == .green)
        #expect(TokenMeterColor.for(fraction: 0.5) == .yellow)
        #expect(TokenMeterColor.for(fraction: 0.74) == .yellow)
        #expect(TokenMeterColor.for(fraction: 0.75) == .orange)
        #expect(TokenMeterColor.for(fraction: 0.89) == .orange)
        #expect(TokenMeterColor.for(fraction: 0.9) == .red)
        #expect(TokenMeterColor.for(fraction: 1.5) == .red)   // clamps above 1
    }
}
