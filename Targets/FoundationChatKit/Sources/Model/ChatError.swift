import Foundation

public enum ChatError: Error, Sendable, Equatable {
    case contextOverflow
    case guardrailViolation
    case rateLimited
    case refusal(String?)
    case modelUnavailable
    case decodingFailure
    case cancelled
    case unknown(String)
}
