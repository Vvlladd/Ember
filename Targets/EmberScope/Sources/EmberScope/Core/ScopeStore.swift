import Foundation
import Observation

public struct RequestRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID { start.requestID }
    public var sessionID: UUID?
    public var startedAt: Date
    public var start: RequestStart
    public var progress: RequestProgress?
    public var end: RequestEnd?
    public var error: ScopeErrorRecord?
    public var isInFlight: Bool { end == nil }
    /// Known up front for `String` prompts, recovered from the transcript otherwise.
    public var promptText: String? { start.prompt ?? end?.resolvedPrompt }
    public init(sessionID: UUID?, startedAt: Date, start: RequestStart, progress: RequestProgress? = nil,
                end: RequestEnd? = nil, error: ScopeErrorRecord? = nil) {
        self.sessionID = sessionID; self.startedAt = startedAt; self.start = start
        self.progress = progress; self.end = end; self.error = error
    }
}

public struct ToolCallRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID { start.callID }
    public var sessionID: UUID?
    public var startedAt: Date
    public var start: ToolCallStart
    public var end: ToolCallEnd?
    public var error: ScopeErrorRecord?
    public init(sessionID: UUID?, startedAt: Date, start: ToolCallStart, end: ToolCallEnd? = nil, error: ScopeErrorRecord? = nil) {
        self.sessionID = sessionID; self.startedAt = startedAt; self.start = start; self.end = end; self.error = error
    }
}

public struct NoteRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var sessionID: UUID?
    public var timestamp: Date
    public var text: String
    public init(id: UUID, sessionID: UUID?, timestamp: Date, text: String) {
        self.id = id; self.sessionID = sessionID; self.timestamp = timestamp; self.text = text
    }
}

public struct ToolRegistryEntry: Sendable, Codable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var info: ToolInfo?
    public var callCount: Int
    public var failureCount: Int
    public var totalDuration: Duration
    public var meanDuration: Duration? { callCount == 0 ? nil : totalDuration / callCount }
    public init(name: String, info: ToolInfo? = nil, callCount: Int = 0, failureCount: Int = 0, totalDuration: Duration = .zero) {
        self.name = name; self.info = info; self.callCount = callCount; self.failureCount = failureCount; self.totalDuration = totalDuration
    }
}

public struct SessionRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var lastActivity: Date
    public var info: SessionInfo
    public var latestSnapshot: TranscriptSnapshot?
    public var requests: [RequestRecord]
    public var toolCalls: [ToolCallRecord]
    public var errors: [ScopeErrorRecord]
    public var notes: [NoteRecord]
    public var prewarmCount: Int
    public var label: String { info.label }
    public init(id: UUID, createdAt: Date, lastActivity: Date, info: SessionInfo, latestSnapshot: TranscriptSnapshot? = nil,
                requests: [RequestRecord] = [], toolCalls: [ToolCallRecord] = [], errors: [ScopeErrorRecord] = [],
                notes: [NoteRecord] = [], prewarmCount: Int = 0) {
        self.id = id; self.createdAt = createdAt; self.lastActivity = lastActivity; self.info = info
        self.latestSnapshot = latestSnapshot; self.requests = requests; self.toolCalls = toolCalls
        self.errors = errors; self.notes = notes; self.prewarmCount = prewarmCount
    }

    static func placeholder(id: UUID, at date: Date) -> SessionRecord {
        SessionRecord(id: id, createdAt: date, lastActivity: date,
                      info: SessionInfo(label: "session", instructions: nil, tools: [], contextSize: 0,
                                        modelDescription: "", restoredFromTranscript: false))
    }
}

/// Everything the UI renders, derived purely from the event log.
public struct ScopeProjection: Sendable, Codable, Equatable {
    public var sessions: [SessionRecord]      // newest first
    public var timeline: [ScopeEvent]         // ascending by sequence
    public var errors: [ScopeErrorRecord]     // newest first
    public var tools: [ToolRegistryEntry]     // by name
    public var modelStatus: ModelStatus?
    public var notes: [NoteRecord]            // notes without a session
    public static let empty = ScopeProjection(sessions: [], timeline: [], errors: [], tools: [], modelStatus: nil, notes: [])
    public init(sessions: [SessionRecord], timeline: [ScopeEvent], errors: [ScopeErrorRecord], tools: [ToolRegistryEntry],
                modelStatus: ModelStatus?, notes: [NoteRecord]) {
        self.sessions = sessions; self.timeline = timeline; self.errors = errors; self.tools = tools
        self.modelStatus = modelStatus; self.notes = notes
    }
}

/// Main-actor, observable projection of a `ScopeRecorder`. Refreshed by the recorder's coalesced flush
/// handler; `fold` is pure so grouping logic is unit-tested with fixtures.
@MainActor
@Observable
public final class ScopeStore {
    public private(set) var projection: ScopeProjection = .empty
    public private(set) var isRecording: Bool
    public private(set) var evictedEventCount: Int = 0
    /// Drives the `.emberScope()` sheet.
    public var isPresented: Bool = false
    public let recorder: ScopeRecorder

    public var sessions: [SessionRecord] { projection.sessions }
    public var timeline: [ScopeEvent] { projection.timeline }
    public var errors: [ScopeErrorRecord] { projection.errors }
    public var tools: [ToolRegistryEntry] { projection.tools }
    public var modelStatus: ModelStatus? { projection.modelStatus }
    public var notes: [NoteRecord] { projection.notes }

    public init(recorder: ScopeRecorder) {
        self.recorder = recorder
        self.isRecording = recorder.isRecording
        recorder.setFlushHandler { [weak self] in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    public func refresh() {
        let events = recorder.snapshot()
        projection = Self.fold(events, maxSessions: recorder.configuration.maxSessions)
        isRecording = recorder.isRecording
        evictedEventCount = recorder.evictedEventCount
    }

    public func setRecording(_ on: Bool) {
        recorder.setRecording(on)
        isRecording = on
    }

    public func clear() {
        recorder.clear()
        refresh()
    }

    public func session(id: UUID) -> SessionRecord? { projection.sessions.first { $0.id == id } }

    // MARK: Fold

    /// Pure: the same events (in any order) always fold to the same projection, so it runs off the main
    /// actor and is unit-tested without a store.
    public nonisolated static func fold(_ events: [ScopeEvent], maxSessions: Int = 50) -> ScopeProjection {
        let ordered = events.sorted { $0.sequence < $1.sequence }
        var sessions: [UUID: SessionRecord] = [:]
        var sessionOrder: [UUID] = []
        var requests: [UUID: RequestRecord] = [:]
        var requestOrder: [UUID] = []
        var toolCalls: [UUID: ToolCallRecord] = [:]
        var toolCallOrder: [UUID] = []
        var errors: [ScopeErrorRecord] = []
        var registry: [String: ToolRegistryEntry] = [:]
        var modelStatus: ModelStatus?
        var globalNotes: [NoteRecord] = []

        func touch(_ id: UUID, at date: Date) {
            if sessions[id] == nil {
                sessions[id] = .placeholder(id: id, at: date)
                sessionOrder.append(id)
            }
            // Read before the modify access: `sessions[id]?.x = f(sessions[id]?.x)` overlaps exclusivity.
            let lastActivity = sessions[id]?.lastActivity ?? date
            sessions[id]?.lastActivity = max(lastActivity, date)
        }

        for event in ordered {
            if let sid = event.sessionID { touch(sid, at: event.timestamp) }
            switch event.payload {
            case .sessionCreated(let info):
                guard let sid = event.sessionID else { continue }
                sessions[sid]?.info = info
                sessions[sid]?.createdAt = event.timestamp
                for tool in info.tools {
                    registry[tool.name, default: ToolRegistryEntry(name: tool.name)].info = tool
                }
            case .prewarm:
                if let sid = event.sessionID { sessions[sid]?.prewarmCount += 1 }
            case .requestStarted(let start):
                requests[start.requestID] = RequestRecord(sessionID: event.sessionID, startedAt: event.timestamp, start: start)
                requestOrder.append(start.requestID)
            case .streamProgress(let progress):
                requests[progress.requestID]?.progress = progress
            case .requestFinished(let end):
                requests[end.requestID]?.end = end
            case .toolCallStarted(let start):
                toolCalls[start.callID] = ToolCallRecord(sessionID: event.sessionID, startedAt: event.timestamp, start: start)
                toolCallOrder.append(start.callID)
                registry[start.toolName, default: ToolRegistryEntry(name: start.toolName)].callCount += 1
            case .toolCallFinished(let end):
                toolCalls[end.callID]?.end = end
                registry[end.toolName, default: ToolRegistryEntry(name: end.toolName)].totalDuration += end.duration
                if case .failed = end.status {
                    registry[end.toolName, default: ToolRegistryEntry(name: end.toolName)].failureCount += 1
                }
            case .error(let record):
                errors.append(record)
                if let rid = record.requestID { requests[rid]?.error = record }
                if let cid = record.toolCallID { toolCalls[cid]?.error = record }
                if let sid = event.sessionID { sessions[sid]?.errors.append(record) }
            case .transcriptSnapshot(let snapshot):
                touch(snapshot.sessionID, at: event.timestamp)
                sessions[snapshot.sessionID]?.latestSnapshot = snapshot
            case .tokenCountsResolved(let counts):
                guard let sid = event.sessionID, let snapshot = sessions[sid]?.latestSnapshot,
                      snapshot.id == counts.snapshotID else { continue }
                sessions[sid]?.latestSnapshot = snapshot.applying(counts)
            case .modelStatus(let status):
                modelStatus = status
            case .note(let text):
                let note = NoteRecord(id: event.id, sessionID: event.sessionID, timestamp: event.timestamp, text: text)
                if let sid = event.sessionID { sessions[sid]?.notes.append(note) } else { globalNotes.append(note) }
            }
        }

        for id in requestOrder {
            if let request = requests[id], let sid = request.sessionID { sessions[sid]?.requests.append(request) }
        }
        for id in toolCallOrder {
            if let call = toolCalls[id], let sid = call.sessionID { sessions[sid]?.toolCalls.append(call) }
        }

        var newestFirst = sessionOrder.reversed().compactMap { sessions[$0] }
        if newestFirst.count > maxSessions { newestFirst = Array(newestFirst.prefix(maxSessions)) }

        return ScopeProjection(sessions: newestFirst,
                               timeline: ordered,
                               errors: errors.reversed(),
                               tools: registry.values.sorted { $0.name < $1.name },
                               modelStatus: modelStatus,
                               notes: globalNotes)
    }
}
