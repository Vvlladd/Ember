import Testing
@testable import FoundationChatKit

struct UnitConverterToolTests {
    @Test func kilometersToMiles() {
        let v = UnitConverterTool.convert(1, from: .kilometers, to: .miles)!
        #expect(abs(v - 0.621371) < 0.001)
    }
    @Test func celsiusToFahrenheit() {
        #expect(UnitConverterTool.convert(100, from: .celsius, to: .fahrenheit)! == 212)
        #expect(UnitConverterTool.convert(0, from: .celsius, to: .fahrenheit)! == 32)
    }
    @Test func kilogramsToPounds() {
        let v = UnitConverterTool.convert(1, from: .kilograms, to: .pounds)!
        #expect(abs(v - 2.20462) < 0.001)
    }
    @Test func crossDimensionIsNil() {
        #expect(UnitConverterTool.convert(1, from: .meters, to: .celsius) == nil)
    }
    @Test func callFormatsResult() async throws {
        let tool = UnitConverterTool()
        let result = try await tool.call(arguments: .init(value: 100, from: .celsius, to: .fahrenheit))
        #expect(result.contains("212"))
        #expect(result.contains("fahrenheit"))
    }
    @Test func callCrossDimensionIsCorrective() async throws {
        let tool = UnitConverterTool()
        let result = try await tool.call(arguments: .init(value: 1, from: .meters, to: .celsius))
        #expect(result.contains("different kinds of unit"))
    }
}
