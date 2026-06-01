import Foundation
@testable import FoundationChatKit

/// Deterministic test double. Scripts streaming snapshots and errors so the engine can
/// be tested without an Apple-Intelligence device.
@MainActor
final class MockSessionHandle: ChatSessionHandle {
    var isResponding: Bool = false
    var contextEntries: [ContextEntry] = []

    /// Cumulative snapshots to emit for the next `stream` call, e.g. ["He","Hello"].
    var scriptedSnapshots: [String] = []
    /// If set, the stream throws this after emitting `errorAfter` snapshots.
    var scriptedError: Error?
    var errorAfter: Int = 0
    var commitsEntriesOnFinish = true
    private(set) var prewarmCount = 0

    func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        let snapshots = scriptedSnapshots
        let error = scriptedError
        let errorAfter = self.errorAfter
        let commits = commitsEntriesOnFinish
        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                self.isResponding = true
                var emitted = 0
                for snap in snapshots {
                    continuation.yield(snap)
                    emitted += 1
                    if let error, emitted >= errorAfter {
                        self.isResponding = false
                        continuation.finish(throwing: error)
                        return
                    }
                }
                if commits {
                    self.contextEntries.append(ContextEntry(kind: .userPrompt, text: prompt))
                    self.contextEntries.append(ContextEntry(kind: .modelResponse, text: snapshots.last ?? ""))
                }
                self.isResponding = false
                continuation.finish()
            }
        }
    }

    func respond(prompt: String) async throws -> String {
        if let scriptedError { throw scriptedError }
        let text = scriptedSnapshots.last ?? ""
        if commitsEntriesOnFinish {
            contextEntries.append(ContextEntry(kind: .userPrompt, text: prompt))
            contextEntries.append(ContextEntry(kind: .modelResponse, text: text))
        }
        return text
    }

    func prewarm() { prewarmCount += 1 }
    func encodedTranscript() -> Data? { nil }
}

@MainActor
final class MockModelProvider: ChatModelProvider {
    var availability: ModelAvailability = .available
    var maxContextTokens: Int = 4096
    var exactCounts: Bool = false
    let session = MockSessionHandle()

    func tokenCount(for text: String) -> Int? { exactCounts ? text.count : nil }
    func makeSession(settings: GenerationSettings, restoring encodedTranscript: Data?) -> any ChatSessionHandle { session }
}
