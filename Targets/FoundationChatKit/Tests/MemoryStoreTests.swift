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
        let container = try ModelContainer(for: Conversation.self, Message.self, MemoryNote.self,
                                           configurations: config)
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

    @Test func snapshotIsCachedUntilInvalidatingWrite() throws {
        let (mem, store) = try makeStore()
        let c = store.createConversation(now: Date(timeIntervalSince1970: 0))
        store.appendMessage(role: .user, text: "trip to paris", to: c, now: Date(timeIntervalSince1970: 0))
        mem.backfill()

        // First call builds the cache.
        let first = mem.snapshot()
        #expect(mem.snapshotBuildCount == 1)
        #expect(first.count == 1)

        // Repeated calls reuse the cache (no rebuild) and return identical results.
        let second = mem.snapshot()
        #expect(mem.snapshotBuildCount == 1)
        #expect(second == first)

        // Adding a message without indexing it does NOT invalidate the cache:
        // snapshot() stays stale (still 1 record) and does not rebuild.
        store.appendMessage(role: .assistant, text: "paris is great", to: c, now: Date(timeIntervalSince1970: 1))
        let stillStale = mem.snapshot()
        #expect(mem.snapshotBuildCount == 1)
        #expect(stillStale.count == 1)

        // An invalidating write (indexing the new message) rebuilds on next snapshot()
        // and reflects the change.
        mem.index(c.orderedMessages.first { $0.role == .assistant }!)
        let fresh = mem.snapshot()
        #expect(mem.snapshotBuildCount == 2)
        #expect(fresh.count == 2)
    }

    @Test func saveNoteAppearsInSnapshotAsNote() throws {
        let (mem, _) = try makeStore()
        mem.saveNote("planning a trip to paris")
        let snap = mem.snapshot()
        #expect(snap.contains { $0.source == .note && $0.text == "planning a trip to paris" })
    }

    @Test func saveNoteIgnoresEmptyAndTrims() throws {
        let (mem, _) = try makeStore()
        mem.saveNote("   ")
        #expect(mem.snapshot().isEmpty)
        mem.saveNote("  trip to paris  ")
        #expect(mem.snapshot().contains { $0.text == "trip to paris" && $0.source == .note })
    }

    @Test func indexEarlyReturnDoesNotInvalidateCache() throws {
        let (mem, store) = try makeStore()
        let c = store.createConversation(now: Date(timeIntervalSince1970: 0))
        store.appendMessage(role: .user, text: "trip to paris", to: c, now: Date(timeIntervalSince1970: 0))
        let indexed = c.orderedMessages.first!
        mem.index(indexed)
        _ = mem.snapshot()
        #expect(mem.snapshotBuildCount == 1)

        // Re-indexing an already-embedded message writes nothing -> cache stays valid.
        mem.index(indexed)
        _ = mem.snapshot()
        #expect(mem.snapshotBuildCount == 1)
    }
}
