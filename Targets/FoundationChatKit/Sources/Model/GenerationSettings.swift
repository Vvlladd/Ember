import Foundation

public struct GenerationSettings: Sendable, Equatable {
    public var instructions: String?
    public var temperature: Double?
    public var maximumResponseTokens: Int?
    public var reservedReplyTokens: Int
    public var memoryRetrievalTopK: Int = 1
    public var memoryRetrievalThreshold: Float = 0.5
    /// When true, after each completed turn the model is asked to extract salient user facts
    /// which are persisted as de-duplicated `.note` memories (Plan 9). Off the hot path, but
    /// costs one extra model round-trip per turn when on.
    public var autoExtractMemories: Bool = true
    public init(instructions: String? = nil, temperature: Double? = nil,
                maximumResponseTokens: Int? = nil, reservedReplyTokens: Int = 512,
                memoryRetrievalTopK: Int = 1, memoryRetrievalThreshold: Float = 0.5,
                autoExtractMemories: Bool = true) {
        self.instructions = instructions
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
        self.reservedReplyTokens = reservedReplyTokens
        self.memoryRetrievalTopK = memoryRetrievalTopK
        self.memoryRetrievalThreshold = memoryRetrievalThreshold
        self.autoExtractMemories = autoExtractMemories
    }
}
