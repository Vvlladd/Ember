import Foundation
import SwiftData
import Testing
@testable import FoundationChatKit

@MainActor
struct TextEmbedderRoleTests {
    private func makeStore(_ embedder: any TextEmbedder) throws -> MemoryStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Conversation.self, Message.self, MemoryNote.self,
                                           configurations: config)
        return MemoryStore(context: ModelContext(container), embedder: embedder)
    }

    @Test func indexEmbedsAsDocument() throws {
        let recorder = RoleRecordingEmbedder()
        let store = try makeStore(recorder)
        store.index(Message(role: .user, text: "trip to paris", createdAt: Date()))
        #expect(recorder.recordedRoles == [.document])
    }

    @Test func saveNoteEmbedsAsDocument() throws {
        let recorder = RoleRecordingEmbedder()
        let store = try makeStore(recorder)
        store.saveNote("likes swift code")
        #expect(recorder.recordedRoles == [.document])
    }

    @Test func nlEmbedderHasLegacyIdentityForEnglish() {
        #expect(NLTextEmbedder().identity.id == EmbedderIdentity.legacyNLEnglish.id)
    }

    @Test func mockIdentityIsStable() {
        #expect(MockEmbedder().identity == EmbedderIdentity(id: "mock-bag-of-words", dimension: 8))
    }
}
