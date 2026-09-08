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

    /// Timeline glyph. Terminal events are status-aware: a failed request must never show a green
    /// check next to "Request failed" (found on the iPad simulator during verification).
    static func icon(for payload: ScopePayload) -> (name: String, color: Color) {
        switch payload {
        case .sessionCreated: ("plus.rectangle.on.rectangle", .purple)
        case .prewarm: ("flame", .secondary)
        case .requestStarted: ("arrow.up.right.circle", .blue)
        case .streamProgress: ("waveform", .blue)
        case .requestFinished(let e):
            switch e.status {
            case .succeeded: ("checkmark.circle", .green)
            case .failed: ("xmark.octagon", .red)
            case .cancelled: ("slash.circle", .secondary)
            }
        case .toolCallStarted: ("wrench.and.screwdriver", .orange)
        case .toolCallFinished(let t):
            switch t.status {
            case .succeeded: ("checkmark.circle", .green)
            case .failed: ("xmark.octagon", .red)
            }
        case .error: ("exclamationmark.triangle.fill", .red)
        case .transcriptSnapshot: ("doc.text.magnifyingglass", .teal)
        case .tokenCountsResolved: ("number", .teal)
        case .modelStatus: ("cpu", .secondary)
        case .note: ("note.text", .secondary)
        }
    }

    /// Rendering lives in `ScopeEventSummary` (Core) so the fold can precompute it off the main actor.
    static func title(for payload: ScopePayload) -> String { ScopeEventSummary.title(for: payload) }
    static func subtitle(for payload: ScopePayload) -> String? { ScopeEventSummary.subtitle(for: payload) }
}
