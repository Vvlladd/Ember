import Foundation
import SwiftData

/// A curated fact the model deliberately persisted via the `saveMemory` tool. Kept separate from
/// `Message` (it is not a conversation turn) so it can be embedded and retrieved on its own.
@Model
public final class MemoryNote {
    public var id: UUID
    public var text: String
    public var createdAt: Date
    public var embedding: Data?

    public init(id: UUID = UUID(), text: String, createdAt: Date, embedding: Data? = nil) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.embedding = embedding
    }
}
