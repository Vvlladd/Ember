import Foundation

public enum ChatError: Error, Sendable, Equatable {
    case contextOverflow
    case guardrailViolation
    case rateLimited
    /// A transient failure inside the on-device generation runtime (e.g. an internal
    /// `com.apple.tokengeneration` error), NOT context overflow. Retryable.
    case generationInterrupted
    case refusal(String?)
    case modelUnavailable
    case decodingFailure
    case cancelled
    case toolFailed(tool: String, message: String?)
    case unknown(String)
}
