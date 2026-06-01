import Foundation

public struct TokenBudgetCalculator: Sendable {
    private let estimator: TokenEstimator
    public init(estimator: TokenEstimator = TokenEstimator()) { self.estimator = estimator }

    public func snapshot(
        maxTokens: Int,
        instructions: String?,
        entries: [ContextEntry],
        inFlight: String?,
        exactCount: (String) -> Int?
    ) -> TokenBudgetSnapshot {
        var isExact = true
        func count(_ text: String) -> Int {
            if let exact = exactCount(text) { return exact }
            isExact = false
            return estimator.estimate(text)
        }
        var lines: [BudgetLine] = []
        if let instructions, !instructions.isEmpty {
            lines.append(BudgetLine(label: "Instructions", tokens: count(instructions)))
        }
        for entry in entries {
            lines.append(BudgetLine(label: Self.label(for: entry.kind), tokens: count(entry.text)))
        }
        if let inFlight, !inFlight.isEmpty {
            lines.append(BudgetLine(label: "Assistant (typing\u{2026})", tokens: count(inFlight)))
        }
        let used = lines.reduce(0) { $0 + $1.tokens }
        return TokenBudgetSnapshot(maxTokens: maxTokens, usedTokens: used, isExact: isExact, lines: lines)
    }

    static func label(for kind: ContextEntryKind) -> String {
        switch kind {
        case .instructions: return "Instructions"
        case .userPrompt: return "You"
        case .modelResponse: return "Assistant"
        case .toolCall: return "Tool call"
        case .toolOutput: return "Tool output"
        }
    }
}
