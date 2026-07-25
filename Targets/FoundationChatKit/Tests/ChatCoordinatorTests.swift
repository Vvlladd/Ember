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
    private func makeWithMemory(autoExtract: Bool = true) throws
        -> (ChatCoordinator, MockModelProvider, MemoryStore) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Conversation.self, Message.self, MemoryNote.self,
                                           configurations: config)
        let context = ModelContext(container)
        let store = ConversationStore(context: context)
        let memory = MemoryStore(context: context, embedder: MockEmbedder())
        let provider = MockModelProvider()
        let coord = ChatCoordinator(provider: provider, store: store,
                                    settings: GenerationSettings(instructions: "sys",
                                                                 autoExtractMemories: autoExtract),
                                    modelVersionTag: "v1", memory: memory,
                                    now: { Date(timeIntervalSince1970: 0) })
        return (coord, provider, memory)
    }

    /// Regression: the migration backfill must wait for the embedder to finish loading. An
    /// asynchronously-loading embedder (EmbeddingGemma) embeds nothing until it is ready, so a
    /// backfill fired synchronously from `init` migrates zero rows — and never runs again,
    /// leaving every stored vector permanently outside the active space.
    @Test func initBackfillsOnceTheEmbedderIsReady() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Conversation.self, Message.self, MemoryNote.self,
                                           configurations: config)
        let context = ModelContext(container)
        let message = Message(role: .user, text: "trip to paris", createdAt: Date())
        context.insert(message)
        try context.save()

        let embedder = DeferredReadyEmbedder()
        let memory = MemoryStore(context: context, embedder: embedder)
        let coord = ChatCoordinator(provider: MockModelProvider(), store: ConversationStore(context: context),
                                    memory: memory, now: { Date(timeIntervalSince1970: 0) })
        #expect(coord.conversations.isEmpty)   // nothing seeded; keeps `coord` alive past init
        #expect(message.embedding == nil)      // not migrated yet — the embedder is still loading

        embedder.finishLoading()
        for _ in 0..<100 where message.embedderID != embedder.identity.id { await Task.yield() }
        #expect(message.embedderID == embedder.identity.id)
        #expect(message.embedding != nil)
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

    /// Plan 9: with auto-extraction enabled (default), the model's scripted salient facts are
    /// persisted as `.note` records after the reply renders — no explicit `saveMemory` needed.
    @Test func sendAutoExtractsSalientFactsToNotes() async throws {
        let (coord, provider, memory) = try makeWithMemory()
        provider.session.scriptedSnapshots = ["ok"]
        provider.extractedMemories = ["User is planning a trip to Lisbon"]
        coord.newConversation()
        await coord.send("I'm planning a trip to Lisbon")
        #expect(memory.snapshot().contains {
            $0.source == .note && $0.text == "User is planning a trip to Lisbon"
        })
        // The load-bearing contract: the user text and the FINAL assistant reply reach the provider.
        #expect(provider.capturedExtractInput?.userText == "I'm planning a trip to Lisbon")
        #expect(provider.capturedExtractInput?.assistantText == "ok")
    }

    /// With the setting off, the same scripted facts are never persisted — and the gate
    /// short-circuits so the provider is never even asked to extract.
    @Test func sendDoesNotAutoExtractWhenSettingOff() async throws {
        let (coord, provider, memory) = try makeWithMemory(autoExtract: false)
        provider.session.scriptedSnapshots = ["ok"]
        provider.extractedMemories = ["User is planning a trip to Lisbon"]
        coord.newConversation()
        await coord.send("I'm planning a trip to Lisbon")
        #expect(!memory.snapshot().contains {
            $0.source == .note && $0.text == "User is planning a trip to Lisbon"
        })
        #expect(provider.capturedExtractInput == nil)
    }

    /// De-dup across turns: the same fact extracted on two turns yields exactly ONE note
    /// (auto-extraction routes through `saveNoteIfNovel`).
    @Test func sendAutoExtractDeduplicatesAcrossTurns() async throws {
        let (coord, provider, memory) = try makeWithMemory()
        provider.session.scriptedSnapshots = ["ok"]
        provider.extractedMemories = ["User is planning a trip to Lisbon"]
        coord.newConversation()
        await coord.send("I'm planning a trip to Lisbon")
        await coord.send("Did I mention my Lisbon trip")
        let matches = memory.snapshot().filter {
            $0.source == .note && $0.text == "User is planning a trip to Lisbon"
        }
        #expect(matches.count == 1)
    }

    /// A note that shares surface words with the query but contains NO MockEmbedder-vocabulary
    /// word, so the query is unembeddable (cosine path early-returned / scored 0). Proves the
    /// retriever now passes the raw query + lexicalWeight through MemoryStore.search so word-overlap
    /// recall works even when the embedder yields no vector. (lastStreamedPrompt added in WS2 2.4a.)
    @Test func wordOverlapQueryRetrievesViaHybridPath() async throws {
        let (coord, provider, memory) = try makeWithMemory()
        memory.saveNote("User is moving house and needs boxes for the relocate")
        coord.newConversation()
        provider.session.scriptedSnapshots = ["Pack light."]

        await coord.send("should I get boxes for moving and relocate")

        let sent = provider.session.lastStreamedPrompt ?? ""
        #expect(sent.contains("moving house"))
    }
}
