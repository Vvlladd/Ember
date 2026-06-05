import Foundation
@testable import FoundationChatKit

/// Deterministic bag-of-words embedder for tests: a vector over a fixed vocabulary so texts that
/// share words score higher in cosine. No NaturalLanguage dependency.
struct MockEmbedder: TextEmbedder {
    let vocabulary: [String]
    init(vocabulary: [String] = ["swift", "trip", "paris", "budget", "weather", "dog", "music", "code"]) {
        self.vocabulary = vocabulary
    }
    func embed(_ text: String) -> [Float]? {
        let words = Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        let v = vocabulary.map { words.contains($0) ? Float(1) : Float(0) }
        return v.allSatisfy { $0 == 0 } ? nil : v
    }
}
