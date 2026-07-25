import Foundation
@testable import FoundationChatKit

/// Deterministic bag-of-words embedder for tests: a vector over a fixed vocabulary so texts that
/// share words score higher in cosine. No NaturalLanguage dependency.
struct MockEmbedder: TextEmbedder {
    let vocabulary: [String]
    let identity = EmbedderIdentity(id: "mock-bag-of-words", dimension: 8)
    init(vocabulary: [String] = ["swift", "trip", "paris", "budget", "weather", "dog", "music", "code"]) {
        self.vocabulary = vocabulary
    }
    func embed(_ text: String, role: EmbeddingRole) -> [Float]? {
        let words = Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        let v = vocabulary.map { words.contains($0) ? Float(1) : Float(0) }
        return v.allSatisfy { $0 == 0 } ? nil : v
    }
    /// Test sugar so pre-existing `embed("…")` call sites keep compiling; production code has no
    /// role-less overload on purpose (every real call site must state its role).
    func embed(_ text: String) -> [Float]? { embed(text, role: .document) }
}
