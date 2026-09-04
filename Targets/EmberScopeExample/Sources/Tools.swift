import Foundation
import FoundationModels

/// The three tools the example registers. They are deliberately SELF-CONTAINED — the example depends on
/// `EmberScope` alone, never on Ember's own `FoundationChatKit` — so what you read here is everything the
/// model can call, and everything the inspector's Tools tab reports.

/// Evaluate arithmetic. Malformed input returns a short corrective string instead of throwing, so the
/// model can recover on the next turn (the usual shape for a well-behaved tool).
struct CalculatorTool: Tool {
    let name = "calculator"
    let description = "Evaluate an arithmetic expression. Call ONLY when the user asks for a calculation."

    @Generable
    struct Arguments {
        @Guide(description: "An arithmetic expression, e.g. (12.5/100)*80")
        var expression: String
    }

    /// A pure recursive-descent evaluator, not `NSExpression`: the model authors the expression string and
    /// guided generation constrains it to *a String*, so an unbalanced paren or a trailing operator is a
    /// realistic input — and `NSExpression(format:)` raises an Objective-C exception Swift cannot catch on
    /// exactly those. The engine throws instead, which a demo can survive.
    private let engine = CalculatorEngine()

    func call(arguments: Arguments) async throws -> String {
        do {
            return Self.format(try engine.evaluate(arguments.expression))
        } catch {
            return "Couldn't evaluate '\(arguments.expression)'."
        }
    }

    /// Renders whole numbers without a trailing ".0".
    private static func format(_ value: Double) -> String {
        guard value.isFinite else { return "undefined" }
        let trimmed = (value * 1e10).rounded() / 1e10
        guard trimmed.isFinite else { return "undefined" }   // ≥ ~1e305 overflows the ×1e10 above
        if trimmed == trimmed.rounded(), abs(trimmed) < 1e15 { return String(Int(trimmed)) }
        return String(trimmed)
    }
}

/// The current date and time, optionally in a given IANA time zone.
struct ClockTool: Tool {
    let name = "clock"
    let description = "Get the current date and time, optionally for a specific time zone."

    @Generable
    struct Arguments {
        @Guide(description: "An IANA time zone like America/New_York. Omit for device local time.")
        var timeZone: String?
    }

    func call(arguments: Arguments) async throws -> String {
        var zone = TimeZone.current
        var note = ""
        if let id = arguments.timeZone, !id.isEmpty {
            if let named = TimeZone(identifier: id) {
                zone = named
            } else {
                note = " (unknown time zone '\(id)', showing device local time)"
            }
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        formatter.timeZone = zone
        return formatter.string(from: Date()) + note
    }
}

/// Always throws. One silly tool buys a deterministic tool-error path: the inspector then shows TWO error
/// rows — the tool's own failure, and the request failure that carries it — on every machine, with or
/// without Apple Intelligence.
struct FlakyTool: Tool {
    let name = "flaky"
    let description = "A tool that always fails. Call it when the user explicitly asks for the flaky tool."

    @Generable
    struct Arguments {
        @Guide(description: "Any short string; it is echoed back inside the failure.")
        var input: String
    }

    func call(arguments: Arguments) async throws -> String {
        throw ExampleToolError.simulatedFailure(arguments.input)
    }
}

enum ExampleToolError: LocalizedError {
    case simulatedFailure(String)

    var errorDescription: String? {
        switch self {
        case .simulatedFailure(let input):
            "FlakyTool always fails on purpose — it was called with '\(input)'."
        }
    }
}
