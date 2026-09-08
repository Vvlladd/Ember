import Foundation

/// A classified error captured by a wrapper. Pure value type (no FoundationModels import) so it is
/// Codable/exportable; `ScopeErrorClassifier` (Task 5) produces it.
public struct ScopeErrorRecord: Sendable, Codable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case exceededContextWindowSize, assetsUnavailable, guardrailViolation, unsupportedGuide,
             unsupportedLanguageOrLocale, decodingFailure, rateLimited, concurrentRequests, refusal,
             toolCallFailed, transientGeneration, cancelled, unknown
    }
    public var id: UUID
    public var kind: Kind
    public var requestID: UUID?
    public var toolCallID: UUID?
    public var toolName: String?
    /// `errorDescription` when available, else `String(describing:)`.
    public var message: String
    /// `GenerationError.Context.debugDescription`.
    public var debugDescription: String?
    public var recoverySuggestion: String?
    public var failureReason: String?
    /// The error chain as "domain(code)", the error's own root first, then each underlying NSError
    /// depth-first. Structured metadata: it survives `captureContent: false`, so a metadata-only
    /// capture still identifies the failure even though `message` is redacted.
    public var underlyingChain: [String]
    public var isRetryable: Bool

    public init(id: UUID = UUID(), kind: Kind, requestID: UUID?, toolCallID: UUID?, toolName: String?,
                message: String, debugDescription: String?, recoverySuggestion: String?, failureReason: String?,
                underlyingChain: [String], isRetryable: Bool) {
        self.id = id; self.kind = kind; self.requestID = requestID; self.toolCallID = toolCallID
        self.toolName = toolName; self.message = message; self.debugDescription = debugDescription
        self.recoverySuggestion = recoverySuggestion; self.failureReason = failureReason
        self.underlyingChain = underlyingChain; self.isRetryable = isRetryable
    }
}
