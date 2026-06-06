import Foundation

/// An immutable, Sendable snapshot of one embedded record — used for off-actor cosine search.
public struct MemoryRecord: Sendable, Equatable {
    /// Where this record came from, so the formatter can render it appropriately.
    public enum Source: Sendable, Equatable { case conversation, note }

    public let messageID: UUID
    public let conversationID: UUID
    public let conversationTitle: String
    public let role: MessageRole
    public let text: String
    public let vector: [Float]
    public let source: Source
    public init(messageID: UUID, conversationID: UUID, conversationTitle: String,
                role: MessageRole, text: String, vector: [Float],
                source: Source = .conversation) {
        self.messageID = messageID
        self.conversationID = conversationID
        self.conversationTitle = conversationTitle
        self.role = role
        self.text = text
        self.vector = vector
        self.source = source
    }
}

/// A scored search result.
public struct MemoryHit: Sendable, Equatable {
    public let record: MemoryRecord
    public let score: Float
    public init(record: MemoryRecord, score: Float) {
        self.record = record
        self.score = score
    }
}
