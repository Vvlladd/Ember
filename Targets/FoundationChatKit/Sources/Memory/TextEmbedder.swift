import Foundation
import NaturalLanguage

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
    }

    public func embed(_ text: String) -> [Float]? {
        guard let embedding else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return embedding.vector(for: trimmed)?.map { Float($0) }
    }
}
