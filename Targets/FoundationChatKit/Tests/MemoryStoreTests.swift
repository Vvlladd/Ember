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

    private func makeStore() throws -> (MemoryStore, ConversationStore) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Conversation.self, Message.self, configurations: config)
        let context = ModelContext(container)
        return (MemoryStore(context: context, embedder: MockEmbedder()),
                ConversationStore(context: context))
    }

    @Test func indexSetsEmbedding() throws {
        let (mem, store) = try makeStore()
        let c = store.createConversation(now: Date(timeIntervalSince1970: 0))
        store.appendMessage(role: .user, text: "trip to paris", to: c, now: Date(timeIntervalSince1970: 0))
        let m = c.orderedMessages.first!
        #expect(m.embedding == nil)
        mem.index(m)
        #expect(m.embedding != nil)
    }
    @Test func backfillEmbedsAllAndSnapshots() throws {
        let (mem, store) = try makeStore()
        let c = store.createConversation(now: Date(timeIntervalSince1970: 0))
        store.appendMessage(role: .user, text: "trip to paris", to: c, now: Date(timeIntervalSince1970: 0))
        store.appendMessage(role: .assistant, text: "paris is great", to: c, now: Date(timeIntervalSince1970: 1))
        mem.backfill()
        #expect(c.orderedMessages.allSatisfy { $0.embedding != nil })
        #expect(mem.snapshot().count == 2)
    }
    @Test func searchRanksAndExcludes() throws {
        let (mem, store) = try makeStore()
        let c = store.createConversation(now: Date(timeIntervalSince1970: 0))
        store.appendMessage(role: .user, text: "trip to paris", to: c, now: Date(timeIntervalSince1970: 0))
        store.appendMessage(role: .user, text: "debugging swift code", to: c, now: Date(timeIntervalSince1970: 1))
        mem.backfill()
        let snap = mem.snapshot()
        let q = MockEmbedder().embed("paris trip")!
        let hits = MemoryStore.search(snap, queryVector: q, topK: 3, threshold: 0.1)
        #expect(hits.first?.record.text == "trip to paris")
        let excluded = Set(snap.filter { $0.text == "trip to paris" }.map(\.messageID))
        let hits2 = MemoryStore.search(snap, queryVector: q, topK: 3, threshold: 0.1, excludingMessageIDs: excluded)
        #expect(!hits2.contains { $0.record.text == "trip to paris" })
    }
}
