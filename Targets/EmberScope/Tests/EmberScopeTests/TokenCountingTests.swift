import Foundation
import FoundationModels
import Testing
@testable import EmberScope

struct MockTokenCounter: TokenCounting {
    var supportsExactCounts = true
    var perEntry: Int = 7
    var perTools: Int = 11
    var failing = false
    func count(entry: Transcript.Entry) async throws -> Int {
        if failing { throw TokenCountingError.unsupported }
        return perEntry
    }
    func count(tools: [any Tool]) async throws -> Int {
        if failing { throw TokenCountingError.unsupported }
        return perTools
    }
}

struct TokenCountingTests {
    private func recorder() -> ScopeRecorder {
        ScopeRecorder(configuration: ScopeConfiguration(isEnabled: true), isRecording: true)
    }

    @Test func resolverRecordsExactCountsForEveryEntryAndTools() async {
        let r = recorder()
        let transcript = Fixtures.transcript()
        let snapshot = TranscriptSnapshot.make(from: transcript, sessionID: Fixtures.sessionID, contextSize: 4096)
        let resolver = TokenCountResolver(counter: MockTokenCounter(), recorder: r)
        await resolver.resolve(snapshot: snapshot, transcript: transcript, tools: [EchoTool()])
        let events = r.snapshot()
        #expect(events.count == 1)
        guard case .tokenCountsResolved(let counts)? = events.first?.payload else { Issue.record("no counts"); return }
        #expect(counts.snapshotID == snapshot.id)
        #expect(counts.entryTokens.count == 5)
        #expect(counts.entryTokens["e-prompt"] == 7)
        #expect(counts.toolsTokens == 11)
        #expect(events.first?.sessionID == Fixtures.sessionID)
        let exact = snapshot.applying(counts)
        #expect(exact.isExact && exact.usedTokens == 35)
    }

    @Test func noToolsMeansNilToolsTokens() async {
        let r = recorder()
        let transcript = Fixtures.transcript()
        let snapshot = TranscriptSnapshot.make(from: transcript, sessionID: Fixtures.sessionID, contextSize: 4096)
        await TokenCountResolver(counter: MockTokenCounter(), recorder: r).resolve(snapshot: snapshot, transcript: transcript, tools: [])
        guard case .tokenCountsResolved(let counts)? = r.snapshot().first?.payload else { Issue.record("no counts"); return }
        #expect(counts.toolsTokens == nil)
    }

    @Test func failuresAndUnsupportedRecordNothing() async {
        let r = recorder()
        let transcript = Fixtures.transcript()
        let snapshot = TranscriptSnapshot.make(from: transcript, sessionID: Fixtures.sessionID, contextSize: 4096)
        await TokenCountResolver(counter: MockTokenCounter(failing: true), recorder: r).resolve(snapshot: snapshot, transcript: transcript, tools: [])
        await TokenCountResolver(counter: MockTokenCounter(supportsExactCounts: false), recorder: r).resolve(snapshot: snapshot, transcript: transcript, tools: [])
        #expect(r.snapshot().isEmpty)
    }

    @Test func systemCounterAdvertisesSupportByOSVersion() {
        let expected: Bool
        if #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) { expected = true } else { expected = false }
        #expect(SystemTokenCounter().supportsExactCounts == expected)
    }
}
