import Testing
@testable import FoundationChatKit

struct CalculatorToolTests {
    @Test func evaluatesExpression() async throws {
        let tool = CalculatorTool()
        let result = try await tool.call(arguments: .init(expression: "(12.5/100)*80"))
        #expect(result == "10")
    }
    @Test func wholeNumbersHaveNoDecimal() async throws {
        let tool = CalculatorTool()
        #expect(try await tool.call(arguments: .init(expression: "2+2")) == "4")
    }
    @Test func malformedReturnsCorrectiveString() async throws {
        let tool = CalculatorTool()
        let result = try await tool.call(arguments: .init(expression: "2 +"))
        #expect(result.contains("Couldn't evaluate"))
    }
    @Test func metadata() {
        let tool = CalculatorTool()
        #expect(tool.name == "calculator")
        #expect(!tool.description.isEmpty)
    }
    @Test func trimsFloatingPointNoise() {
        #expect(CalculatorTool.format(0.1 + 0.2) == "0.3")
        #expect(CalculatorTool.format(14.0) == "14")
    }
}
