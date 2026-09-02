import Testing
@testable import EmberScope

@MainActor
struct PreviewFixturesTests {
    @Test func previewStoreIsRichEnoughForEveryScreen() {
        let store = ScopeStore.preview
        #expect(store.sessions.count >= 2)
        #expect(store.sessions.contains { $0.latestSnapshot != nil && !$0.requests.isEmpty && !$0.toolCalls.isEmpty })
        #expect(!store.errors.isEmpty)
        #expect(!store.tools.isEmpty)
        #expect(store.modelStatus != nil)
        #expect(store.timeline.count > 10)
        #expect(store.sessions.contains { !$0.notes.isEmpty })
    }
}
