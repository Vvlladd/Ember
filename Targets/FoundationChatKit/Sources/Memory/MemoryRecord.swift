import Foundation

/// An immutable, Sendable snapshot of one embedded message — used for off-actor cosine search.
public struct MemoryRecord: Sendable, Equatable {
    public let messageID: UUID
    public let conversationID: UUID
    public let conversationTitle: String
    public let role: MessageRole
    public let text: String
    public let vector: [Float]
    public init(messageID: UUID, conversationID: UUID, conversationTitle: String,
                role: MessageRole, text: String, vector: [Float]) {
        self.messageID = messageID
        self.conversationID = conversationID
        self.conversationTitle = conversationTitle
        self.role = role
        self.text = text
        self.vector = vector
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
