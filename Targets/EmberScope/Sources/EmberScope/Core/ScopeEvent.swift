import Foundation

/// One immutable record in the inspector's log. Ordered by `sequence` (assigned by `ScopeRecorder`).
public struct ScopeEvent: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let sequence: UInt64
    public let timestamp: Date
    /// The `InspectedSession` this belongs to; nil for global events (model status, global notes).
    public let sessionID: UUID?
    public let payload: ScopePayload

    public init(id: UUID, sequence: UInt64, timestamp: Date, sessionID: UUID?, payload: ScopePayload) {
        self.id = id
        self.sequence = sequence
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.payload = payload
    }
}

public enum ScopePayload: Sendable, Codable, Equatable {
    case sessionCreated(SessionInfo)
    case prewarm
    case requestStarted(RequestStart)
    case streamProgress(RequestProgress)
    case requestFinished(RequestEnd)
    case toolCallStarted(ToolCallStart)
    case toolCallFinished(ToolCallEnd)
    case error(ScopeErrorRecord)
    case transcriptSnapshot(TranscriptSnapshot)
    case tokenCountsResolved(TokenCounts)
    case modelStatus(ModelStatus)
    case note(String)
}
