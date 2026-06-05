import Foundation
import FoundationModels

/// Converts a value between a small, honest set of length, mass, and temperature units.
/// Cross-dimension conversions return a corrective string instead of throwing.
public struct UnitConverterTool: Tool {
    public let name = "unitConverter"
    public let description = "Convert a value between units of length, mass, or temperature."

    @Generable
    public enum Unit: String {
        case meters, kilometers, miles, feet
        case kilograms, pounds
        case celsius, fahrenheit
    }

    @Generable
    public struct Arguments {
        @Guide(description: "The numeric value to convert")
        public var value: Double
        @Guide(description: "The unit to convert from")
        public var from: Unit
        @Guide(description: "The unit to convert to")
        public var to: Unit
        public init(value: Double, from: Unit, to: Unit) {
            self.value = value; self.from = from; self.to = to
        }
    }

    public init() {}

    public func call(arguments: Arguments) async throws -> String {
        guard let result = Self.convert(arguments.value, from: arguments.from, to: arguments.to) else {
            return "Can't convert \(arguments.from.rawValue) to \(arguments.to.rawValue) — they are different kinds of unit."
        }
        return "\(CalculatorTool.format(result)) \(arguments.to.rawValue)"
    }

    enum Dimension { case length, mass, temperature }
    static func dimension(of unit: Unit) -> Dimension {
        switch unit {
        case .meters, .kilometers, .miles, .feet: return .length
        case .kilograms, .pounds: return .mass
        case .celsius, .fahrenheit: return .temperature
        }
    }

    static func convert(_ value: Double, from: Unit, to: Unit) -> Double? {
        guard dimension(of: from) == dimension(of: to) else { return nil }
        switch dimension(of: from) {
        case .length:
            return fromMeters(toMeters(value, from), to)
        case .mass:
            let kg = (from == .kilograms) ? value : value * 0.45359237
            return (to == .kilograms) ? kg : kg / 0.45359237
        case .temperature:
            let celsius = (from == .celsius) ? value : (value - 32) * 5 / 9
            return (to == .celsius) ? celsius : celsius * 9 / 5 + 32
        }
    }

    private static func toMeters(_ v: Double, _ u: Unit) -> Double {
        switch u {
        case .meters: return v
        case .kilometers: return v * 1000
        case .miles: return v * 1609.344
        case .feet: return v * 0.3048
        default: return v
        }
    }
    private static func fromMeters(_ m: Double, _ u: Unit) -> Double {
        switch u {
        case .meters: return m
        case .kilometers: return m / 1000
        case .miles: return m / 1609.344
        case .feet: return m / 0.3048
        default: return m
        }
    }
}
