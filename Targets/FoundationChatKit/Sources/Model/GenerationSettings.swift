import Foundation

public struct GenerationSettings: Sendable, Equatable {
    public var instructions: String?
    public var temperature: Double?
    public var maximumResponseTokens: Int?
    public var reservedReplyTokens: Int
    public var memoryRetrievalTopK: Int = 1
    public var memoryRetrievalThreshold: Float = 0.5
    public init(instructions: String? = nil, temperature: Double? = nil,
                maximumResponseTokens: Int? = nil, reservedReplyTokens: Int = 512,
                memoryRetrievalTopK: Int = 1, memoryRetrievalThreshold: Float = 0.5) {
        self.instructions = instructions
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
        self.reservedReplyTokens = reservedReplyTokens
        self.memoryRetrievalTopK = memoryRetrievalTopK
        self.memoryRetrievalThreshold = memoryRetrievalThreshold
    }
}
