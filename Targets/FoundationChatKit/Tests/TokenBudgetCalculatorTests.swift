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
    @Test func retrievedMemoryLabelledAndCounted() {
        let calc = TokenBudgetCalculator()
        let snap = calc.snapshot(
            maxTokens: 4096, instructions: nil,
            entries: [ContextEntry(kind: .retrievedMemory, text: "earlier paris trip context")],
            inFlight: nil, exactCount: { $0.count })
        let line = snap.lines.first { $0.label == "Memory" }
        #expect(line != nil)
        #expect(line!.tokens > 0)
    }
    @Test func instructionsLineShownWhenNoEntry() {
        let calc = TokenBudgetCalculator()
        let snap = calc.snapshot(
            maxTokens: 4096, instructions: "sys",
            entries: [ContextEntry(kind: .userPrompt, text: "hi")],
            inFlight: nil, exactCount: { _ in nil })
        #expect(snap.lines.contains { $0.label == "Instructions" })
    }

    @Test func breakdownBucketsSnapshotLines() {
        let lines = [
            BudgetLine(id: 0, label: "Instructions", tokens: 12),
            BudgetLine(id: 1, label: "Tool: calculator", tokens: 8),
            BudgetLine(id: 2, label: "Tool: dateTime", tokens: 6),
            BudgetLine(id: 3, label: "You", tokens: 40),
            BudgetLine(id: 4, label: "Assistant", tokens: 55),
            BudgetLine(id: 5, label: "Retrieved memory", tokens: 9)   // WS2 synthetic line
        ]
        let snapshot = TokenBudgetSnapshot(maxTokens: 4096, usedTokens: 130, isExact: true, lines: lines)
        let calc = TokenBudgetCalculator()
        let b = calc.breakdown(from: snapshot, replyReserve: 512)
        #expect(b.instructions == 12)
        #expect(b.tools == 14)               // 8 + 6
        #expect(b.history == 95)             // 40 + 55
        #expect(b.retrievedMemory == 9)
        #expect(b.replyReserve == 512)
        #expect(b.total == 12 + 14 + 95 + 9 + 512)
    }

    @Test func breakdownBucketsCommittedMemoryLabel() {
        // The real committed-transcript memory label also maps to retrievedMemory.
        let lines = [
            BudgetLine(id: 0, label: "You", tokens: 20),
            BudgetLine(id: 1, label: "Memory", tokens: 17)   // real committed-memory label
        ]
        let snapshot = TokenBudgetSnapshot(maxTokens: 4096, usedTokens: 37, isExact: true, lines: lines)
        let b = TokenBudgetCalculator().breakdown(from: snapshot, replyReserve: 0)
        #expect(b.retrievedMemory == 17)
        #expect(b.history == 20)
    }

    @Test func breakdownTreatsTypingLineAsHistory() {
        let lines = [
            BudgetLine(id: 0, label: "You", tokens: 10),
            BudgetLine(id: 1, label: "Assistant (typing\u{2026})", tokens: 3)   // real typing label
        ]
        let snapshot = TokenBudgetSnapshot(maxTokens: 4096, usedTokens: 13, isExact: false, lines: lines)
        let b = TokenBudgetCalculator().breakdown(from: snapshot, replyReserve: 0)
        #expect(b.history == 13)
        #expect(b.replyReserve == 0)
    }
}
