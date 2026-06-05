import Foundation

public struct TokenBudgetCalculator: Sendable {
    private let estimator: TokenEstimator
    public init(estimator: TokenEstimator = TokenEstimator()) { self.estimator = estimator }

    /// Estimate tokens for a single string (used for proactive pre-turn budgeting).
    public func estimate(_ text: String) -> Int { estimator.estimate(text) }

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
        let hasInstructionEntry = entries.contains { $0.kind == .instructions }
        if let instructions, !instructions.isEmpty, !hasInstructionEntry {
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
