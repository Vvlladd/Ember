import Foundation

/// One-line renderings of a `ScopePayload`, shared by the timeline, the event detail screen and the
/// fold (which precomputes them once per event so search does not rebuild them per keystroke). Pure
/// and UI-framework-free, so it lives beside the model rather than in the SwiftUI layer.
public enum ScopeEventSummary {
    public static func title(for payload: ScopePayload) -> String {
        switch payload {
        case .sessionCreated(let i): "Session created · \(i.label)"
        case .prewarm: "Prewarm"
        case .requestStarted(let r): "\(r.kind == .stream ? "Stream" : "Respond") started"
        case .streamProgress(let p): "Streaming · \(p.chunkCount) chunks"
        case .requestFinished(let e):
            switch e.status {
            case .succeeded: "Request finished · \(ScopeFormatting.duration(e.duration))"
            case .failed: "Request failed · \(ScopeFormatting.duration(e.duration))"
            case .cancelled: "Request cancelled"
            }
        case .toolCallStarted(let t): "Tool call · \(t.toolName)"
        case .toolCallFinished(let t): "Tool finished · \(t.toolName) · \(ScopeFormatting.duration(t.duration))"
        case .error(let e): e.kind.title
        case .transcriptSnapshot(let s): "Context snapshot · \(ScopeFormatting.tokens(s.usedTokens)) / \(ScopeFormatting.tokens(s.contextSize))"
        case .tokenCountsResolved: "Exact token counts resolved"
        case .modelStatus(let m): "Model · \(m.availability)"
        case .note(let n): n
        }
    }

    public static func subtitle(for payload: ScopePayload) -> String? {
        switch payload {
        case .requestStarted(let r): r.prompt.map { ScopeFormatting.preview($0) }
        case .requestFinished(let e): e.output.map { ScopeFormatting.preview($0) }
        case .toolCallStarted(let t): ScopeFormatting.preview(t.arguments)
        case .toolCallFinished(let t): t.output.map { ScopeFormatting.preview($0) }
        case .error(let e): e.message
        default: nil
        }
    }
}
