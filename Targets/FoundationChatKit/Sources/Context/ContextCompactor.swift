import Foundation

/// Phase 3 context compaction: keep the most recent `keepingRecent` entries verbatim and replace
/// the older ones with a single model-generated recap. Falls back to `OverflowRecovery.condense`
/// (deterministic first+last) when the summary is unavailable, so it never blocks a turn.
public enum ContextCompactor {
    @MainActor
    public static func compact(_ entries: [ContextEntry], keepingRecent: Int = 4,
                               using provider: any ChatModelProvider) async -> [ContextEntry] {
        guard entries.count > keepingRecent else { return entries }
        let older = entries.prefix(entries.count - keepingRecent)
        let recent = Array(entries.suffix(keepingRecent))
        let text = older.map { entry -> String in
            let who: String
            switch entry.kind {
            case .userPrompt: who = "User"
            case .modelResponse: who = "Assistant"
            case .instructions: who = "System"
            case .toolCall: who = "Tool call"
            case .toolOutput: who = "Tool output"
            }
            return "\(who): \(entry.text)"
        }.joined(separator: "\n")
        guard let summary = await provider.summarize(text), !summary.isEmpty else {
            return OverflowRecovery.condense(entries)
        }
        let recap = ContextEntry(kind: .instructions, text: "Summary of earlier conversation: \(summary)")
        return [recap] + recent
    }
}
