import Foundation
import SwiftData

@Model
public final class Message {
    public var id: UUID
    public var roleRaw: String
    public var text: String
    public var createdAt: Date
    public var conversation: Conversation?
    public var embedding: Data?

    public init(id: UUID = UUID(), role: MessageRole, text: String, createdAt: Date, conversation: Conversation? = nil, embedding: Data? = nil) {
        self.id = id
        self.roleRaw = role.rawValue
        self.text = text
        self.createdAt = createdAt
        self.conversation = conversation
        self.embedding = embedding
    }

    public var role: MessageRole { MessageRole(rawValue: roleRaw) ?? .systemNotice }
}
