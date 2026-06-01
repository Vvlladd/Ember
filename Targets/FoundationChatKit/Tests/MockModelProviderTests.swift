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
}
