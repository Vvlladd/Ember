import Foundation
import SwiftData
import Testing
@testable import FoundationChatKit

@MainActor
struct BackfillMigrationTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Conversation.self, Message.self, MemoryNote.self,
                                           configurations: config)
        return ModelContext(container)
    }

    /// Seed `count` messages embedded in the "other-space" identity.
    private func seedStale(_ context: ModelContext, count: Int) throws {
        let old = MemoryStore(context: context, embedder: OtherSpaceEmbedder())
        for i in 0..<count {
            let m = Message(role: .user, text: "trip \(i) to paris",
                            createdAt: Date(timeIntervalSince1970: Double(i)))
            context.insert(m)
            old.index(m)
        }
        try context.save()
    }

    @Test func backfillMigratesUpToChunkSize() throws {
        let context = try makeContext()
        try seedStale(context, count: 5)
        let store = MemoryStore(context: context, embedder: MockEmbedder())
        #expect(store.backfill(chunkSize: 3) == 3)
        let migrated = try context.fetch(FetchDescriptor<Message>())
            .filter { $0.embedderID == "mock-bag-of-words" }
        #expect(migrated.count == 3)
    }

    @Test func backfillIsIdempotentAndConverges() throws {
        let context = try makeContext()
        try seedStale(context, count: 5)
        let store = MemoryStore(context: context, embedder: MockEmbedder())
        #expect(store.backfill(chunkSize: 3) == 3)
        #expect(store.backfill(chunkSize: 3) == 2)   // remainder
        #expect(store.backfill(chunkSize: 3) == 0)   // converged — nothing left
    }

    @Test func backfillAlsoMigratesNotes() throws {
        let context = try makeContext()
        MemoryStore(context: context, embedder: OtherSpaceEmbedder()).saveNote("likes swift")
        let store = MemoryStore(context: context, embedder: MockEmbedder())
        #expect(store.backfill() == 1)
        let note = try #require(try context.fetch(FetchDescriptor<MemoryNote>()).first)
        #expect(note.embedderID == "mock-bag-of-words")
    }

    @Test func backfillStillEmbedsNeverEmbeddedRows() throws {
        let context = try makeContext()
        let m = Message(role: .user, text: "trip to paris", createdAt: Date())
        context.insert(m)
        try context.save()
        let store = MemoryStore(context: context, embedder: MockEmbedder())
        #expect(store.backfill() == 1)
        #expect(m.embedding != nil && m.embedderID == "mock-bag-of-words")
    }
}
