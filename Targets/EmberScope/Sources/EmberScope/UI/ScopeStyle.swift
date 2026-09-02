import SwiftUI

enum ScopeStyle {
    static func color(_ kind: ScopeEntry.Kind) -> Color {
        switch kind {
        case .instructions: .purple
        case .prompt: .blue
        case .response: .green
        case .toolCalls, .toolOutput: .orange
        }
    }

    static func icon(_ kind: ScopeEntry.Kind) -> String {
        switch kind {
        case .instructions: "text.alignleft"
        case .prompt: "person"
        case .response: "sparkles"
        case .toolCalls: "wrench.and.screwdriver"
        case .toolOutput: "arrow.uturn.left"
        }
    }

    static func label(_ kind: ScopeEntry.Kind) -> String {
        switch kind {
        case .instructions: "INSTRUCTIONS"
        case .prompt: "PROMPT"
        case .response: "RESPONSE"
        case .toolCalls: "TOOL CALL"
        case .toolOutput: "TOOL OUTPUT"
        }
    }

    /// Same 4-tier thresholds Ember's gauge uses.
    static func color(fraction: Double) -> Color {
        switch fraction {
        case ..<0.5: .green
        case ..<0.75: .yellow
        case ..<0.9: .orange
        default: .red
        }
    }

    static let error = Color.red

    static func icon(for payload: ScopePayload) -> (name: String, color: Color) {
        switch payload {
        case .sessionCreated: ("plus.rectangle.on.rectangle", .purple)
        case .prewarm: ("flame", .secondary)
        case .requestStarted: ("arrow.up.right.circle", .blue)
        case .streamProgress: ("waveform", .blue)
        case .requestFinished: ("checkmark.circle", .green)
        case .toolCallStarted, .toolCallFinished: ("wrench.and.screwdriver", .orange)
        case .error: ("exclamationmark.triangle.fill", .red)
        case .transcriptSnapshot: ("doc.text.magnifyingglass", .teal)
        case .tokenCountsResolved: ("number", .teal)
        case .modelStatus: ("cpu", .secondary)
        case .note: ("note.text", .secondary)
        }
    }

    static func title(for payload: ScopePayload) -> String {
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

    static func subtitle(for payload: ScopePayload) -> String? {
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
