import Foundation
import NaturalLanguage
import os

/// Produces a dense vector for a piece of text. Mock-able so memory logic is testable off-device.
public protocol TextEmbedder: Sendable {
    func embed(_ text: String) -> [Float]?
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

    public func embed(_ text: String) -> [Float]? {
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
