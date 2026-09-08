import Foundation
import Testing
@testable import EmberScope

struct ScopeExportTests {
    /// A fractional second, to prove the archive keeps sub-second resolution (final review A11).
    private let fractional = Fixtures.date.addingTimeInterval(0.125)

    private func projection() -> ScopeProjection {
        // `takenAt` is pinned so the fixture is deterministic; it deliberately carries a fractional
        // second, which the archive's date strategy must round-trip.
        let snapshot = TranscriptSnapshot.make(from: Fixtures.transcript(), sessionID: Fixtures.sessionID,
                                               contextSize: 4096, takenAt: fractional)
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

    @Test func jsonRoundTripsWithSubSecondDates() throws {
        let archive = ScopeArchive(projection: projection(), exportedAt: fractional)
        let data = try ScopeExport.json(archive)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("2023-11-14T22:13:20.125Z"))        // ISO-8601 with fractional seconds
        let decoded = try ScopeExport.decode(data)
        #expect(decoded == archive)
        #expect(decoded.exportedAt == fractional)
        #expect(decoded.sessions[0].latestSnapshot?.takenAt == fractional)
        // Assert the value, not the pretty-printer's spacing.
        #expect(decoded.version == EmberScopeVersion.current)
    }

    /// Ruling (final review A12): pin the archive's wire format for the two status enums, so a future
    /// refactor cannot silently change what already-shared archives mean.
    @Test func statusEnumsHaveAStableWireFormat() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let id = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        #expect(String(decoding: try encoder.encode(RequestStatus.succeeded), as: UTF8.self) == #"{"succeeded":{}}"#)
        #expect(String(decoding: try encoder.encode(RequestStatus.cancelled), as: UTF8.self) == #"{"cancelled":{}}"#)
        #expect(String(decoding: try encoder.encode(RequestStatus.failed(errorID: id)), as: UTF8.self)
                == #"{"failed":{"errorID":"44444444-4444-4444-4444-444444444444"}}"#)
        #expect(String(decoding: try encoder.encode(ToolCallStatus.succeeded), as: UTF8.self) == #"{"succeeded":{}}"#)
        #expect(String(decoding: try encoder.encode(ToolCallStatus.failed(errorID: id)), as: UTF8.self)
                == #"{"failed":{"errorID":"44444444-4444-4444-4444-444444444444"}}"#)
    }

    /// Spec §11: an export made in metadata-only mode must carry no content. Record the fixture through
    /// a recorder configured with `captureContent: false`, fold it and check BOTH renderings.
    @Test func redactionIsHonouredByBothExports() throws {
        let recorder = ScopeRecorder(configuration: ScopeConfiguration(isEnabled: true, captureContent: false),
                                     isRecording: true)
        let secrets = ["You are terse.", "Hello there", "Hi!", "echo: hi", #"{"text":"hi"}"#]
        let snapshot = TranscriptSnapshot.make(from: Fixtures.transcript(), sessionID: Fixtures.sessionID,
                                               contextSize: 4096, takenAt: fractional)
        recorder.record(.sessionCreated(Fixtures.sessionInfo), sessionID: Fixtures.sessionID)
        recorder.record(.transcriptSnapshot(snapshot), sessionID: Fixtures.sessionID)
        recorder.record(.requestStarted(Fixtures.requestStart), sessionID: Fixtures.sessionID)
        recorder.record(.requestFinished(Fixtures.requestEnd), sessionID: Fixtures.sessionID)
        recorder.record(.toolCallStarted(ToolCallStart(callID: Fixtures.callID, toolName: "echo",
                                                       arguments: #"{"text":"hi"}"#)), sessionID: Fixtures.sessionID)
        recorder.record(.toolCallFinished(ToolCallEnd(callID: Fixtures.callID, toolName: "echo", status: .succeeded,
                                                      duration: .milliseconds(4), output: "echo: hi")),
                        sessionID: Fixtures.sessionID)
        recorder.record(.error(Fixtures.errorRecord), sessionID: Fixtures.sessionID)

        let archive = ScopeArchive(projection: ScopeStore.fold(recorder.snapshot()), exportedAt: fractional)
        let markdown = ScopeExport.markdown(archive)
        let json = String(decoding: try ScopeExport.json(archive), as: UTF8.self)
        for secret in secrets {
            #expect(!markdown.contains(secret), "markdown leaked \(secret)")
            #expect(!json.contains(secret), "json leaked \(secret)")
        }
        #expect(markdown.contains(ScopeRedaction.prefix))
        #expect(json.contains(ScopeRedaction.prefix))
        // Structure survives: kinds, tool names and counts are developer metadata, not content.
        #expect(markdown.contains("### chat"))
        #expect(markdown.contains("`echo`"))
        #expect(markdown.contains("## Errors (1)"))
    }

    /// Ruling (final review A8): the Markdown report is an archive, so both error lists read oldest
    /// first — the Errors TAB stays newest-first.
    @Test func markdownPrintsErrorsOldestFirst() {
        let older = ScopeErrorRecord(kind: .rateLimited, requestID: nil, toolCallID: nil, toolName: nil,
                                     message: "older failure", debugDescription: nil, recoverySuggestion: nil,
                                     failureReason: nil, underlyingChain: [], isRetryable: true)
        let newer = ScopeErrorRecord(kind: .refusal, requestID: nil, toolCallID: nil, toolName: nil,
                                     message: "newer failure", debugDescription: nil, recoverySuggestion: nil,
                                     failureReason: nil, underlyingChain: [], isRetryable: false)
        var p = projection()
        p.errors = [newer, older]                       // as the projection stores them: newest first
        p.sessions[0].errors = [older, newer]           // as the fold appends them: chronological
        let md = ScopeExport.markdown(ScopeArchive(projection: p, exportedAt: fractional))
        #expect(md.range(of: "older failure")!.lowerBound < md.range(of: "newer failure")!.lowerBound)
        let global = md.range(of: "## Errors")!.upperBound
        let tail = md[global...]
        #expect(tail.range(of: "older failure")!.lowerBound < tail.range(of: "newer failure")!.lowerBound)
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
        #expect(ScopeFormatting.singleLine("a\nb\r\nc") == "a b c")
        #expect(ScopeFormatting.preview("a\nb   c", max: 80) == "a b c")
        #expect(ScopeFormatting.preview(String(repeating: "x", count: 100), max: 10) == "xxxxxxxxx…")
        #expect(ScopeFormatting.timestamp(Fixtures.date) == "2023-11-14T22:13:20Z")
    }

    /// Ruling (Task 12 review): multi-line / fenced content must not break the report's structure.
    @Test func multiLineContentIsFencedSoLaterSectionsSurvive() {
        var p = projection()
        p.sessions[0].info.instructions = "Line one\n```swift\nlet x = 1\n```\nLine two"
        let md = ScopeExport.markdown(ScopeArchive(projection: p, exportedAt: Fixtures.date))
        #expect(md.contains("- Instructions:\n    ````\n    Line one\n    ```swift"))   // fence longer than the embedded ```
        #expect(md.contains("    Line two\n    ````\n"))
        #expect(md.contains("## Errors (1)"))
        #expect(md.contains("## Notes"))
    }
}
