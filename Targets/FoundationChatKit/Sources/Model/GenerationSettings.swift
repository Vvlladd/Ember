import Foundation

public struct GenerationSettings: Sendable, Equatable {
    public var instructions: String?
    public var temperature: Double?
    public var maximumResponseTokens: Int?
    public var reservedReplyTokens: Int
    public init(instructions: String? = nil, temperature: Double? = nil,
                maximumResponseTokens: Int? = nil, reservedReplyTokens: Int = 512) {
        self.instructions = instructions
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
        self.reservedReplyTokens = reservedReplyTokens
    }
}
