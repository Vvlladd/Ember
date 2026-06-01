import Foundation

public enum BudgetZone: Sendable, Equatable { case green, amber, red }

public struct BudgetLine: Identifiable, Sendable, Equatable {
    /// Stable position index within the snapshot. Using a positional id (not a random
    /// UUID) keeps `TokenBudgetSnapshot` Equatable meaningful and keeps SwiftUI `ForEach`
    /// rows stable across the per-token budget recomputes during streaming.
    public let id: Int
    public var label: String
    public var tokens: Int
    public init(id: Int, label: String, tokens: Int) {
        self.id = id; self.label = label; self.tokens = tokens
    }
}

public struct TokenBudgetSnapshot: Sendable, Equatable {
    public var maxTokens: Int
    public var usedTokens: Int
    public var isExact: Bool
    public var lines: [BudgetLine]
    public init(maxTokens: Int, usedTokens: Int, isExact: Bool, lines: [BudgetLine]) {
        self.maxTokens = maxTokens
        self.usedTokens = usedTokens
        self.isExact = isExact
        self.lines = lines
    }
    public var remaining: Int { max(0, maxTokens - usedTokens) }
    public var fraction: Double { maxTokens <= 0 ? 0 : min(1, Double(usedTokens) / Double(maxTokens)) }
    public var zone: BudgetZone {
        switch fraction {
        case ..<0.70: return .green
        case ..<0.90: return .amber
        default: return .red
        }
    }
}
