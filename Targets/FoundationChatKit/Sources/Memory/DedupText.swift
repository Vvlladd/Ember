import Foundation

/// Shared text-level near-duplicate rule used by BOTH note de-dup (`saveNoteIfNovel`) and
/// injection-time collapse (`MemoryContextBlock.wrap`), so "what counts as the same memory"
/// has exactly one definition: normalized equality, or substring containment where the
/// contained (shorter) side is at least 3 words — a one-word text ("paris") can't swallow
/// every richer fact mentioning it, only genuine fragments match.
enum DedupText {
    /// Lowercase, collapse whitespace runs to single spaces, trim.
    static func normalized(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// True when `a` and `b` are the same memory under the normalized-equality / ≥3-word
    /// containment rule. Symmetric.
    static func isNearDuplicate(_ a: String, _ b: String) -> Bool {
        let na = normalized(a), nb = normalized(b)
        if na == nb { return true }
        let shorter = na.count <= nb.count ? na : nb
        let longer = na.count <= nb.count ? nb : na
        return wordCount(shorter) >= 3 && longer.contains(shorter)
    }
}
