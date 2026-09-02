import Foundation
import FoundationModels
import os

/// Seam over `SystemLanguageModel.tokenCount(for:)` so exact accounting is testable without a model.
public protocol TokenCounting: Sendable {
    var supportsExactCounts: Bool { get }
    func count(entry: Transcript.Entry) async throws -> Int
    func count(tools: [any Tool]) async throws -> Int
}

public enum TokenCountingError: Error { case unsupported }

/// Real counter. `tokenCount(for:)` is 26.4+; it also throws when Apple Intelligence is disabled —
/// callers must treat failure as "keep the estimates".
public struct SystemTokenCounter: TokenCounting {
    public let model: SystemLanguageModel
    public init(model: SystemLanguageModel = .default) { self.model = model }

    public var supportsExactCounts: Bool {
        if #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) { return true }
        return false
    }

    public func count(entry: Transcript.Entry) async throws -> Int {
        guard #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) else { throw TokenCountingError.unsupported }
        return try await model.tokenCount(for: [entry])
    }

    public func count(tools: [any Tool]) async throws -> Int {
        guard #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) else { throw TokenCountingError.unsupported }
        return try await model.tokenCount(for: tools)
    }
}

/// Resolves exact per-entry counts for one snapshot and records them as a follow-up event, so the
/// projection can upgrade estimates without mutating shared state. All-or-nothing: a failure keeps estimates.
public struct TokenCountResolver: Sendable {
    public let counter: any TokenCounting
    let recorder: ScopeRecorder

    public init(counter: any TokenCounting, recorder: ScopeRecorder) {
        self.counter = counter
        self.recorder = recorder
    }

    public func resolve(snapshot: TranscriptSnapshot, transcript: Transcript, tools: [any Tool]) async {
        guard counter.supportsExactCounts, recorder.isActive else { return }
        do {
            var entryTokens: [String: Int] = [:]
            for entry in transcript {
                if Task.isCancelled { return }
                entryTokens[entry.id] = try await counter.count(entry: entry)
            }
            let toolsTokens = tools.isEmpty ? nil : try await counter.count(tools: tools)
            recorder.record(.tokenCountsResolved(TokenCounts(snapshotID: snapshot.id, entryTokens: entryTokens,
                                                             toolsTokens: toolsTokens)),
                            sessionID: snapshot.sessionID)
        } catch {
            // Structured metadata only (domain/code): the diagnostics channel never carries free-form text.
            let ns = error as NSError
            ScopeDiagnostics.log.debug("exact token counting unavailable — keeping estimates: \(ns.domain, privacy: .public)(\(ns.code))")
        }
    }
}
