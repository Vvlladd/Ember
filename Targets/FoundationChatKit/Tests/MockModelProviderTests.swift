import Testing
import Foundation
@testable import FoundationChatKit

@MainActor
struct MockModelProviderTests {
    @Test func streamsScriptedSnapshotsThenCommits() async throws {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["He", "Hello"]
        var received: [String] = []
        for try await snap in provider.session.stream(prompt: "hi") { received.append(snap) }
        #expect(received == ["He", "Hello"])
        #expect(provider.session.contextEntries.map(\.text) == ["hi", "Hello"])
        #expect(provider.session.isResponding == false)
    }

    @Test func throwsScriptedError() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["x"]
        provider.session.scriptedError = ChatError.contextOverflow
        provider.session.errorAfter = 1
        await #expect(throws: ChatError.self) {
            for try await _ in provider.session.stream(prompt: "hi") {}
        }
    }

    @Test func extractMemoriesReturnsScriptedFacts() async {
        let provider = MockModelProvider()
        provider.extractedMemories = ["User is planning a trip to Lisbon"]
        let facts = await provider.extractMemories(
            userText: "I'm planning a trip to Lisbon next month",
            assistantText: "That sounds great! Lisbon is lovely.")
        #expect(facts == ["User is planning a trip to Lisbon"])
    }

    @Test func extractMemoriesCapturesInputs() async {
        let provider = MockModelProvider()
        _ = await provider.extractMemories(
            userText: "My name is Vlad",
            assistantText: "Nice to meet you, Vlad.")
        #expect(provider.capturedExtractInput?.userText == "My name is Vlad")
        #expect(provider.capturedExtractInput?.assistantText == "Nice to meet you, Vlad.")
    }

    @Test func extractMemoriesDefaultsToEmpty() async {
        let provider = MockModelProvider()
        let facts = await provider.extractMemories(userText: "hi", assistantText: "hello")
        #expect(facts == [])
    }
}
