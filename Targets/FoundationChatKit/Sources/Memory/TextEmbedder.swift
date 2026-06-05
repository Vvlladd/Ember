import Foundation
import NaturalLanguage

/// Produces a dense vector for a piece of text. Mock-able so memory logic is testable off-device.
public protocol TextEmbedder: Sendable {
    func embed(_ text: String) -> [Float]?
}

/// Real on-device embedder over `NLEmbedding` sentence vectors (no asset download required).
public struct NLTextEmbedder: TextEmbedder {
    private let language: NLLanguage
    public init(language: NLLanguage = .english) { self.language = language }

    public func embed(_ text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let embedding = NLEmbedding.sentenceEmbedding(for: language),
              let vector = embedding.vector(for: trimmed) else { return nil }
        return vector.map { Float($0) }
    }
}
