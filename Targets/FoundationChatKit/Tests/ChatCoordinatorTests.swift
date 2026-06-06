import Testing
import Foundation
import SwiftData
@testable import FoundationChatKit

@MainActor
struct ChatCoordinatorTests {
    func make() throws -> (ChatCoordinator, MockModelProvider) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Conversation.self, Message.self, configurations: config)
        let store = ConversationStore(context: ModelContext(container))
        let provider = MockModelProvider()
        let coord = ChatCoordinator(provider: provider, store: store,
                                    settings: GenerationSettings(instructions: "sys"),
                                    modelVersionTag: "v1", now: { Date(timeIntervalSince1970: 0) })
        return (coord, provider)
    }

    @Test func newConversationCreatesSelectsAndBuildsEngine() throws {
        let (coord, _) = try make()
        coord.newConversation()
        #expect(coord.conversations.count == 1)
        #expect(coord.selectedID != nil)
        #expect(coord.engine != nil)
    }

    @Test func sendPersistsMessagesAndTitle() async throws {
        let (coord, provider) = try make()
        provider.session.scriptedSnapshots = ["Hello there friend"]
        coord.newConversation()
        await coord.send("How are you")
        let convo = coord.conversations.first!
        #expect(convo.orderedMessages.map(\.role) == [.user, .assistant])
        #expect(convo.orderedMessages.map(\.text) == ["How are you", "Hello there friend"])
        #expect(convo.title == "How are you")
    }

    @Test func reopeningRestoresPriorMessagesFromStore() async throws {
        let (coord, provider) = try make()
        provider.session.scriptedSnapshots = ["hello"]
        coord.newConversation()
        await coord.send("hi")
        let id = coord.selectedID!
        coord.select(nil)
        #expect(coord.engine == nil)
        provider.session.contextEntries = []   // prove restore comes from the store, not leftover mock state
        coord.select(id)
        #expect(coord.engine?.messages.map(\.text) == ["hi", "hello"])
    }

    @Test func deleteRemovesAndDeselects() throws {
        let (coord, _) = try make()
        coord.newConversation()
        let id = coord.selectedID!
        coord.deleteConversation(id)
        #expect(coord.conversations.isEmpty)
        #expect(coord.engine == nil)
    }

    @Test func firstExchangeAppliesGeneratedTitle() async throws {
        let (coord, provider) = try make()
        provider.session.scriptedSnapshots = ["Sure, here's a plan."]
        provider.titleResult = "Weekend Trip Plan"
        coord.newConversation()
        await coord.send("help me plan a weekend trip")
        #expect(coord.conversations.first?.title == "Weekend Trip Plan")
    }

    @Test func nilTitleKeepsDeterministicTitle() async throws {
        let (coord, provider) = try make()
        provider.session.scriptedSnapshots = ["ok"]
        provider.titleResult = nil
        coord.newConversation()
        await coord.send("hello there friend")
        #expect(coord.conversations.first?.title == "hello there friend")
    }

    @Test func titleNotRegeneratedOnSecondTurn() async throws {
        let (coord, provider) = try make()
        provider.session.scriptedSnapshots = ["a"]
        provider.titleResult = "First Title"
        coord.newConversation()
        await coord.send("first message")
        provider.titleResult = "Second Title"
        await coord.send("second message")
        #expect(coord.conversations.first?.title == "First Title")
    }

    @Test func refreshAvailabilityPicksUpProviderChange() throws {
        let (coord, provider) = try make()
        #expect(coord.availability == .available)
        provider.availability = .unavailable(.modelNotReady)
        coord.refreshAvailability()
        #expect(coord.availability == .unavailable(.modelNotReady))
    }

    @Test func renameSetsCustomTitle() throws {
        let (coord, _) = try make()
        coord.newConversation()
        let id = coord.selectedID!
        coord.rename(id, to: "  My Chat  ")
        #expect(coord.conversations.first?.title == "My Chat")
    }
    @Test func autoTitleDoesNotClobberRenamed() async throws {
        let (coord, provider) = try make()
        provider.session.scriptedSnapshots = ["ok"]
        provider.titleResult = "Generated"
        coord.newConversation()
        let id = coord.selectedID!
        coord.rename(id, to: "Manual")
        await coord.send("hello there")
        #expect(coord.conversations.first?.title == "Manual")
    }
    @Test func visibleConversationsFiltersBySearch() async throws {
        let (coord, provider) = try make()
        provider.session.scriptedSnapshots = ["ok"]
        coord.newConversation(); await coord.send("apples")
        coord.newConversation(); await coord.send("oranges")
        coord.searchText = "apple"
        #expect(coord.visibleConversations.count == 1)
    }

    @MainActor
    private func makeWithMemory() throws -> (ChatCoordinator, MockModelProvider, MemoryStore) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Conversation.self, Message.self, MemoryNote.self,
                                           configurations: config)
        let context = ModelContext(container)
        let store = ConversationStore(context: context)
        let memory = MemoryStore(context: context, embedder: MockEmbedder())
        let provider = MockModelProvider()
        let coord = ChatCoordinator(provider: provider, store: store,
                                    settings: GenerationSettings(instructions: "sys"),
                                    modelVersionTag: "v1", memory: memory,
                                    now: { Date(timeIntervalSince1970: 0) })
        return (coord, provider, memory)
    }

    @Test func registersMemorySearchTool() throws {
        let (coord, provider, _) = try makeWithMemory()
        coord.newConversation()
        #expect(provider.recordedTools.contains { $0.name == "searchMemory" })
    }
    @Test func sendIndexesMessages() async throws {
        let (coord, provider, memory) = try makeWithMemory()
        provider.session.scriptedSnapshots = ["ok"]
        coord.newConversation()
        await coord.send("trip to paris")
        #expect(memory.snapshot().contains { $0.text == "trip to paris" })
    }

    @Test func registersSaveMemoryTool() throws {
        let (coord, provider, _) = try makeWithMemory()
        coord.newConversation()
        #expect(provider.recordedTools.contains { $0.name == "saveMemory" })
    }

    /// End-to-end drain: the mock session invokes the REAL registered `SaveMemoryTool.call`
    /// during the turn (buffering the fact), and the coordinator drains the buffer after
    /// `send`, persisting it via `MemoryStore.saveNote`. Asserts the note then appears in
    /// the snapshot as a `.note` source — proving the `buffer.drain() -> saveNote` wiring.
    @Test func sendDrainsBufferedFactsToNotes() async throws {
        let (coord, provider, memory) = try makeWithMemory()
        provider.session.scriptedSnapshots = ["ok"]
        provider.session.scriptedSaveMemoryFacts = ["trip to paris"]
        coord.newConversation()
        await coord.send("remember my plans")
        #expect(memory.snapshot().contains { $0.source == .note && $0.text == "trip to paris" })
    }
}
