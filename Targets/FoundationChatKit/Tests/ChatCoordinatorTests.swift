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
}
