import Foundation
import FoundationModels

enum TranscriptMapping {
    /// Flatten a `Transcript` into framework-agnostic entries for the engine/inspector.
    static func entries(from transcript: Transcript) -> [ContextEntry] {
        transcript.map { entry in
            switch entry {
            case .instructions(let i):
                return ContextEntry(kind: .instructions, text: text(of: i.segments))
            case .prompt(let p):
                return ContextEntry(kind: .userPrompt, text: text(of: p.segments))
            case .response(let r):
                return ContextEntry(kind: .modelResponse, text: text(of: r.segments))
            case .toolCalls(let calls):
                let joined = calls.map { call -> String in
                    "\(call.toolName)(\(Self.argumentString(call.arguments)))"
                }.joined(separator: "\n")
                return ContextEntry(kind: .toolCall, text: joined)
            case .toolOutput(let o):
                return ContextEntry(kind: .toolOutput, text: text(of: o.segments))
            @unknown default:
                return ContextEntry(kind: .modelResponse, text: "")
            }
        }
    }

    /// Render a tool call's arguments as readable JSON.
    private static func argumentString(_ content: GeneratedContent) -> String {
        let raw = content.jsonString
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func text(of segments: [Transcript.Segment]) -> String {
        segments.map { segment in
            switch segment {
            case .text(let t): return t.content
            case .structure(let s): return String(describing: s.content)
            @unknown default: return ""
            }
        }.joined()
    }
}
