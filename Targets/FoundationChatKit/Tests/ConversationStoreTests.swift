import Testing
import Foundation
import SwiftData
@testable import FoundationChatKit

@MainActor
struct ConversationStoreTests {
    func makeStore() throws -> ConversationStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Conversation.self, Message.self, configurations: config)
        // Use ModelContext(container) rather than container.mainContext to avoid a
        // macOS 26 / Swift 6.3 runtime trap when @Model types are used across module
        // boundaries in a test bundle.
        return ConversationStore(context: ModelContext(container))
    }

    @Test func createAndFetch() async throws {
        let store = try makeStore()
        let convo = store.createConversation(now: Date(timeIntervalSince1970: 0))
        let all = try store.allConversations()
        #expect(all.count == 1)
        #expect(all.first?.id == convo.id)
        #expect(convo.title == "New Chat")
    }

    @Test func appendMessageUpdatesTitleFromFirstPrompt() async throws {
        let store = try makeStore()
        let convo = store.createConversation(now: Date(timeIntervalSince1970: 0))
        store.appendMessage(role: .user, text: "How do I parse JSON in Swift quickly", to: convo, now: Date(timeIntervalSince1970: 1))
        #expect(convo.title == "How do I parse JSON in Swift")
        #expect(convo.orderedMessages.count == 1)
    }

    @Test func deleteRemovesConversation() async throws {
        let store = try makeStore()
        let convo = store.createConversation(now: Date(timeIntervalSince1970: 0))
        store.delete(convo)
        #expect(try store.allConversations().isEmpty)
    }

    @Test func loadEntriesPrefersMessagesWhenNoTranscript() async throws {
        let store = try makeStore()
        let convo = store.createConversation(now: Date(timeIntervalSince1970: 0))
        store.appendMessage(role: .user, text: "hi", to: convo, now: Date(timeIntervalSince1970: 1))
        store.appendMessage(role: .assistant, text: "hello", to: convo, now: Date(timeIntervalSince1970: 2))
        let entries = store.contextEntries(for: convo)
        #expect(entries.map(\.kind) == [.userPrompt, .modelResponse])
        #expect(entries.map(\.text) == ["hi", "hello"])
    }

    @Test func systemNoticeMessagesAreNotContextEntries() async throws {
        let store = try makeStore()
        let convo = store.createConversation(now: Date(timeIntervalSince1970: 0))
        store.appendMessage(role: .user, text: "hi", to: convo, now: Date(timeIntervalSince1970: 1))
        store.appendMessage(role: .systemNotice, text: "Context compacted", to: convo, now: Date(timeIntervalSince1970: 2))
        store.appendMessage(role: .assistant, text: "hello", to: convo, now: Date(timeIntervalSince1970: 3))
        #expect(store.contextEntries(for: convo).map(\.text) == ["hi", "hello"])
    }

    @Test func searchMatchesTitleAndMessageCaseInsensitive() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Conversation.self, Message.self, configurations: config)
        let store = ConversationStore(context: ModelContext(container))
        let c1 = store.createConversation(now: Date(timeIntervalSince1970: 0))
        store.setTitle("Trip Planning", for: c1)
        let c2 = store.createConversation(now: Date(timeIntervalSince1970: 0))
        store.appendMessage(role: .user, text: "Quantum physics", to: c2, now: Date(timeIntervalSince1970: 0))
        #expect(store.search("trip").map(\.id) == [c1.id])
        #expect(store.search("QUANTUM").map(\.id) == [c2.id])
        #expect(store.search("   ").count == 2)
    }
    @Test func setTitleCustomMarksFlag() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Conversation.self, Message.self, configurations: config)
        let store = ConversationStore(context: ModelContext(container))
        let convo = store.createConversation(now: Date(timeIntervalSince1970: 0))
        store.setTitle("My Title", for: convo, custom: true)
        #expect(convo.title == "My Title")
        #expect(convo.titleIsCustom == true)
    }
}
