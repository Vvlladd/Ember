import Foundation
import Testing
@testable import EmberScope

struct ScopeEventCodableTests {
    private func roundTrip(_ payload: ScopePayload) throws -> ScopeEvent {
        let event = Fixtures.event(payload, sequence: 7)
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(ScopeEvent.self, from: data)
        #expect(decoded == event)
        return decoded
    }

    @Test func sessionCreatedRoundTrips() throws {
        let e = try roundTrip(.sessionCreated(Fixtures.sessionInfo))
        #expect(e.sequence == 7)
        #expect(e.sessionID == Fixtures.sessionID)
    }

    @Test func requestLifecycleRoundTrips() throws {
        _ = try roundTrip(.requestStarted(Fixtures.requestStart))
        _ = try roundTrip(.streamProgress(RequestProgress(requestID: Fixtures.requestID, chunkCount: 3, contentChars: 40)))
        _ = try roundTrip(.requestFinished(Fixtures.requestEnd))
        let failed = RequestEnd(requestID: Fixtures.requestID, status: .failed(errorID: Fixtures.errorRecord.id),
                                duration: .seconds(2), timeToFirstToken: nil, chunkCount: 0, output: nil,
                                outputChars: 0, appendedEntryCount: 0, resolvedPrompt: "resolved")
        _ = try roundTrip(.requestFinished(failed))
    }

    @Test func toolErrorStatusAndNoteRoundTrip() throws {
        _ = try roundTrip(.toolCallStarted(ToolCallStart(callID: Fixtures.callID, toolName: "echo", arguments: "{\"text\":\"hi\"}")))
        _ = try roundTrip(.toolCallFinished(ToolCallEnd(callID: Fixtures.callID, toolName: "echo", status: .succeeded,
                                                        duration: .milliseconds(4), output: "echo: hi")))
        _ = try roundTrip(.error(Fixtures.errorRecord))
        _ = try roundTrip(.modelStatus(ModelStatus(availability: "available", isAvailable: true, contextSize: 4096,
                                                   supportsExactTokenCounts: true, supportedLanguageCount: 23,
                                                   osVersion: "26.6")))
        _ = try roundTrip(.tokenCountsResolved(TokenCounts(snapshotID: UUID(), entryTokens: ["e-1": 12], toolsTokens: 40)))
        _ = try roundTrip(.prewarm)
        _ = try roundTrip(.note("compacted"))
    }

    @Test func errorKindsAreStableStrings() {
        #expect(ScopeErrorRecord.Kind.allCases.count == 13)
        #expect(ScopeErrorRecord.Kind.exceededContextWindowSize.rawValue == "exceededContextWindowSize")
    }

    @Test func transcriptSnapshotRoundTrips() throws {
        let snapshot = TranscriptSnapshot.make(from: Fixtures.transcript(), sessionID: Fixtures.sessionID,
                                               contextSize: 4096, tools: [EchoTool()], takenAt: Fixtures.date)
        let decoded = try roundTrip(.transcriptSnapshot(snapshot))
        guard case .transcriptSnapshot(let back) = decoded.payload else { Issue.record("wrong case"); return }
        #expect(back.entries.count == 5)
        #expect(back.usedTokens == snapshot.usedTokens && back.toolsTokens == snapshot.toolsTokens)
    }
}
