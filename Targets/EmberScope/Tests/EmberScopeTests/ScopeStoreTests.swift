import Foundation
import Testing
@testable import EmberScope

struct ScopeStoreFoldTests {
    let s1 = Fixtures.sessionID
    let s2 = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

    private func stream() -> [ScopeEvent] {
        var seq: UInt64 = 0
        func ev(_ p: ScopePayload, _ sid: UUID?, offset: TimeInterval = 0) -> ScopeEvent {
            seq += 1
            return Fixtures.event(p, sequence: seq, sessionID: sid, at: Fixtures.date.addingTimeInterval(offset))
        }
        let snapshot = TranscriptSnapshot.make(from: Fixtures.transcript(), sessionID: s1, contextSize: 4096)
        let counts = TokenCounts(snapshotID: snapshot.id, entryTokens: Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.id, 3) }), toolsTokens: 9)
        let staleCounts = TokenCounts(snapshotID: UUID(), entryTokens: ["e-instr": 999], toolsTokens: nil)
        let toolStart = ToolCallStart(callID: Fixtures.callID, toolName: "echo", arguments: "{}")
        let toolEnd = ToolCallEnd(callID: Fixtures.callID, toolName: "echo", status: .succeeded, duration: .milliseconds(10), output: "ok")
        let call2 = UUID()
        let toolErr = ScopeErrorRecord(kind: .toolCallFailed, requestID: nil, toolCallID: call2, toolName: "echo", message: "boom",
                                       debugDescription: nil, recoverySuggestion: nil, failureReason: nil, underlyingChain: [], isRetryable: false)
        return [
            ev(.modelStatus(ModelStatus(availability: "available", isAvailable: true, contextSize: 4096, supportsExactTokenCounts: true, supportedLanguageCount: 1, osVersion: "26")), nil),
            ev(.sessionCreated(Fixtures.sessionInfo), s1),
            ev(.transcriptSnapshot(snapshot), s1),
            ev(.prewarm, s1),
            ev(.requestStarted(Fixtures.requestStart), s1, offset: 1),
            ev(.streamProgress(RequestProgress(requestID: Fixtures.requestID, chunkCount: 2, contentChars: 8)), s1, offset: 1.1),
            ev(.toolCallStarted(toolStart), s1, offset: 1.2),
            ev(.toolCallFinished(toolEnd), s1, offset: 1.3),
            ev(.toolCallStarted(ToolCallStart(callID: call2, toolName: "echo", arguments: "{}")), s1, offset: 1.4),
            ev(.error(toolErr), s1, offset: 1.5),
            ev(.toolCallFinished(ToolCallEnd(callID: call2, toolName: "echo", status: .failed(errorID: toolErr.id), duration: .milliseconds(30), output: nil)), s1, offset: 1.6),
            ev(.requestFinished(Fixtures.requestEnd), s1, offset: 2),
            ev(.tokenCountsResolved(staleCounts), s1, offset: 2.1),
            ev(.tokenCountsResolved(counts), s1, offset: 2.2),
            ev(.note("retrieved 2 memories"), s1, offset: 2.3),
            ev(.note("global note"), nil, offset: 2.4),
            ev(.sessionCreated(SessionInfo(label: "title", instructions: nil, tools: [], contextSize: 4096, modelDescription: "m", restoredFromTranscript: false)), s2, offset: 3),
            ev(.requestStarted(RequestStart(requestID: UUID(), kind: .respond, prompt: nil, options: RequestOptions(temperature: nil, maximumResponseTokens: 24, samplingDescription: "greedy"), responseFormat: "ConversationTitle", includeSchemaInPrompt: true)), s2, offset: 3.1),
            ev(.error(Fixtures.errorRecord), s2, offset: 3.2),
        ]
    }

    @Test func groupsSessionsNewestFirstWithRecords() {
        let p = ScopeStore.fold(stream())
        #expect(p.sessions.map(\.label) == ["title", "chat"])
        let chat = p.sessions[1]
        #expect(chat.id == s1)
        #expect(chat.prewarmCount == 1)
        #expect(chat.requests.count == 1)
        let req = chat.requests[0]
        #expect(req.id == Fixtures.requestID)
        #expect(req.progress?.chunkCount == 2)
        #expect(req.end == Fixtures.requestEnd)
        #expect(!req.isInFlight)
        #expect(req.promptText == "Hello there")
        #expect(chat.toolCalls.count == 2)
        #expect(chat.toolCalls[0].end?.status == .succeeded)
        #expect(chat.toolCalls[1].error?.kind == .toolCallFailed)
        #expect(chat.errors.count == 1)
        #expect(chat.notes.map(\.text) == ["retrieved 2 memories"])
        #expect(chat.lastActivity >= chat.createdAt)
        let title = p.sessions[0]
        #expect(title.requests.count == 1 && title.requests[0].isInFlight)
        #expect(title.requests[0].start.responseFormat == "ConversationTitle")
    }

    @Test func appliesMatchingTokenCountsOnly() {
        let p = ScopeStore.fold(stream())
        let snap = p.sessions[1].latestSnapshot
        #expect(snap?.isExact == true)
        #expect(snap?.entries.allSatisfy { $0.tokens == 3 } == true)   // stale counts (999) ignored
        #expect(snap?.toolsTokens == 9)
    }

    @Test func registryAggregatesToolStats() {
        let p = ScopeStore.fold(stream())
        #expect(p.tools.map(\.name) == ["echo"])
        let echo = p.tools[0]
        #expect(echo.info?.description == "Echo the text back.")
        #expect(echo.callCount == 2 && echo.failureCount == 1)
        #expect(echo.totalDuration == .milliseconds(40))
        #expect(echo.meanDuration == .milliseconds(20))
    }

    @Test func errorsNewestFirstTimelineAscendingNotesSplit() {
        let p = ScopeStore.fold(stream())
        #expect(p.errors.count == 2)
        #expect(p.errors[0] == Fixtures.errorRecord)
        #expect(p.timeline.map(\.sequence) == Array(1...UInt64(stream().count)))
        #expect(p.notes.map(\.text) == ["global note"])
        #expect(p.modelStatus?.contextSize == 4096)
    }

    @Test func unknownSessionGetsPlaceholderAndOldestAreEvicted() {
        let orphan = UUID()
        var events = stream()
        events.append(Fixtures.event(.prewarm, sequence: 100, sessionID: orphan, at: Fixtures.date.addingTimeInterval(10)))
        let p = ScopeStore.fold(events, maxSessions: 2)
        #expect(p.sessions.count == 2)
        #expect(p.sessions[0].id == orphan && p.sessions[0].label == "session")
        #expect(p.sessions.map(\.id).contains(s1) == false)   // oldest dropped
    }

    /// Ruling (Task 10 review): a finish whose start was evicted must not touch the registry.
    @Test func orphanToolCallFinishDoesNotSkewTheRegistry() {
        let orphan = Fixtures.event(.toolCallFinished(ToolCallEnd(callID: UUID(), toolName: "echo", status: .failed(errorID: UUID()),
                                                                  duration: .seconds(9), output: nil)), sequence: 1, sessionID: s1)
        let p = ScopeStore.fold([orphan])
        #expect(p.tools.isEmpty)
        #expect(p.sessions.first?.toolCalls.isEmpty == true)
    }

    /// `fold` is public and may see concatenated/decoded streams: duplicate start ids never double-list.
    @Test func duplicateStartEventsNeverDoubleList() {
        let start = Fixtures.event(.requestStarted(Fixtures.requestStart), sequence: 1, sessionID: s1)
        let again = Fixtures.event(.requestStarted(Fixtures.requestStart), sequence: 2, sessionID: s1)
        let p = ScopeStore.fold([start, again])
        #expect(p.sessions.first?.requests.count == 1)
        #expect(ScopeStore.fold([], maxSessions: -1).sessions.isEmpty)
    }

    @Test func foldIsOrderIndependent() {
        let events = stream()                       // ONE array — the fixture mints fresh UUIDs on every call
        #expect(ScopeStore.fold(events.shuffled()) == ScopeStore.fold(events))
    }
}

@MainActor
struct ScopeStoreTests {
    @Test func refreshProjectsRecorderAndTracksState() {
        let r = ScopeRecorder(configuration: ScopeConfiguration(isEnabled: true, maxEvents: 2), isRecording: true)
        let store = ScopeStore(recorder: r)
        #expect(store.sessions.isEmpty && store.isRecording)
        r.record(.sessionCreated(Fixtures.sessionInfo), sessionID: Fixtures.sessionID)
        r.record(.prewarm, sessionID: Fixtures.sessionID)
        r.record(.prewarm, sessionID: Fixtures.sessionID)
        store.refresh()
        #expect(store.sessions.count == 1)
        #expect(store.evictedEventCount == 1)
        #expect(store.session(id: Fixtures.sessionID)?.prewarmCount == 2)
        store.setRecording(false)
        #expect(!store.isRecording && !r.isRecording)
        store.clear()
        #expect(store.sessions.isEmpty && store.timeline.isEmpty)
    }

    @Test func flushHandlerRefreshesAsynchronously() async {
        let r = ScopeRecorder(configuration: ScopeConfiguration(isEnabled: true), isRecording: true)
        let store = ScopeStore(recorder: r)
        r.record(.note("hello"))
        for _ in 0..<50 where store.notes.isEmpty { await Task.yield() }
        #expect(store.notes.map(\.text) == ["hello"])
    }
}
