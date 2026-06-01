import Testing
import Foundation
@testable import FoundationChatKit

@MainActor
final class PersistenceSpy {
    var recordedMessages: [ChatMessage] = []
    var resumeStateCount = 0
    var lastTokenCount = 0
    var persistence: ConversationEngine.ConversationPersistence {
        ConversationEngine.ConversationPersistence(
            recordMessage: { [weak self] in self?.recordedMessages.append($0) },
            recordResumeState: { [weak self] _, tokens in
                self?.resumeStateCount += 1
                self?.lastTokenCount = tokens
            }
        )
    }
}

@MainActor
struct ConversationEnginePersistenceTests {
    @Test func persistsUserThenAssistantThenResumeState() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["Hello!"]
        let spy = PersistenceSpy()
        let engine = ConversationEngine(provider: provider, settings: GenerationSettings(instructions: "sys"),
                                        persistence: spy.persistence, now: { Date(timeIntervalSince1970: 0) })
        await engine.send("hi")
        #expect(spy.recordedMessages.map(\.role) == [.user, .assistant])
        #expect(spy.recordedMessages.map(\.text) == ["hi", "Hello!"])
        #expect(spy.resumeStateCount == 1)
    }

    @Test func restoresFromContextEntries() {
        let provider = MockModelProvider()
        let engine = ConversationEngine(
            provider: provider,
            settings: GenerationSettings(),
            restoringEntries: [ContextEntry(kind: .userPrompt, text: "hi"),
                               ContextEntry(kind: .modelResponse, text: "hello")],
            now: { Date(timeIntervalSince1970: 0) })
        #expect(engine.messages.map(\.role) == [.user, .assistant])
        #expect(engine.messages.map(\.text) == ["hi", "hello"])
    }

    @Test func exposesContextEntriesAndTranscript() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["ok"]
        let engine = ConversationEngine(provider: provider, now: { Date(timeIntervalSince1970: 0) })
        await engine.send("hi")
        #expect(engine.contextEntries.map(\.text) == ["hi", "ok"])
        #expect(engine.encodedTranscript == nil)
    }
}
