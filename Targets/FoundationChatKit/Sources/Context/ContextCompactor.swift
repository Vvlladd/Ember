import Foundation

/// Phase 3 context compaction: keep the most recent `keepingRecent` entries verbatim and replace
/// the older ones with a single model-generated recap. The recap is built from a structured
/// `ConversationSummary` (summary + key topics + user preferences) rendered deterministically;
/// any harvested user preferences are surfaced via `onPreference` so they can be persisted as
/// durable notes before the older turns are dropped. Falls back to `OverflowRecovery.condense`
/// (deterministic first+last) when the structured summary is unavailable, so it never blocks a turn.
public enum ContextCompactor {
    @MainActor
    public static func compact(_ entries: [ContextEntry], keepingRecent: Int = 4,
                               using provider: any ChatModelProvider,
                               onPreference: (@MainActor (String) -> Void)? = nil) async -> [ContextEntry] {
        guard entries.count > keepingRecent else { return entries }
        let older = entries.prefix(entries.count - keepingRecent)
        let recent = Array(entries.suffix(keepingRecent))
        let text = older.compactMap { entry -> String? in
            let who: String
            switch entry.kind {
            case .userPrompt: who = "User"
            case .modelResponse: who = "Assistant"
            case .instructions: who = "System"
            case .toolCall: who = "Tool call"
            case .toolOutput: who = "Tool output"
            case .retrievedMemory: return nil   // re-retrieved fresh each turn; never carry stale memory into the recap
            }
            return "\(who): \(entry.text)"
        }.joined(separator: "\n")

        guard let structured = await provider.summarizeStructured(text), !structured.isEmpty else {
            return OverflowRecovery.condense(entries)
        }
        for pref in structured.cleanPreferences { onPreference?(pref) }
        let recap = ContextEntry(kind: .instructions,
                                 text: "Summary of earlier conversation: \(structured.render())")
        return [recap] + recent
    }
}
