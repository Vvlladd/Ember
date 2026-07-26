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
    /// Transient-failure simulation for retry tests: while > 0, EACH `stream` call throws
    /// `failureError` (after `errorAfter` snapshots) and decrements. Subsequent calls stream
    /// normally. Independent of `scriptedError` (which throws on every call).
    var failuresRemaining: Int = 0
    var failureError: Error?
    /// How many times `stream` has been invoked (so tests can assert a retry actually happened).
    private(set) var streamCallCount = 0
    /// Plan 10 WS2: capture the exact prompt the engine streamed (post-augmentation) so tests
    /// can assert memory-injection shaping. Set synchronously before the stream closure runs.
    var lastStreamedPrompt: String?
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
        streamCallCount += 1
        lastStreamedPrompt = prompt
        let snapshots = scriptedSnapshots
        // This call fails if a transient failure is budgeted, else falls back to the static error.
        let willFailTransiently = failuresRemaining > 0
        if willFailTransiently { failuresRemaining -= 1 }
        let error = willFailTransiently ? (failureError ?? scriptedError) : scriptedError
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
    /// Plan 10 WS4 — structured summary scripting. Separate captured field from the string
    /// `summarize` path's `capturedSummarizeInput` to avoid cross-method pollution.
    var scriptedStructuredSummary: ConversationSummary?
    private(set) var capturedStructuredSummarizeInput: String?
    /// Scripted result returned by `extractMemories(...)` (nil scripts the failure path).
    var extractedMemories: [String]? = []
    /// Captures the most recent userText passed to `extractMemories(...)`.
    private(set) var capturedExtractInput: String?

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
    func summarizeStructured(_ text: String) async -> ConversationSummary? {
        capturedStructuredSummarizeInput = text
        return scriptedStructuredSummary
    }
    func extractMemories(userText: String) async -> [String]? {
        capturedExtractInput = userText
        return extractedMemories
    }
}
