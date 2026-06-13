import Foundation

/// Pure, deterministic lexical overlap score in [0, 1]. Used alongside cosine similarity so
/// memory recall doesn't depend on a single weak embedder (NLEmbedding retrieves on surface
/// overlap, not deep semantics). No FoundationModels / NaturalLanguage dependency: tokenizes
/// with Foundation only (lowercase + non-alphanumeric split + stopword removal), so it is
/// fully Sendable, off-device-testable, and safe inside a @Sendable retriever closure.
///
/// Scoring: query-biased recall — `shared / queryTokenCount`, so a short focused query matched
/// fully by a longer text scores ~1 (the longer text isn't penalized for extra words).
public enum LexicalScorer {
    /// Common English function words dropped before scoring so they don't inflate overlap.
    private static let stopwords: Set<String> = [
        "the", "a", "an", "to", "of", "and", "or", "in", "on", "at", "for", "with",
        "is", "are", "was", "were", "be", "been", "i", "you", "it", "this", "that",
        "what", "should", "do", "does", "did", "my", "me", "we", "they", "them",
        "from", "by", "as", "so", "if", "but", "not", "no", "yes"
    ]

    public static func score(query: String, text: String) -> Float {
        let q = tokens(query)
        let t = tokens(text)
        guard !q.isEmpty, !t.isEmpty else { return 0 }
        let shared = q.intersection(t).count
        guard shared > 0 else { return 0 }
        return Float(shared) / Float(q.count)
    }

    /// Lowercase, split on non-alphanumeric, drop stopwords and empties. Deterministic set.
    static func tokens(_ s: String) -> Set<String> {
        let lowered = s.lowercased()
        let raw = lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return Set(raw.map(String.init).filter { !$0.isEmpty && !stopwords.contains($0) })
    }
}
