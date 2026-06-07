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

    /// A transient on-device generation failure is retried ONCE and then succeeds — the user sees
    /// the reply, not an error.
    @Test func retriesOnceOnTransientGenerationError() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["Hello, retried"]
        provider.session.errorAfter = 0
        provider.session.failuresRemaining = 1
        provider.session.failureError = ChatError.generationInterrupted
        let engine = makeEngine(provider)
        await engine.send("hi")
        #expect(provider.session.streamCallCount == 2)        // failed once, retried once
        #expect(engine.lastError == nil)
        #expect(engine.messages.last?.role == .assistant)
        #expect(engine.messages.last?.text == "Hello, retried")
    }

    /// If the transient failure persists past the single retry, it surfaces as the friendly error.
    @Test func surfacesTransientErrorAfterRetryExhausted() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["partial"]
        provider.session.errorAfter = 0
        provider.session.failuresRemaining = 2                // initial + retry both fail
        provider.session.failureError = ChatError.generationInterrupted
        let engine = makeEngine(provider)
        await engine.send("hi")
        #expect(provider.session.streamCallCount == 2)        // one retry, then give up
        #expect(engine.lastError == .generationInterrupted)
    }

    /// A NON-retryable error (e.g. guardrail) is surfaced immediately, with no retry.
    @Test func doesNotRetryNonRetryableError() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["x"]
        provider.session.errorAfter = 0
        provider.session.failuresRemaining = 1
        provider.session.failureError = ChatError.guardrailViolation
        let engine = makeEngine(provider)
        await engine.send("hi")
        #expect(provider.session.streamCallCount == 1)        // no retry
        #expect(engine.lastError == .guardrailViolation)
    }

    // MARK: - Plan 10 WS2: injection knobs (inject-fewer / truncate)

    @Test func injectsAtMostMaxHitsAndTruncates() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["ok"]
        let longFact = String(repeating: "q", count: 400)
        let hits = [
            MemoryHit(record: MemoryRecord(messageID: UUID(), conversationID: UUID(),
                conversationTitle: "Past", role: .user, text: longFact, vector: [], source: .note), score: 0.9),
            MemoryHit(record: MemoryRecord(messageID: UUID(), conversationID: UUID(),
                conversationTitle: "Past", role: .user, text: "second", vector: [], source: .note), score: 0.8),
            MemoryHit(record: MemoryRecord(messageID: UUID(), conversationID: UUID(),
                conversationTitle: "Past", role: .user, text: "third", vector: [], source: .note), score: 0.7),
            MemoryHit(record: MemoryRecord(messageID: UUID(), conversationID: UUID(),
                conversationTitle: "Past", role: .user, text: "fourth", vector: [], source: .note), score: 0.6)
        ]
        let settings = GenerationSettings(memoryInjectionMaxHits: 2, memoryInjectionMaxCharsPerHit: 60)
        let retrieval = ConversationEngine.MemoryRetrieval { _ in hits }
        let engine = ConversationEngine(provider: provider, settings: settings, memoryRetrieval: retrieval)

        await engine.send("recall")

        let sent = provider.session.lastStreamedPrompt ?? ""
        #expect(sent.contains("\u{2026}"))             // first hit truncated
        #expect(!sent.contains(longFact))              // full long fact not present
        #expect(sent.contains("second"))               // 2nd hit kept
        #expect(!sent.contains("third"))               // 3rd hit dropped (maxHits 2)
        #expect(sent.hasSuffix("recall"))              // raw prompt preserved at end
    }

    // MARK: - Plan 10 WS2 (2.4b): injected memory block accounted as a budget line

    @Test func memoryBlockShowsAsBudgetLineAfterTurn() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["hi", "hello"]
        let hits = [MemoryHit(record: MemoryRecord(messageID: UUID(), conversationID: UUID(),
            conversationTitle: "Past", role: .user, text: "User loves Lisbon", vector: [], source: .note), score: 0.9)]
        let retrieval = ConversationEngine.MemoryRetrieval { _ in hits }
        let engine = ConversationEngine(provider: provider, memoryRetrieval: retrieval)

        await engine.send("where to?")

        let memoryLine = engine.budget.lines.first { $0.label == "Retrieved memory" }
        #expect(memoryLine != nil)
        #expect((memoryLine?.tokens ?? 0) > 0)
    }

    @Test func memoryBlockLineClearedOnNextTurnWithNoHits() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["one", "two"]
        var hitsToReturn = [MemoryHit(record: MemoryRecord(messageID: UUID(), conversationID: UUID(),
            conversationTitle: "Past", role: .user, text: "User loves Lisbon", vector: [], source: .note), score: 0.9)]
        let retrieval = ConversationEngine.MemoryRetrieval { _ in hitsToReturn }
        let engine = ConversationEngine(provider: provider, memoryRetrieval: retrieval)
        await engine.send("first")
        hitsToReturn = []                 // no memory next turn
        await engine.send("second")
        #expect(engine.budget.lines.first { $0.label == "Retrieved memory" } == nil)
    }
}
