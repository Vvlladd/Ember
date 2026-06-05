import Testing
import Foundation
import SwiftData
@testable import FoundationChatKit

@MainActor
struct MemoryStoreTests {
    @Test func messageStoresEmbedding() {
        let m = Message(role: .user, text: "hi", createdAt: Date(timeIntervalSince1970: 0),
                        embedding: Data([1, 2, 3]))
        #expect(m.embedding == Data([1, 2, 3]))
    }
    @Test func memoryRecordInit() {
        let r = MemoryRecord(messageID: UUID(), conversationID: UUID(), conversationTitle: "T",
                             role: .user, text: "x", vector: [1, 2])
        #expect(r.vector == [1, 2])
        #expect(MemoryHit(record: r, score: 0.5).score == 0.5)
    }
}
