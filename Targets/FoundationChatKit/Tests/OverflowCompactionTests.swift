import Testing
import Foundation
@testable import FoundationChatKit

@MainActor
struct OverflowCompactionTests {
    @Test func proactivelyCompactsBeforeOverflow() async {
        let provider = MockModelProvider()
        provider.maxContextTokens = 60
        provider.scriptedStructuredSummary = ConversationSummary(
            summary: "RECAP", keyTopics: [], userPreferences: [])
        let seeded = (0..<8).map { ContextEntry(kind: .userPrompt, text: "some earlier message number \($0)") }
        provider.session.contextEntries = seeded
        provider.session.scriptedSnapshots = ["ok"]
        let engine = ConversationEngine(
            provider: provider,
            settings: GenerationSettings(instructions: "sys", reservedReplyTokens: 20),
            restoringEntries: seeded,
            now: { Date(timeIntervalSince1970: 0) })
        await engine.send("a brand new question that needs room")
        #expect(engine.messages.contains { $0.role == .systemNotice && $0.text.contains("summarized to make room") })
    }
    @Test func reactiveRecoveryUsesCompactor() async {
        let provider = MockModelProvider()
        provider.scriptedStructuredSummary = ConversationSummary(
            summary: "RECAP", keyTopics: [], userPreferences: [])
        let seeded = (0..<8).map { ContextEntry(kind: .userPrompt, text: "m\($0)") }
        provider.session.contextEntries = seeded
        provider.session.scriptedSnapshots = ["partial"]
        provider.session.scriptedError = ChatError.contextOverflow
        provider.session.errorAfter = 1
        let engine = ConversationEngine(provider: provider, restoringEntries: seeded,
                                        now: { Date(timeIntervalSince1970: 0) })
        await engine.send("hi")
        #expect(engine.messages.contains { $0.role == .systemNotice && $0.text.contains("compacted to keep the chat going") })
    }
}
