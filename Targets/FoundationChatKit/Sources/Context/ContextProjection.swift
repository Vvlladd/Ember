import Foundation

public enum ContextProjection {
    /// Filters a context window down to conversational bubbles (user prompts and model
    /// responses), preserving order. Instructions/tool entries are inspector-only.
    public static func bubbles(from entries: [ContextEntry], now: () -> Date = Date.init) -> [ChatMessage] {
        entries.compactMap { entry in
            switch entry.kind {
            case .userPrompt:
                return ChatMessage(role: .user, text: entry.text, createdAt: now())
            case .modelResponse:
                return ChatMessage(role: .assistant, text: entry.text, createdAt: now())
            case .instructions, .toolCall, .toolOutput:
                return nil
            }
        }
    }
}
