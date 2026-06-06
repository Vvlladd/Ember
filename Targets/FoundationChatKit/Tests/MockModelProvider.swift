import Foundation
import FoundationModels
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
    /// Scripted (toolCallText, toolOutputText) pairs injected into contextEntries on finish.
    var scriptedToolInteractions: [(call: String, output: String)] = []
    /// Facts the scripted model "decides" to save: on finish the mock invokes the REAL registered
    /// `SaveMemoryTool.call` for each, faithfully exercising its `buffer.add` side effect (the mock
    /// does NOT otherwise execute registered tools).
    var scriptedSaveMemoryFacts: [String] = []
    /// Tools handed to this session by the provider's `makeSession`, so scripted interactions can
    /// invoke the real registered tool implementations.
    var registeredTools: [any Tool] = []
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
                // Faithfully invoke the real registered saveMemory tool for any scripted facts.
                // Surface (don't swallow) tool throws into the stream, matching how the surrounding
                // code finishes the stream — so a future throw from SaveMemoryTool.call is visible.
                for fact in self.scriptedSaveMemoryFacts {
                    if let save = self.registeredTools.first(where: { $0.name == "saveMemory" }) as? SaveMemoryTool {
                        do {
                            _ = try await save.call(arguments: .init(fact: fact))
                        } catch {
                            self.isResponding = false
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                }
                if commits {
                    self.contextEntries.append(ContextEntry(kind: .userPrompt, text: prompt))
                    for interaction in self.scriptedToolInteractions {
                        self.contextEntries.append(ContextEntry(kind: .toolCall, text: interaction.call))
                        self.contextEntries.append(ContextEntry(kind: .toolOutput, text: interaction.output))
                    }
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
    var exactAsyncCount: Bool = false
    let session = MockSessionHandle()
    var recordedTools: [any Tool] = []
    var titleResult: String?
    var summarizeResult: String?
    /// Captures the most recent text passed to `summarize(_:)` so tests can assert what the
    /// compactor fed into the summary (e.g. that recalled memory was excluded).
    private(set) var capturedSummarizeInput: String?
    /// Scripted result returned by `extractMemories(...)` (nil scripts the failure path).
    var extractedMemories: [String]? = []
    /// Captures the most recent (userText, assistantText) passed to `extractMemories(...)`.
    private(set) var capturedExtractInput: (userText: String, assistantText: String)?

    func tokenCount(for text: String) -> Int? { exactCounts ? text.count : nil }
    func exactTokenCount(for text: String) async -> Int? {
        (exactCounts || exactAsyncCount) ? text.count : nil
    }
    func makeSession(settings: GenerationSettings, tools: [any Tool], restoring encodedTranscript: Data?) -> any ChatSessionHandle {
        recordedTools = tools
        session.registeredTools = tools
        return session
    }
    func makeSession(settings: GenerationSettings, tools: [any Tool], seeding entries: [ContextEntry]) -> any ChatSessionHandle {
        recordedTools = tools
        session.registeredTools = tools
        session.contextEntries = entries
        return session
    }
    func generateTitle(forFirstExchange exchange: TitleSeed) async -> String? { titleResult }
    func summarize(_ text: String) async -> String? { capturedSummarizeInput = text; return summarizeResult }
    func extractMemories(userText: String, assistantText: String) async -> [String]? {
        capturedExtractInput = (userText, assistantText)
        return extractedMemories
    }
}
