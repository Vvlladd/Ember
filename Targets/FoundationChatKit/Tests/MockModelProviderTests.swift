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
            userText: "I'm planning a trip to Lisbon next month")
        #expect(facts == ["User is planning a trip to Lisbon"])
    }

    @Test func extractMemoriesCapturesInputs() async {
        let provider = MockModelProvider()
        _ = await provider.extractMemories(userText: "My name is Vlad")
        #expect(provider.capturedExtractInput == "My name is Vlad")
    }

    @Test func extractMemoriesDefaultsToEmpty() async {
        let provider = MockModelProvider()
        let facts = await provider.extractMemories(userText: "hi")
        #expect(facts == [])
    }

    @Test func mockSummarizeStructuredReturnsScripted() async {
        let provider = MockModelProvider()
        provider.scriptedStructuredSummary = ConversationSummary(
            summary: "A planning chat.", keyTopics: ["Lisbon"],
            userPreferences: ["User prefers window seats"])
        let result = await provider.summarizeStructured("long history text")
        #expect(result?.summary == "A planning chat.")
        #expect(result?.userPreferences == ["User prefers window seats"])
        #expect(provider.capturedStructuredSummarizeInput == "long history text")
    }

    @Test func mockSummarizeStructuredNilByDefault() async {
        let provider = MockModelProvider()
        #expect(await provider.summarizeStructured("x") == nil)
    }
}
