import Foundation

public struct GenerationSettings: Sendable, Equatable {
    public var instructions: String?
    public var temperature: Double?
    public var maximumResponseTokens: Int?
    public var reservedReplyTokens: Int
    public var memoryRetrievalTopK: Int = 4
    /// Minimum score for an auto-RAG hit. Raised from 0.5 → 0.35 in Plan 10 WS2 so durable
    /// notes aren't lost, but tight enough to keep near-miss noise out of the prompt.
    public var memoryRetrievalThreshold: Float = 0.35
    /// Inject at most this many hits per turn (retrieve-more / inject-fewer). Plan 10 WS2.
    public var memoryInjectionMaxHits: Int = 3
    /// Clamp each injected hit to this many characters. Plan 10 WS2.
    public var memoryInjectionMaxCharsPerHit: Int = 240
    /// When true, after each completed turn the model is asked to extract salient user facts
    /// which are persisted as de-duplicated `.note` memories (Plan 9). Off the hot path, but
    /// costs one extra model round-trip per turn when on.
    public var autoExtractMemories: Bool = true
    public init(instructions: String? = nil, temperature: Double? = nil,
                maximumResponseTokens: Int? = nil, reservedReplyTokens: Int = 512,
                memoryRetrievalTopK: Int = 4, memoryRetrievalThreshold: Float = 0.35,
                memoryInjectionMaxHits: Int = 3, memoryInjectionMaxCharsPerHit: Int = 240,
                autoExtractMemories: Bool = true) {
        self.instructions = instructions
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
        self.reservedReplyTokens = reservedReplyTokens
        self.memoryRetrievalTopK = memoryRetrievalTopK
        self.memoryRetrievalThreshold = memoryRetrievalThreshold
        self.memoryInjectionMaxHits = memoryInjectionMaxHits
        self.memoryInjectionMaxCharsPerHit = memoryInjectionMaxCharsPerHit
        self.autoExtractMemories = autoExtractMemories
    }
}
