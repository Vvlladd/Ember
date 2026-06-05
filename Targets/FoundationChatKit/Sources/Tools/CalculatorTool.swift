import Foundation
import FoundationModels

/// A tool the model can call to evaluate arithmetic. Backed by the pure `CalculatorEngine`.
/// Malformed input returns a short corrective string (not a throw) so the model can recover.
public struct CalculatorTool: Tool {
    public let name = "calculator"
    public let description = "Evaluate an arithmetic expression with + - * / and parentheses."

    @Generable
    public struct Arguments {
        @Guide(description: "An arithmetic expression, e.g. (12.5/100)*80")
        public var expression: String
        public init(expression: String) { self.expression = expression }
    }

    private let engine = CalculatorEngine()
    public init() {}

    public func call(arguments: Arguments) async throws -> String {
        do {
            return Self.format(try engine.evaluate(arguments.expression))
        } catch {
            return "Couldn't evaluate '\(arguments.expression)'."
        }
    }

    /// Renders whole numbers without a trailing ".0".
    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        return String(value)
    }
}
