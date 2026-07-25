import Foundation
import NaturalLanguage
import os

/// Which side of retrieval a text is embedded for. EmbeddingGemma is trained with different task
/// prefixes for queries vs stored documents; NLEmbedding ignores the distinction.
public enum EmbeddingRole: Sendable { case query, document }

/// Stable identity of an embedder's vector space. Vectors from different identities are never
/// cosine-compared (see MemoryStore) — a swap changes the id and triggers re-embedding.
public struct EmbedderIdentity: Sendable, Equatable {
    public let id: String
    public let dimension: Int
    public init(id: String, dimension: Int) { self.id = id; self.dimension = dimension }
    /// Vectors persisted before versioning existed (embedderID == nil) are NLEmbedding English.
    public static let legacyNLEnglish = EmbedderIdentity(id: "nl-sentence-en", dimension: 512)
}

/// Produces a dense vector for a piece of text. Mock-able so memory logic is testable off-device.
public protocol TextEmbedder: Sendable {
    var identity: EmbedderIdentity { get }
    func embed(_ text: String, role: EmbeddingRole) -> [Float]?
}

/// Real on-device embedder over `NLEmbedding` sentence vectors (no asset download required).
///
/// `@unchecked Sendable`: the `NLEmbedding` is resolved exactly once in `init` and thereafter only
/// read — `vector(for:)` is a pure read with no mutation — so the cached value is safe to share
/// across threads. We assert this invariant manually rather than relying on automatic checking.
public final class NLTextEmbedder: TextEmbedder, @unchecked Sendable {
    private let language: NLLanguage
    private let embedding: NLEmbedding?

    public init(language: NLLanguage = .english) {
        self.language = language
        self.embedding = NLEmbedding.sentenceEmbedding(for: language)
        if embedding == nil {
            // CRITICAL: no sentence embedding for this language → every embed returns nil and
            // ALL semantic memory (indexing, retrieval, cosine de-dup) silently does nothing.
            EmberLog.embed.error("NLEmbedding.sentenceEmbedding unavailable for \(self.language.rawValue, privacy: .public) — semantic memory is DISABLED")
        } else {
            EmberLog.embed.info("NLEmbedding ready for \(self.language.rawValue, privacy: .public) (dim=\(self.embedding?.dimension ?? -1, privacy: .public))")
        }
    }

    public var identity: EmbedderIdentity {
        language == .english
            ? .legacyNLEnglish
            : EmbedderIdentity(id: "nl-sentence-\(language.rawValue)", dimension: embedding?.dimension ?? 0)
    }

    public func embed(_ text: String, role: EmbeddingRole) -> [Float]? {
        guard let embedding else {
            EmberLog.embed.error("embed() called but no embedding model — returning nil")
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let raw = embedding.vector(for: trimmed) else {
            // OOV / model returned no vector for this string.
            EmberLog.embed.notice("no vector for text (len=\(trimmed.count, privacy: .public)) — returning nil")
            return nil
        }
        return raw.map { Float($0) }
    }
}
