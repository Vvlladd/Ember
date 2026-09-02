import Foundation
import Testing
@testable import EmberScope

struct ScopeExportTests {
    private func projection() -> ScopeProjection {
        // `takenAt` is pinned: its default is `Date()`, and ISO-8601 encoding keeps whole seconds only,
        // so a live timestamp would not survive the round trip.
        let snapshot = TranscriptSnapshot.make(from: Fixtures.transcript(), sessionID: Fixtures.sessionID,
                                               contextSize: 4096, takenAt: Fixtures.date)
        let request = RequestRecord(sessionID: Fixtures.sessionID, startedAt: Fixtures.date, start: Fixtures.requestStart,
                                    end: Fixtures.requestEnd)
        let call = ToolCallRecord(sessionID: Fixtures.sessionID, startedAt: Fixtures.date,
                                  start: ToolCallStart(callID: Fixtures.callID, toolName: "echo", arguments: "{\"text\":\"hi\"}"),
                                  end: ToolCallEnd(callID: Fixtures.callID, toolName: "echo", status: .succeeded, duration: .milliseconds(4), output: "echo: hi"))
        let session = SessionRecord(id: Fixtures.sessionID, createdAt: Fixtures.date, lastActivity: Fixtures.date,
                                    info: Fixtures.sessionInfo, latestSnapshot: snapshot, requests: [request],
                                    toolCalls: [call], errors: [Fixtures.errorRecord],
                                    notes: [NoteRecord(id: UUID(), sessionID: Fixtures.sessionID, timestamp: Fixtures.date, text: "retrieved 2 memories")])
        return ScopeProjection(sessions: [session], timeline: [], errors: [Fixtures.errorRecord],
                               tools: [ToolRegistryEntry(name: "echo", info: Fixtures.sessionInfo.tools[0], callCount: 1, failureCount: 0, totalDuration: .milliseconds(4))],
                               modelStatus: ModelStatus(availability: "available", isAvailable: true, contextSize: 4096,
                                                        supportsExactTokenCounts: true, supportedLanguageCount: 23, osVersion: "26.6"),
                               notes: [NoteRecord(id: UUID(), sessionID: nil, timestamp: Fixtures.date, text: "global")])
    }

    @Test func jsonRoundTrips() throws {
        let archive = ScopeArchive(projection: projection(), exportedAt: Fixtures.date)
        let data = try ScopeExport.json(archive)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"version\" : \"\(EmberScopeVersion.current)\""))
        #expect(text.contains("2023-11-14T22:13:20Z"))            // ISO-8601 dates
        let decoded = try ScopeExport.decode(data)
        #expect(decoded == archive)
    }

    @Test func markdownContainsTheImportantSections() {
        let md = ScopeExport.markdown(ScopeArchive(projection: projection(), exportedAt: Fixtures.date))
        #expect(md.hasPrefix("# EmberScope export"))
        #expect(md.contains("## Model"))
        #expect(md.contains("contextSize: 4096"))
        #expect(md.contains("### chat"))
        #expect(md.contains("You are terse."))                     // instructions
        #expect(md.contains("| instructions |"))                   // context table row
        #expect(md.contains("Hello there"))                        // prompt
        #expect(md.contains("Hi!"))                                // output
        #expect(md.contains("echo({\"text\":\"hi\"})"))           // tool call
        #expect(md.contains("Rate limited"))                       // error title
        #expect(md.contains("retrieved 2 memories"))               // session note
        #expect(md.contains("global"))                             // global note
        #expect(md.contains("## Errors (1)"))
    }

    @Test func formattingHelpers() {
        #expect(ScopeFormatting.duration(.milliseconds(300)) == "300 ms")
        #expect(ScopeFormatting.duration(.milliseconds(1_250)) == "1.25 s")
        #expect(ScopeFormatting.duration(.microseconds(800)) == "0.8 ms")
        #expect(ScopeFormatting.tokens(4096) == "4,096")
        #expect(ScopeFormatting.short(Fixtures.sessionID) == "11111111")
        #expect(ScopeFormatting.preview("a\nb   c", max: 80) == "a b c")
        #expect(ScopeFormatting.preview(String(repeating: "x", count: 100), max: 10) == "xxxxxxxxx…")
        #expect(ScopeFormatting.timestamp(Fixtures.date) == "2023-11-14T22:13:20Z")
    }
}
