import Foundation

public enum ScopeRedaction {
    static let prefix = "«redacted"

    public static func placeholder(forCharacterCount count: Int) -> String {
        "«redacted · \(count) chars»"
    }

    public static func isRedacted(_ text: String) -> Bool { text.hasPrefix(prefix) }

    static func redact(_ text: String?) -> String? { text.map { placeholder(forCharacterCount: $0.count) } }
    static func redact(_ text: String) -> String { placeholder(forCharacterCount: text.count) }
}

public extension ScopePayload {
    /// Content-free copy: user-derived text is replaced by a length placeholder; developer metadata
    /// (tool names/descriptions/schemas, options, counts, durations, notes, structured error fields) is kept;
    /// free-form error strings are redacted too because they can quote prompt text.
    func redacted() -> ScopePayload {
        switch self {
        case .sessionCreated(var info):
            info.instructions = ScopeRedaction.redact(info.instructions)
            return .sessionCreated(info)
        case .requestStarted(var start):
            start.prompt = ScopeRedaction.redact(start.prompt)
            return .requestStarted(start)
        case .requestFinished(var end):
            end.output = ScopeRedaction.redact(end.output)
            end.resolvedPrompt = ScopeRedaction.redact(end.resolvedPrompt)
            return .requestFinished(end)
        case .toolCallStarted(var start):
            start.arguments = ScopeRedaction.redact(start.arguments)
            return .toolCallStarted(start)
        case .toolCallFinished(var end):
            end.output = ScopeRedaction.redact(end.output)
            return .toolCallFinished(end)
        case .transcriptSnapshot(let snapshot):
            return .transcriptSnapshot(snapshot.redacted())
        case .error(var record):
            // Free-form strings can quote prompt text; structured diagnostics (kind, retryable, chain, ids) stay.
            record.message = ScopeRedaction.redact(record.message)
            record.debugDescription = ScopeRedaction.redact(record.debugDescription)
            record.recoverySuggestion = ScopeRedaction.redact(record.recoverySuggestion)
            record.failureReason = ScopeRedaction.redact(record.failureReason)
            return .error(record)
        case .prewarm, .streamProgress, .tokenCountsResolved, .modelStatus, .note:
            return self
        }
    }
}
