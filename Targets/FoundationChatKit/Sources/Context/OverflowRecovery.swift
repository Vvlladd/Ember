import Foundation

/// Phase 1 context compaction: TN3193's deterministic "first + last entry" strategy,
/// used to seed a fresh session after `exceededContextWindowSize`.
/// (Phase 3 upgrades this to LLM-summarized compaction.)
public enum OverflowRecovery {
    public static func condense(_ entries: [ContextEntry]) -> [ContextEntry] {
        guard entries.count > 1 else { return entries }
        let first = entries.first!
        let last = entries.last!
        if first.id == last.id { return [first] }
        return [first, last]
    }
}
