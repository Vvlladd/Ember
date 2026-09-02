import Foundation
import FoundationModels

public extension ScopeErrorRecord.Kind {
    var isRetryable: Bool {
        switch self {
        case .rateLimited, .concurrentRequests, .transientGeneration: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .exceededContextWindowSize: return "Context window exceeded"
        case .assetsUnavailable: return "Model assets unavailable"
        case .guardrailViolation: return "Guardrail violation"
        case .unsupportedGuide: return "Unsupported guide"
        case .unsupportedLanguageOrLocale: return "Unsupported language"
        case .decodingFailure: return "Decoding failure"
        case .rateLimited: return "Rate limited"
        case .concurrentRequests: return "Concurrent requests"
        case .refusal: return "Refusal"
        case .toolCallFailed: return "Tool call failed"
        case .transientGeneration: return "Transient generation failure"
        case .cancelled: return "Cancelled"
        case .unknown: return "Unknown error"
        }
    }
}

/// Turns any error thrown by Foundation Models (or a tool) into a `ScopeErrorRecord`. Pure.
public enum ScopeErrorClassifier {
    public static func classify(_ error: any Error, requestID: UUID? = nil, toolCallID: UUID? = nil,
                                toolName: String? = nil) -> ScopeErrorRecord {
        let chain = underlyingChain(of: error)

        if error is CancellationError {
            return ScopeErrorRecord(kind: .cancelled, requestID: requestID, toolCallID: toolCallID, toolName: toolName,
                                    message: "Cancelled", debugDescription: nil, recoverySuggestion: nil,
                                    failureReason: nil, underlyingChain: chain, isRetryable: false)
        }

        if let toolError = error as? LanguageModelSession.ToolCallError {
            return ScopeErrorRecord(kind: .toolCallFailed, requestID: requestID, toolCallID: toolCallID,
                                    toolName: toolError.tool.name,
                                    message: toolError.errorDescription ?? "Tool '\(toolError.tool.name)' failed",
                                    debugDescription: String(describing: toolError.underlyingError),
                                    recoverySuggestion: nil, failureReason: nil,
                                    underlyingChain: underlyingChain(of: toolError.underlyingError),
                                    isRetryable: false)
        }

        if let generation = error as? LanguageModelSession.GenerationError {
            let (kind, context) = kindAndContext(of: generation)
            return ScopeErrorRecord(kind: kind, requestID: requestID, toolCallID: toolCallID, toolName: toolName,
                                    message: generation.errorDescription ?? String(describing: generation),
                                    debugDescription: context?.debugDescription,
                                    recoverySuggestion: generation.recoverySuggestion,
                                    failureReason: generation.failureReason,
                                    underlyingChain: chain, isRetryable: kind.isRetryable)
        }

        // NSError-shaped failures that do not bridge to a GenerationError case.
        let ns = error as NSError
        let kind: ScopeErrorRecord.Kind
        if isTransientGenerationFailure(error) {
            kind = .transientGeneration
        } else if chain.contains(where: { $0.hasPrefix("ModelManagerServices.ModelManagerError") })
                    || ns.domain.hasPrefix("ModelManagerServices.ModelManagerError") {
            kind = .assetsUnavailable
        } else {
            kind = .unknown
        }
        let localized = (error as? LocalizedError)
        return ScopeErrorRecord(kind: kind, requestID: requestID, toolCallID: toolCallID, toolName: toolName,
                                message: localized?.errorDescription ?? "\(ns.domain) (\(ns.code))",
                                debugDescription: String(describing: error),
                                recoverySuggestion: localized?.recoverySuggestion,
                                failureReason: localized?.failureReason,
                                underlyingChain: chain, isRetryable: kind.isRetryable)
    }

    private static func kindAndContext(of error: LanguageModelSession.GenerationError)
        -> (ScopeErrorRecord.Kind, LanguageModelSession.GenerationError.Context?) {
        switch error {
        case .exceededContextWindowSize(let c): return (.exceededContextWindowSize, c)
        case .assetsUnavailable(let c): return (.assetsUnavailable, c)
        case .guardrailViolation(let c): return (.guardrailViolation, c)
        case .unsupportedGuide(let c): return (.unsupportedGuide, c)
        case .unsupportedLanguageOrLocale(let c): return (.unsupportedLanguageOrLocale, c)
        case .decodingFailure(let c): return (.decodingFailure, c)
        case .rateLimited(let c): return (.rateLimited, c)
        case .concurrentRequests(let c): return (.concurrentRequests, c)
        case .refusal(_, let c): return (.refusal, c)
        @unknown default: return (.unknown, nil)
        }
    }

    /// `com.apple.tokengeneration` anywhere in the error or its underlying chain — the intermittent
    /// on-device runtime hiccup that is worth one retry (same heuristic Ember ships).
    public static func isTransientGenerationFailure(_ error: any Error) -> Bool {
        let ns = error as NSError
        if ns.domain == "com.apple.tokengeneration" { return true }
        return underlyingChain(of: error).contains { $0.hasPrefix("com.apple.tokengeneration(") }
    }

    /// "domain(code)" for every underlying NSError, depth-first, following both the single and the
    /// multiple underlying-error keys. Bounded depth so a cyclic chain cannot hang.
    public static func underlyingChain(of error: any Error) -> [String] {
        var out: [String] = []
        func walk(_ e: any Error, depth: Int) {
            guard depth < 8 else { return }
            let ns = e as NSError
            if let single = ns.userInfo[NSUnderlyingErrorKey] as? any Error {
                out.append(describe(single)); walk(single, depth: depth + 1)
            }
            if let many = ns.userInfo[NSMultipleUnderlyingErrorsKey] as? [any Error] {
                for u in many { out.append(describe(u)); walk(u, depth: depth + 1) }
            }
        }
        walk(error, depth: 0)
        return out
    }

    private static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        return "\(ns.domain)(\(ns.code))"
    }
}
