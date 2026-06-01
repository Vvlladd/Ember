import Foundation

public struct ChatMessage: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var role: MessageRole
    public var text: String
    public var createdAt: Date
    public var isStreaming: Bool

    public init(id: UUID = UUID(), role: MessageRole, text: String, createdAt: Date, isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.isStreaming = isStreaming
    }
}
