import Foundation
import FoundationModels

/// Token-accounting metadata for one registered tool. Plain value type (no FoundationModels
/// dependency) so `TokenBudgetCalculator` can consume it.
public struct ToolAccounting: Sendable, Equatable {
    public let name: String
    public let schemaDigest: String   // the text the estimator counts (name + description + schema)
    public init(name: String, schemaDigest: String) {
        self.name = name
        self.schemaDigest = schemaDigest
    }
}

/// Assembles Ember's default tool set and derives token-accounting metadata.
public enum Toolbox {
    public static func defaultTools(now: @escaping @Sendable () -> Date = Date.init) -> [any Tool] {
        [DateTimeTool(now: now), CalculatorTool(), UnitConverterTool()]
    }

    public static func accountingMetadata(for tools: [any Tool]) -> [ToolAccounting] {
        tools.map { tool in
            ToolAccounting(
                name: tool.name,
                schemaDigest: tool.name + " " + tool.description + " " + String(describing: tool.parameters)
            )
        }
    }
}
