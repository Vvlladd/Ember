import Foundation

/// Per-bucket view of where the context budget goes (Plan 10 WS5). Pure, Sendable, Equatable —
/// the SwiftUI inspector renders it directly.
public struct TokenBreakdown: Sendable, Equatable {
    public var instructions: Int
    public var tools: Int
    public var history: Int
    public var retrievedMemory: Int
    public var replyReserve: Int

    public var total: Int { instructions + tools + history + retrievedMemory + replyReserve }

    public init(instructions: Int, tools: Int, history: Int,
                retrievedMemory: Int, replyReserve: Int) {
        self.instructions = instructions
        self.tools = tools
        self.history = history
        self.retrievedMemory = retrievedMemory
        self.replyReserve = replyReserve
    }
}

/// Color bucket for the token gauge fraction. Borrows Foundation Lab's TokenUsageBar
/// thresholds: green < 0.5, yellow < 0.75, orange < 0.9, red >= 0.9.
public enum TokenMeterColorBucket: Sendable, Equatable { case green, yellow, orange, red }

public enum TokenMeterColor {
    public static func `for`(fraction: Double) -> TokenMeterColorBucket {
        let f = min(max(fraction, 0), 1)
        switch f {
        case ..<0.5: return .green
        case ..<0.75: return .yellow
        case ..<0.9: return .orange
        default: return .red
        }
    }
}
