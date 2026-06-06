import Testing
import Foundation
@testable import FoundationChatKit

@MainActor
struct ConversationEngineTests {
    func makeEngine(_ provider: MockModelProvider) -> ConversationEngine {
        ConversationEngine(provider: provider, settings: GenerationSettings(instructions: "sys"),
                           now: { Date(timeIntervalSince1970: 0) })
    }

    @Test func sendProducesOneGrowingAssistantBubble() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["He", "Hello", "Hello!"]
        let engine = makeEngine(provider)
        await engine.send("hi")
        #expect(engine.messages.map(\.role) == [.user, .assistant])
        #expect(engine.messages.last?.text == "Hello!")
        #expect(engine.messages.last?.isStreaming == false)
        #expect(engine.isResponding == false)
    }

    @Test func budgetUpdatesAfterTurn() async {
        let provider = MockModelProvider()
        provider.exactCounts = true
        provider.session.scriptedSnapshots = ["abcd"]
        let engine = makeEngine(provider)
        await engine.send("xy")
        // instructions "sys"(3) + user "xy"(2) + assistant "abcd"(4) = 9
        #expect(engine.budget.usedTokens == 9)
        #expect(engine.budget.isExact == true)
    }

    @Test func overflowSeedsNewSessionFromCondensedEntries() async {
        let provider = MockModelProvider()
        provider.summarizeResult = "RECAP"
        provider.session.contextEntries = [
            ContextEntry(kind: .userPrompt, text: "first"),
            ContextEntry(kind: .modelResponse, text: "a"),
            ContextEntry(kind: .userPrompt, text: "b"),
            ContextEntry(kind: .modelResponse, text: "c"),
            ContextEntry(kind: .userPrompt, text: "d"),
            ContextEntry(kind: .modelResponse, text: "last"),
        ]
        provider.session.commitsEntriesOnFinish = false
        provider.session.scriptedSnapshots = ["partial"]
        provider.session.scriptedError = ChatError.contextOverflow
        provider.session.errorAfter = 1
        let engine = makeEngine(provider)
        await engine.send("hi")
        #expect(engine.messages.contains { $0.role == .systemNotice })
        #expect(engine.lastError == nil)
        // Recovery compacted older turns into a model recap, keeping the recent ones verbatim.
        #expect(provider.session.contextEntries.first?.text.contains("RECAP") == true)
        #expect(provider.session.contextEntries.count < 6)
        #expect(provider.session.contextEntries.last?.text == "last")
    }

    @Test func cancelAfterCompletionIsSafe() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["done"]
        let engine = makeEngine(provider)
        await engine.send("hi")
        engine.cancel()
        #expect(engine.isResponding == false)
        #expect(engine.messages.last?.text == "done")
    }

    @Test func guardrailErrorIsSurfaced() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["x"]
        provider.session.scriptedError = ChatError.guardrailViolation
        provider.session.errorAfter = 1
        let engine = makeEngine(provider)
        await engine.send("hi")
        #expect(engine.lastError == .guardrailViolation)
    }

    @Test func ignoresSendWhileResponding() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["done"]
        let engine = makeEngine(provider)
        engine.isResponding = true
        await engine.send("hi")
        #expect(engine.messages.isEmpty)
    }

    // MARK: - Automatic hybrid RAG (retrieve-before-generate)

    private func parisHit() -> MemoryHit {
        let record = MemoryRecord(messageID: UUID(), conversationID: UUID(),
                                  conversationTitle: "Trip", role: .user,
                                  text: "trip to paris", vector: [1, 0, 0])
        return MemoryHit(record: record, score: 0.9)
    }

    @Test func autoRAGInjectsRetrievedMemoryIntoStreamedPromptButNotBubble() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["pack a coat"]
        let hit = parisHit()
        let retrieval = ConversationEngine.MemoryRetrieval { _ in [hit] }
        let engine = ConversationEngine(
            provider: provider,
            settings: GenerationSettings(instructions: "sys"),
            memoryRetrieval: retrieval,
            now: { Date(timeIntervalSince1970: 0) }
        )
        await engine.send("what should I pack?")

        // The model received the AUGMENTED prompt (MockSessionHandle commits a .userPrompt
        // entry equal to the streamed prompt).
        let streamedPrompt = provider.session.contextEntries
            .first(where: { $0.kind == .userPrompt })?.text
        #expect(streamedPrompt?.contains("trip to paris") == true)
        // The marker/header proves injection happened (not just concatenation).
        #expect(streamedPrompt?.contains("Background from earlier chats (use only if directly relevant to the question; otherwise ignore):") == true)
        #expect(streamedPrompt?.contains("what should I pack?") == true)

        // The on-screen bubble stays RAW.
        let userBubble = engine.messages.first(where: { $0.role == .user })
        #expect(userBubble?.text == "what should I pack?")
        #expect(userBubble?.text.contains("trip to paris") == false)
    }

    @Test func noRetrieverLeavesPromptRaw() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["ok"]
        let engine = makeEngine(provider)  // no retriever
        await engine.send("plain prompt")

        let streamedPrompt = provider.session.contextEntries
            .first(where: { $0.kind == .userPrompt })?.text
        #expect(streamedPrompt == "plain prompt")
        #expect(streamedPrompt?.contains("Background from earlier chats (use only if directly relevant to the question; otherwise ignore):") == false)
        #expect(engine.messages.first(where: { $0.role == .user })?.text == "plain prompt")
    }

    @Test func emptyRetrievalLeavesPromptRaw() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["ok"]
        let retrieval = ConversationEngine.MemoryRetrieval { _ in [] }
        let engine = ConversationEngine(
            provider: provider,
            settings: GenerationSettings(instructions: "sys"),
            memoryRetrieval: retrieval,
            now: { Date(timeIntervalSince1970: 0) }
        )
        await engine.send("plain prompt")

        let streamedPrompt = provider.session.contextEntries
            .first(where: { $0.kind == .userPrompt })?.text
        #expect(streamedPrompt == "plain prompt")
        #expect(streamedPrompt?.contains("Background from earlier chats (use only if directly relevant to the question; otherwise ignore):") == false)
        #expect(engine.messages.first(where: { $0.role == .user })?.text == "plain prompt")
    }
}
