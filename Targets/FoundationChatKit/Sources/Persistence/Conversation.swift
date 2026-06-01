import Foundation
import SwiftData

@Model
public final class Conversation {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var transcriptData: Data?
    public var modelVersionTag: String?
    public var lastTokenCount: Int
    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    public var messages: [Message]

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date,
        updatedAt: Date,
        transcriptData: Data? = nil,
        modelVersionTag: String? = nil,
        lastTokenCount: Int = 0,
        messages: [Message] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.transcriptData = transcriptData
        self.modelVersionTag = modelVersionTag
        self.lastTokenCount = lastTokenCount
        self.messages = messages
    }

    public var orderedMessages: [Message] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }
}
