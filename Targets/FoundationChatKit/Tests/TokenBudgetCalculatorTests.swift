import Testing
@testable import FoundationChatKit

struct TokenBudgetCalculatorTests {
    func oneTokenPerChar(_ s: String) -> Int? { s.count }

    @Test func buildsBreakdownAndSumsUsed() {
        let calc = TokenBudgetCalculator(estimator: TokenEstimator())
        let entries = [
            ContextEntry(kind: .userPrompt, text: "abcd"),
            ContextEntry(kind: .modelResponse, text: "ef"),
        ]
        let snap = calc.snapshot(maxTokens: 4096, instructions: "xyz", entries: entries, inFlight: nil, exactCount: oneTokenPerChar)
        #expect(snap.isExact == true)
        #expect(snap.usedTokens == 9)
        #expect(snap.remaining == 4087)
        #expect(snap.lines.map(\.label) == ["Instructions", "You", "Assistant"])
        #expect(snap.lines.map(\.tokens) == [3, 4, 2])
    }

    @Test func inFlightAddsToUsed() {
        let calc = TokenBudgetCalculator(estimator: TokenEstimator())
        let snap = calc.snapshot(maxTokens: 100, instructions: nil, entries: [], inFlight: "abcdefg", exactCount: oneTokenPerChar)
        #expect(snap.usedTokens == 7)
        #expect(snap.lines.last?.label == "Assistant (typing…)")
    }

    @Test func fallsBackToEstimatorWhenNoExactCounter() {
        let calc = TokenBudgetCalculator(estimator: TokenEstimator())
        let entries = [ContextEntry(kind: .userPrompt, text: String(repeating: "a", count: 35))]
        let snap = calc.snapshot(maxTokens: 4096, instructions: nil, entries: entries, inFlight: nil, exactCount: { _ in nil })
        #expect(snap.isExact == false)
        #expect(snap.usedTokens == 10)
    }

    @Test func zoneThresholds() {
        let calc = TokenBudgetCalculator(estimator: TokenEstimator())
        func zone(used: Int) -> BudgetZone {
            calc.snapshot(maxTokens: 100, instructions: String(repeating: "x", count: used), entries: [], inFlight: nil, exactCount: { $0.count }).zone
        }
        #expect(zone(used: 50) == .green)
        #expect(zone(used: 75) == .amber)
        #expect(zone(used: 95) == .red)
    }
}
