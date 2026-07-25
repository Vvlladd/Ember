import Foundation

/// EmbeddingGemma's task-prefix prompt format and Matryoshka output handling. Pure — unit-tested
/// without the model. The prefix strings come from the EmbeddingGemma model card; if the card
/// disagrees, THIS is the single place to fix (and re-run scripts/convert parity with the same text).
public enum GemmaEmbeddingFormat {
    public static func prompt(_ text: String, role: EmbeddingRole) -> String {
        switch role {
        case .document: "title: none | text: \(text)"
        case .query: "task: search result | query: \(text)"
        }
    }

    /// Matryoshka truncation: keep the first `dim` components, then re-normalize to unit length so
    /// cosine over truncated vectors stays calibrated. Zero vectors pass through untouched.
    public static func truncateAndNormalize(_ vector: [Float], to dim: Int) -> [Float] {
        let t = Array(vector.prefix(dim))
        let norm = (t.reduce(Float(0)) { $0 + $1 * $1 }).squareRoot()
        guard norm > 0 else { return t }
        return t.map { $0 / norm }
    }
}
