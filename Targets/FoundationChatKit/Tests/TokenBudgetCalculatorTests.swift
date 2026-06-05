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

    @Test func identicalInputsProduceEqualSnapshotsWithStableIDs() {
        let calc = TokenBudgetCalculator(estimator: TokenEstimator())
        let entries = [
            ContextEntry(kind: .userPrompt, text: "abcd"),
            ContextEntry(kind: .modelResponse, text: "ef"),
        ]
        let a = calc.snapshot(maxTokens: 4096, instructions: "xyz", entries: entries, inFlight: nil, exactCount: oneTokenPerChar)
        let b = calc.snapshot(maxTokens: 4096, instructions: "xyz", entries: entries, inFlight: nil, exactCount: oneTokenPerChar)
        #expect(a == b)                              // stable positional ids make Equatable meaningful
        #expect(a.lines.map(\.id) == [0, 1, 2])
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

    @Test func includesToolDefinitionLines() {
        let calc = TokenBudgetCalculator()
        let tools = [ToolAccounting(name: "calculator", schemaDigest: "calculator evaluate math expression")]
        let snapshot = calc.snapshot(
            maxTokens: 4096,
            instructions: "sys",
            entries: [ContextEntry(kind: .userPrompt, text: "hi")],
            inFlight: nil,
            tools: tools,
            exactCount: { _ in nil }
        )
        #expect(snapshot.lines.contains { $0.label == "Tool: calculator" })
        let toolLine = snapshot.lines.first { $0.label == "Tool: calculator" }!
        #expect(toolLine.tokens > 0)
        #expect(snapshot.usedTokens == snapshot.lines.reduce(0) { $0 + $1.tokens })
    }

    @Test func instructionsCountedOnceWhenEntryPresent() {
        let calc = TokenBudgetCalculator()
        let snap = calc.snapshot(
            maxTokens: 4096, instructions: "sys",
            entries: [ContextEntry(kind: .instructions, text: "sys"),
                      ContextEntry(kind: .userPrompt, text: "hi")],
            inFlight: nil, exactCount: { _ in nil })
        #expect(snap.lines.filter { $0.label == "Instructions" }.count == 1)
    }
    @Test func instructionsLineShownWhenNoEntry() {
        let calc = TokenBudgetCalculator()
        let snap = calc.snapshot(
            maxTokens: 4096, instructions: "sys",
            entries: [ContextEntry(kind: .userPrompt, text: "hi")],
            inFlight: nil, exactCount: { _ in nil })
        #expect(snap.lines.contains { $0.label == "Instructions" })
    }
}
