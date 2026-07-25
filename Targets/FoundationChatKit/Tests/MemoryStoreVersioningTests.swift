import Foundation
import SwiftData
import Testing
@testable import FoundationChatKit

/// A second vector space with a DIFFERENT identity — same bag-of-words math, different id.
struct OtherSpaceEmbedder: TextEmbedder {
    let identity = EmbedderIdentity(id: "other-space", dimension: 8)
    private let base = MockEmbedder()
    func embed(_ text: String, role: EmbeddingRole) -> [Float]? { base.embed(text, role: role) }
}

@MainActor
struct MemoryStoreVersioningTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Conversation.self, Message.self, MemoryNote.self,
                                           configurations: config)
        return ModelContext(container)
    }

    @Test func writesTagTheActiveEmbedderID() throws {
        let context = try makeContext()
        let store = MemoryStore(context: context, embedder: MockEmbedder())
        let message = Message(role: .user, text: "trip to paris", createdAt: Date())
        context.insert(message)
        store.index(message)
        #expect(message.embedderID == "mock-bag-of-words")
        store.saveNote("likes swift")
        let note = try #require(try context.fetch(FetchDescriptor<MemoryNote>()).first)
        #expect(note.embedderID == "mock-bag-of-words")
    }

    @Test func mismatchedSpaceVectorIsExcludedFromCosine() throws {
        let context = try makeContext()
        // Written in one space…
        MemoryStore(context: context, embedder: MockEmbedder()).saveNote("trip to paris")
        // …read under another: vector must be treated as absent (empty), not compared.
        let store = MemoryStore(context: context, embedder: OtherSpaceEmbedder())
        let record = try #require(store.snapshot().first)
        #expect(record.vector.isEmpty)
    }

    @Test func matchingSpaceVectorSurvivesSnapshot() throws {
        let context = try makeContext()
        MemoryStore(context: context, embedder: MockEmbedder()).saveNote("trip to paris")
        let store = MemoryStore(context: context, embedder: MockEmbedder())
        let record = try #require(store.snapshot().first)
        #expect(!record.vector.isEmpty)
    }

    @Test func nilEmbedderIDCountsAsLegacyNL() throws {
        let context = try makeContext()
        // Simulate a pre-versioning row: embedding present, embedderID nil.
        let legacy = MemoryNote(text: "trip to paris", createdAt: Date(),
                                embedding: MemoryStore.archive([1, 0, 0, 0, 0, 0, 0, 0]))
        context.insert(legacy)
        try context.save()
        // Under an embedder claiming the legacy identity, the vector is live…
        struct LegacyClaimer: TextEmbedder {
            let identity = EmbedderIdentity.legacyNLEnglish
            func embed(_ text: String, role: EmbeddingRole) -> [Float]? { nil }
        }
        let nlStore = MemoryStore(context: context, embedder: LegacyClaimer())
        #expect(!(try #require(nlStore.snapshot().first)).vector.isEmpty)
        // …under any other embedder it is dead.
        let gemmaStore = MemoryStore(context: context, embedder: MockEmbedder())
        #expect((try #require(gemmaStore.snapshot().first)).vector.isEmpty)
    }

    @Test func indexReembedsStaleMessage() throws {
        let context = try makeContext()
        let message = Message(role: .user, text: "trip to paris", createdAt: Date())
        context.insert(message)
        MemoryStore(context: context, embedder: OtherSpaceEmbedder()).index(message)
        #expect(message.embedderID == "other-space")
        MemoryStore(context: context, embedder: MockEmbedder()).index(message)  // stale → re-embed
        #expect(message.embedderID == "mock-bag-of-words")
    }
}
