import Foundation

/// Single source of truth for how retrieved memory is framed inside a prompt.
///
/// Auto-injected context is wrapped between marker lines so it can be deterministically split back
/// out for inspector display and transcript projection — the markers live on their own lines and
/// the same constants are shared by `wrap`/`augment`/`split` so they always agree. Reused by
/// retrieval injection, the transcript split, and the memory search tool's per-hit formatting.
public enum MemoryContextBlock {
    private static let openMarker = "\u{27E6}memory\u{27E7}"      // ⟦memory⟧
    private static let closeMarker = "\u{27E6}/memory\u{27E7}"   // ⟦/memory⟧
    private static let header = "Background from earlier chats (use only if directly relevant to the question; otherwise ignore):"

    /// Renders a single hit. Factored out of `MemorySearchTool` so the tool and auto-injection
    /// agree on formatting. Saved notes (model-curated facts) render differently from
    /// conversation snippets.
    public static func formatHit(_ hit: MemoryHit) -> String {
        switch hit.record.source {
        case .note:
            return "Saved memory: \(hit.record.text)"
        case .conversation:
            let who = hit.record.role == .user ? "You" : "Assistant"
            return "From '\(hit.record.conversationTitle)' — \(who): \(hit.record.text)"
        }
    }

    /// The full marker-delimited block: open marker, header, one `- ` bullet per hit, close marker —
    /// each marker on its own line. Returns an empty string for no hits (`augment` guards first).
    public static func wrap(_ hits: [MemoryHit]) -> String {
        guard !hits.isEmpty else { return "" }
        let bullets = hits.map { "- \(formatHit($0))" }.joined(separator: "\n")
        return "\(openMarker)\n\(header)\n\(bullets)\n\(closeMarker)"
    }

    /// Prepends the wrapped block to `prompt` when there are hits; otherwise returns `prompt` as-is.
    public static func augment(prompt: String, with hits: [MemoryHit]) -> String {
        guard !hits.isEmpty else { return prompt }
        return "\(wrap(hits))\n\(prompt)"
    }

    /// Inverse of `augment`. If `text` starts with the open marker, returns the inner block content
    /// (header + bullets, WITHOUT the marker lines) plus the trailing user prompt; otherwise returns
    /// `(nil, text)`. Round-trips with `augment`: `split(augment(p, hits)).userText == p`.
    public static func split(_ text: String) -> (memory: String?, userText: String) {
        guard text.hasPrefix(openMarker + "\n") else { return (nil, text) }
        let afterOpen = text.dropFirst((openMarker + "\n").count)
        guard let closeRange = afterOpen.range(of: "\n" + closeMarker) else { return (nil, text) }
        let inner = String(afterOpen[afterOpen.startIndex..<closeRange.lowerBound])
        var rest = String(afterOpen[closeRange.upperBound...])
        if rest.hasPrefix("\n") { rest.removeFirst() }
        return (memory: inner, userText: rest)
    }
}
