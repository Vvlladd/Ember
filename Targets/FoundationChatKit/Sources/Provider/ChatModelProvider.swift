import Foundation
import FoundationModels

/// A minimal seed for generating a conversation title from the first completed exchange.
public struct TitleSeed: Sendable, Equatable {
    public let userText: String
    public let assistantText: String
    public init(userText: String, assistantText: String) {
        self.userText = userText
        self.assistantText = assistantText
    }
}

/// One in-flight chat context (wraps a `LanguageModelSession`). `@MainActor` because the
/// underlying session is observed on the main actor and drives UI.
@MainActor
public protocol ChatSessionHandle: AnyObject {
    var isResponding: Bool { get }
    /// The committed context window as framework-agnostic entries (post-turn).
    var contextEntries: [ContextEntry] { get }
    /// Streams CUMULATIVE snapshots (each element is the whole response so far).
    func stream(prompt: String) -> AsyncThrowingStream<String, Error>
    /// Non-streaming response (used in background to avoid rate limiting).
    func respond(prompt: String) async throws -> String
    func prewarm()
    /// Encodes the live session for fast/faithful resume (nil if unsupported).
    func encodedTranscript() -> Data?
}

@MainActor
public protocol ChatModelProvider: AnyObject {
    var availability: ModelAvailability { get }
    /// Max context tokens (`contextSize` on 26.4+, else 4096).
    var maxContextTokens: Int { get }
    /// Exact token count for `text` (26.4+); nil when unavailable -> caller estimates.
    func tokenCount(for text: String) -> Int?
    func makeSession(settings: GenerationSettings, tools: [any Tool], restoring encodedTranscript: Data?) -> any ChatSessionHandle
    /// Create a fresh session seeded with the given (already condensed) entries as its
    /// starting context. Used to recover from a context-window overflow.
    func makeSession(settings: GenerationSettings, tools: [any Tool], seeding entries: [ContextEntry]) -> any ChatSessionHandle
    /// Generate a short title from the first completed exchange via guided generation.
    /// Returns nil to fall back to the deterministic title.
    func generateTitle(forFirstExchange exchange: TitleSeed) async -> String?
}
