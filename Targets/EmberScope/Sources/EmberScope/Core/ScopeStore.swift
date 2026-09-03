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
    /// Calls that STARTED (and whose start survived the ring buffer).
    public var callCount: Int
    /// Calls that also finished — the population `totalDuration` describes.
    public var completedCount: Int
    public var failureCount: Int
    public var totalDuration: Duration
    /// Mean over COMPLETED calls: dividing the finished total by the started count under-reports the
    /// mean whenever a call is still in flight.
    public var meanDuration: Duration? { completedCount == 0 ? nil : totalDuration / completedCount }
    public init(name: String, info: ToolInfo? = nil, callCount: Int = 0, completedCount: Int = 0,
                failureCount: Int = 0, totalDuration: Duration = .zero) {
        self.name = name; self.info = info; self.callCount = callCount; self.completedCount = completedCount
        self.failureCount = failureCount; self.totalDuration = totalDuration
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

/// One timeline row: the event plus its rendered one-liners, built ONCE in the fold. The search field
/// filters thousands of these per keystroke, so `searchKey` (lowercased title + subtitle) must not be
/// rebuilt in a view `body`.
public struct TimelineEntry: Sendable, Codable, Equatable, Identifiable {
    public var event: ScopeEvent
    public var title: String
    public var subtitle: String?
    public var searchKey: String
    public var id: UUID { event.id }

    public init(event: ScopeEvent) {
        self.event = event
        let title = ScopeEventSummary.title(for: event.payload)
        let subtitle = ScopeEventSummary.subtitle(for: event.payload)
        self.title = title
        self.subtitle = subtitle
        self.searchKey = (subtitle.map { title + " " + $0 } ?? title).lowercased()
    }
}

/// Everything the UI renders, derived purely from the event log.
public struct ScopeProjection: Sendable, Codable, Equatable {
    public var sessions: [SessionRecord]      // most recently active first
    public var timeline: [TimelineEntry]      // ascending by sequence
    public var errors: [ScopeErrorRecord]     // newest first
    public var tools: [ToolRegistryEntry]     // by name
    public var modelStatus: ModelStatus?
    public var notes: [NoteRecord]            // notes without a session
    public static let empty = ScopeProjection(sessions: [], timeline: [], errors: [], tools: [], modelStatus: nil, notes: [])
    public init(sessions: [SessionRecord], timeline: [TimelineEntry], errors: [ScopeErrorRecord], tools: [ToolRegistryEntry],
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
    /// Mirrors of the recorder's configuration, so a view `body` never takes the recorder's lock.
    public private(set) var isEnabled: Bool
    public private(set) var maxEvents: Int
    /// Drives the `.emberScope()` sheet.
    public var isPresented: Bool = false
    public let recorder: ScopeRecorder

    /// Monotonic guard: a slower older fold must never overwrite a newer projection.
    @ObservationIgnored private var requestedGeneration: UInt64 = 0
    @ObservationIgnored private var appliedGeneration: UInt64 = 0

    public var sessions: [SessionRecord] { projection.sessions }
    public var timeline: [TimelineEntry] { projection.timeline }
    public var errors: [ScopeErrorRecord] { projection.errors }
    public var tools: [ToolRegistryEntry] { projection.tools }
    public var modelStatus: ModelStatus? { projection.modelStatus }
    public var notes: [NoteRecord] { projection.notes }

    public init(recorder: ScopeRecorder) {
        self.recorder = recorder
        let configuration = recorder.configuration
        self.isRecording = recorder.isRecording
        self.isEnabled = configuration.isEnabled
        self.maxEvents = configuration.maxEvents
        recorder.setFlushHandler { [weak self] in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        // The log is empty (or tiny) at construction, and callers expect a usable store synchronously.
        applyNow()
    }

    /// Re-fold the recorder's log. The fold runs OFF the main actor — it is `nonisolated` and pure —
    /// and only the finished projection is assigned here, so a 2,000-event flush does not block the UI.
    /// Awaiting it returns after the projection has been assigned (or skipped as stale).
    public func refresh() async {
        requestedGeneration += 1
        let generation = requestedGeneration
        let recorder = self.recorder
        let maxSessions = recorder.configuration.maxSessions
        let folded = await Task.detached(priority: .utility) {
            ScopeStore.fold(recorder.snapshot(), maxSessions: maxSessions)
        }.value
        guard generation > appliedGeneration else { return }
        appliedGeneration = generation
        apply(folded)
    }

    /// Synchronous fold, for the two paths that must be immediate and are cheap: construction and
    /// `clear()` (which has just emptied the log).
    private func applyNow() {
        requestedGeneration += 1
        appliedGeneration = requestedGeneration
        apply(Self.fold(recorder.snapshot(), maxSessions: recorder.configuration.maxSessions))
    }

    private func apply(_ folded: ScopeProjection) {
        projection = folded
        let configuration = recorder.configuration
        isRecording = recorder.isRecording
        isEnabled = configuration.isEnabled
        maxEvents = configuration.maxEvents
        evictedEventCount = recorder.evictedEventCount
    }

    public func setRecording(_ on: Bool) {
        recorder.setRecording(on)
        isRecording = on
    }

    public func clear() {
        recorder.clear()
        applyNow()
    }

    public func session(id: UUID) -> SessionRecord? { projection.sessions.first { $0.id == id } }

    // MARK: Fold

    /// Pure: the same events (in any order) always fold to the same projection, so it runs off the main
    /// actor and is unit-tested without a store.
    public nonisolated static func fold(_ events: [ScopeEvent], maxSessions: Int = 50) -> ScopeProjection {
        let ordered = orderedForFolding(events)
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
                if requests[start.requestID] == nil { requestOrder.append(start.requestID) }   // duplicate ids never double-list
                requests[start.requestID] = RequestRecord(sessionID: event.sessionID, startedAt: event.timestamp, start: start)
            case .streamProgress(let progress):
                requests[progress.requestID]?.progress = progress
            case .requestFinished(let end):
                guard requests[end.requestID]?.end == nil else { continue }   // a duplicate finish never re-times
                requests[end.requestID]?.end = end
            case .toolCallStarted(let start):
                if toolCalls[start.callID] == nil {
                    toolCallOrder.append(start.callID)
                    registry[start.toolName, default: ToolRegistryEntry(name: start.toolName)].callCount += 1
                }
                toolCalls[start.callID] = ToolCallRecord(sessionID: event.sessionID, startedAt: event.timestamp, start: start)
            case .toolCallFinished(let end):
                // Aggregate only calls whose start survived the ring buffer, so callCount and totalDuration
                // describe the same population (an orphan finish would skew meanDuration / failureCount),
                // and never twice for the same call.
                guard let call = toolCalls[end.callID], call.end == nil else { continue }
                // Both halves are keyed off the START record's name, so a finish reporting a different
                // name cannot split one call across two registry rows.
                let name = call.start.toolName
                toolCalls[end.callID]?.end = end
                registry[name, default: ToolRegistryEntry(name: name)].completedCount += 1
                registry[name, default: ToolRegistryEntry(name: name)].totalDuration += end.duration
                if case .failed = end.status {
                    registry[name, default: ToolRegistryEntry(name: name)].failureCount += 1
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

        // Most recently ACTIVE first, and truncated the same way: ordering by creation would let a
        // burst of one-shot `title` / `extract` sessions evict the long-lived `chat` session that is
        // still streaming. Ties fall back to creation time, then id, so the fold stays deterministic.
        var byActivity = sessionOrder.compactMap { sessions[$0] }.sorted { a, b in
            if a.lastActivity != b.lastActivity { return a.lastActivity > b.lastActivity }
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return a.id.uuidString < b.id.uuidString
        }
        let cap = max(0, maxSessions)   // a negative host value must not trap
        if byActivity.count > cap { byActivity = Array(byActivity.prefix(cap)) }

        return ScopeProjection(sessions: byActivity,
                               timeline: ordered.map(TimelineEntry.init),
                               errors: errors.reversed(),
                               tools: registry.values.sorted { $0.name < $1.name },
                               modelStatus: modelStatus,
                               notes: globalNotes)
    }

    /// `fold` is public and may be handed a decoded, concatenated or shuffled stream, so the contract
    /// is "any order in, sequence order out". The hot path — a live `ScopeRecorder.snapshot()` — is
    /// already strictly ascending, so it skips both the sort and the de-duplication after one linear
    /// scan. Anything else is de-duplicated by event id (`fold(events + events) == fold(events)`) and
    /// sorted with tie-breaks all the way down to the id, so two folds of the same events agree.
    nonisolated static func orderedForFolding(_ events: [ScopeEvent]) -> [ScopeEvent] {
        var isStrictlyAscending = true
        for i in events.indices.dropFirst() where events[i].sequence <= events[i - 1].sequence {
            isStrictlyAscending = false
            break
        }
        guard !isStrictlyAscending else { return events }
        var seen = Set<UUID>()
        return events.filter { seen.insert($0.id).inserted }.sorted { a, b in
            if a.sequence != b.sequence { return a.sequence < b.sequence }
            if a.timestamp != b.timestamp { return a.timestamp < b.timestamp }
            return a.id.uuidString < b.id.uuidString
        }
    }
}
