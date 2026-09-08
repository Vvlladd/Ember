import Foundation

/// A small, dependency-free arithmetic evaluator: `+ - * /`, parentheses, decimals,
/// unary +/-. Precedence-correct recursive descent. No FoundationModels dependency so
/// it is trivially unit-testable.
///
/// NOTE: this is a verbatim copy of `Targets/FoundationChatKit/Sources/Tools/CalculatorEngine.swift`
/// (minus the `public` modifiers, which the example does not need), because the example must not depend
/// on `FoundationChatKit` — depending on `EmberScope` alone is the whole point of this target. If you
/// change one, change the other: keep the two in sync.
struct CalculatorEngine: Sendable {
    enum CalculatorError: Error, Equatable {
        case malformedExpression
        case divisionByZero
    }

    init() {}

    func evaluate(_ expression: String) throws -> Double {
        var parser = Parser(expression)
        let value = try parser.parseExpression()
        try parser.expectEnd()
        return value
    }

    private struct Parser {
        let chars: [Character]
        var index = 0
        init(_ s: String) { chars = Array(s) }

        mutating func parseExpression() throws -> Double {     // + and -
            var value = try parseTerm()
            while let op = peekOperator(), op == "+" || op == "-" {
                advance()
                let rhs = try parseTerm()
                value = (op == "+") ? value + rhs : value - rhs
            }
            return value
        }

        mutating func parseTerm() throws -> Double {           // * and /
            var value = try parseFactor()
            while let op = peekOperator(), op == "*" || op == "/" {
                advance()
                let rhs = try parseFactor()
                if op == "/" {
                    guard rhs != 0 else { throw CalculatorError.divisionByZero }
                    value /= rhs
                } else {
                    value *= rhs
                }
            }
            return value
        }

        mutating func parseFactor() throws -> Double {
            skipSpaces()
            guard index < chars.count else { throw CalculatorError.malformedExpression }
            let c = chars[index]
            if c == "(" {
                advance()
                let value = try parseExpression()
                skipSpaces()
                guard index < chars.count, chars[index] == ")" else {
                    throw CalculatorError.malformedExpression
                }
                advance()
                return value
            }
            if c == "-" { advance(); return try -parseFactor() }
            if c == "+" { advance(); return try parseFactor() }
            return try parseNumber()
        }

        mutating func parseNumber() throws -> Double {
            skipSpaces()
            var digits = ""
            while index < chars.count, chars[index].isNumber || chars[index] == "." {
                digits.append(chars[index]); advance()
            }
            guard let value = Double(digits) else { throw CalculatorError.malformedExpression }
            return value
        }

        mutating func peekOperator() -> Character? {
            skipSpaces()
            guard index < chars.count else { return nil }
            let c = chars[index]
            return "+-*/".contains(c) ? c : nil
        }

        mutating func skipSpaces() { while index < chars.count, chars[index] == " " { advance() } }
        mutating func advance() { index += 1 }
        mutating func expectEnd() throws {
            skipSpaces()
            if index != chars.count { throw CalculatorError.malformedExpression }
        }
    }
}
