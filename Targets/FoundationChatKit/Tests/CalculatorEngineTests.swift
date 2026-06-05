import Testing
@testable import FoundationChatKit

struct CalculatorEngineTests {
    let engine = CalculatorEngine()

    @Test func addition() throws { #expect(try engine.evaluate("2+2") == 4) }
    @Test func precedence() throws { #expect(try engine.evaluate("2 + 3 * 4") == 14) }
    @Test func parentheses() throws { #expect(try engine.evaluate("(2 + 3) * 4") == 20) }
    @Test func division() throws { #expect(try engine.evaluate("10 / 4") == 2.5) }
    @Test func unaryMinus() throws { #expect(try engine.evaluate("-5 + 2") == -3) }

    @Test func divisionByZeroThrows() {
        #expect(throws: CalculatorEngine.CalculatorError.divisionByZero) {
            try engine.evaluate("5 / 0")
        }
    }
    @Test func malformedThrows() {
        #expect(throws: CalculatorEngine.CalculatorError.malformedExpression) {
            try engine.evaluate("2 +")
        }
    }
    @Test func gibberishThrows() {
        #expect(throws: (any Error).self) { try engine.evaluate("abc") }
    }
}
