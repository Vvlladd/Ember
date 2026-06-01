import Foundation

public struct GenerationSettings: Sendable, Equatable {
    public var instructions: String?
    public var temperature: Double?
    public var maximumResponseTokens: Int?
    public init(instructions: String? = nil, temperature: Double? = nil, maximumResponseTokens: Int? = nil) {
        self.instructions = instructions
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
    }
}
