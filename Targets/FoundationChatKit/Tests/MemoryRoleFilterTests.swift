import Foundation
import SwiftData
import Testing
@testable import FoundationChatKit

/// Assistant messages are conversational filler, not durable user facts — they polluted retrieval
/// (travel small-talk injected into a food question on-device). Only USER messages feed the
/// conversation-snippet tier; durable facts still flow through curated MemoryNotes.
@MainActor
struct MemoryRoleFilterTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Conversation.self, Message.self, MemoryNote.self,
                                           configurations: config)
        return ModelContext(container)
    }

    @Test func indexSkipsAssistantMessages() throws {
        let context = try makeContext()
        let store = MemoryStore(context: context, embedder: MockEmbedder())
        let reply = Message(role: .assistant, text: "trip to paris sounds lovely", createdAt: Date())
        context.insert(reply)
        store.index(reply)
        #expect(reply.embedding == nil)
    }

    @Test func snapshotExcludesLegacyEmbeddedAssistantRows() throws {
        // Stores indexed before this fix contain embedded assistant rows — they must not
        // resurface as retrieval candidates.
        let context = try makeContext()
        let legacy = Message(role: .assistant, text: "trip to paris sounds lovely",
                             createdAt: Date(),
                             embedding: MemoryStore.archive(MockEmbedder().embed("trip to paris")!),
                             embedderID: "mock-bag-of-words")
        context.insert(legacy)
        try context.save()
        let store = MemoryStore(context: context, embedder: MockEmbedder())
        #expect(store.snapshot().isEmpty)
    }

    @Test func backfillSkipsAssistantMessages() throws {
        let context = try makeContext()
        let reply = Message(role: .assistant, text: "trip to paris sounds lovely", createdAt: Date())
        context.insert(reply)
        try context.save()
        let store = MemoryStore(context: context, embedder: MockEmbedder())
        #expect(store.backfill() == 0)
        #expect(reply.embedding == nil)
    }

    @Test func userMessagesStillIndexAndSurface() throws {
        let context = try makeContext()
        let store = MemoryStore(context: context, embedder: MockEmbedder())
        let fact = Message(role: .user, text: "trip to paris", createdAt: Date())
        context.insert(fact)
        store.index(fact)
        #expect(fact.embedding != nil)
        #expect(store.snapshot().count == 1)
    }
}
