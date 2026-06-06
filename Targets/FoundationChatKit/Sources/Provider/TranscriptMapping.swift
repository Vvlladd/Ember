import Foundation
import FoundationModels

enum TranscriptMapping {
    /// Flatten a `Transcript` into framework-agnostic entries for the engine/inspector.
    ///
    /// Most entries map 1:1, but an auto-RAG `.prompt` (augmented via `MemoryContextBlock`) splits
    /// into TWO entries — a `.retrievedMemory` block followed by the clean `.userPrompt` — so the
    /// transcript is the single source of truth for both budgeting (Memory + You) and a distinct
    /// inspector section, while resumed bubbles stay clean.
    static func entries(from transcript: Transcript) -> [ContextEntry] {
        transcript.flatMap { entry -> [ContextEntry] in
            switch entry {
            case .instructions(let i):
                return [ContextEntry(kind: .instructions, text: text(of: i.segments))]
            case .prompt(let p):
                let raw = text(of: p.segments)
                let (memory, userText) = MemoryContextBlock.split(raw)
                if let memory {
                    return [ContextEntry(kind: .retrievedMemory, text: memory),
                            ContextEntry(kind: .userPrompt, text: userText)]
                }
                return [ContextEntry(kind: .userPrompt, text: userText)]
            case .response(let r):
                return [ContextEntry(kind: .modelResponse, text: text(of: r.segments))]
            case .toolCalls(let calls):
                let joined = calls.map { call -> String in
                    "\(call.toolName)(\(Self.argumentString(call.arguments)))"
                }.joined(separator: "\n")
                return [ContextEntry(kind: .toolCall, text: joined)]
            case .toolOutput(let o):
                return [ContextEntry(kind: .toolOutput, text: text(of: o.segments))]
            @unknown default:
                return [ContextEntry(kind: .modelResponse, text: "")]
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
