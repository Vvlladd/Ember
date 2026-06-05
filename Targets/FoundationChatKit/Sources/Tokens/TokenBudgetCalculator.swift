import Foundation

public struct TokenBudgetCalculator: Sendable {
    private let estimator: TokenEstimator
    public init(estimator: TokenEstimator = TokenEstimator()) { self.estimator = estimator }

    public func snapshot(
        maxTokens: Int,
        instructions: String?,
        entries: [ContextEntry],
        inFlight: String?,
        tools: [ToolAccounting] = [],
        exactCount: (String) -> Int?
    ) -> TokenBudgetSnapshot {
        var isExact = true
        func count(_ text: String) -> Int {
            if let exact = exactCount(text) { return exact }
            isExact = false
            return estimator.estimate(text)
        }
        var lines: [BudgetLine] = []
        func add(_ label: String, _ text: String) {
            lines.append(BudgetLine(id: lines.count, label: label, tokens: count(text)))
        }
        if let instructions, !instructions.isEmpty {
            add("Instructions", instructions)
        }
        for tool in tools {
            add("Tool: \(tool.name)", tool.schemaDigest)
        }
        for entry in entries {
            add(Self.label(for: entry.kind), entry.text)
        }
        if let inFlight, !inFlight.isEmpty {
            add("Assistant (typing\u{2026})", inFlight)
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
