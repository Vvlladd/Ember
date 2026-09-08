import Foundation
import Synchronization
import Testing
@testable import EmberScope

final class CollectingSink: ScopeSink {
    let events = Mutex<[ScopeEvent]>([])
    func receive(_ event: ScopeEvent) { events.withLock { $0.append(event) } }
    var count: Int { events.withLock { $0.count } }
}

struct ScopeRecorderTests {
    private func recorder(_ config: ScopeConfiguration = ScopeConfiguration(isEnabled: true)) -> ScopeRecorder {
        ScopeRecorder(configuration: config, isRecording: true, clock: { Fixtures.date })
    }

    @Test func assignsIncreasingSequenceAndTimestamp() {
        let r = recorder()
        let a = r.record(.prewarm, sessionID: Fixtures.sessionID)
        let b = r.record(.note("x"))
        #expect(a?.sequence == 1)
        #expect(b?.sequence == 2)
        #expect(a?.timestamp == Fixtures.date)
        #expect(a?.sessionID == Fixtures.sessionID && b?.sessionID == nil)
        #expect(r.snapshot().map(\.sequence) == [1, 2])
    }

    @Test func disabledOrPausedIsNoop() {
        let disabled = ScopeRecorder(configuration: ScopeConfiguration(isEnabled: false), isRecording: true)
        #expect(disabled.record(.prewarm) == nil)
        #expect(disabled.snapshot().isEmpty)
        #expect(!disabled.isActive)

        let paused = ScopeRecorder(configuration: ScopeConfiguration(isEnabled: true), isRecording: false)
        #expect(paused.record(.prewarm) == nil)
        paused.setRecording(true)
        #expect(paused.record(.prewarm) != nil)
        #expect(paused.isActive)
    }

    @Test func evictsOldestBeyondCapacity() {
        let r = recorder(ScopeConfiguration(isEnabled: true, maxEvents: 3))
        for i in 0..<5 { r.record(.note("\(i)")) }
        let notes = r.snapshot().compactMap { if case .note(let n) = $0.payload { return n } else { return nil } }
        #expect(notes == ["2", "3", "4"])
        #expect(r.evictedEventCount == 2)
    }

    @Test func redactsAtRecordTimeWhenCaptureContentIsOff() {
        let r = recorder(ScopeConfiguration(isEnabled: true, captureContent: false))
        let e = r.record(.requestStarted(Fixtures.requestStart))
        guard case .requestStarted(let start)? = e?.payload else { Issue.record("wrong payload"); return }
        #expect(ScopeRedaction.isRedacted(start.prompt ?? ""))
        // Ruling (Task 2 review): metadata-only mode must also scrub error diagnostics on the failure path.
        let f = r.record(.error(Fixtures.errorRecord))
        guard case .error(let record)? = f?.payload else { Issue.record("wrong payload"); return }
        #expect(ScopeRedaction.isRedacted(record.message))
        #expect(record.kind == .rateLimited && record.isRetryable)
    }

    @Test func sinksReceiveEveryEvent() {
        let r = recorder()
        let sink = CollectingSink()
        r.addSink(sink)
        r.record(.prewarm); r.record(.note("n"))
        #expect(sink.count == 2)
    }

    @Test func flushHandlerFiresOncePerBatch() {
        let r = recorder()
        let calls = Mutex(0)
        r.setFlushHandler { calls.withLock { $0 += 1 } }
        r.record(.prewarm); r.record(.prewarm); r.record(.prewarm)
        #expect(calls.withLock { $0 } == 1)
        _ = r.snapshot()                       // consumer drained → re-armed
        r.record(.prewarm)
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func clearDropsEventsAndResetsEviction() {
        let r = recorder(ScopeConfiguration(isEnabled: true, maxEvents: 1))
        r.record(.prewarm); r.record(.prewarm)
        r.clear()
        #expect(r.snapshot().isEmpty)
        #expect(r.evictedEventCount == 0)
        #expect(r.record(.prewarm)?.sequence == 3)   // sequence keeps growing (ids stay unique across clears)
    }

    /// Ruling (final review B11): a host calling `clear()` directly must get a refreshed store, so
    /// `clear` flushes exactly like `record` does.
    @Test func clearInvokesTheFlushHandler() {
        let r = recorder()
        let calls = Mutex(0)
        r.record(.prewarm)
        r.setFlushHandler { calls.withLock { $0 += 1 } }   // installing re-arms the flush
        r.clear()
        #expect(calls.withLock { $0 } == 1)
        _ = r.snapshot()
        r.clear()
        #expect(calls.withLock { $0 } == 2)
    }

    /// Ruling (final review B13): configuration and recording state must change together, or a
    /// concurrent `record` can see the new configuration with the old recording flag.
    @Test func startAppliesConfigurationAndRecordingTogether() {
        let r = ScopeRecorder(configuration: ScopeConfiguration(isEnabled: false), isRecording: false)
        #expect(!r.isActive)
        r.start(configuration: ScopeConfiguration(isEnabled: true, maxEvents: 7, captureContent: false))
        #expect(r.isRecording && r.isActive)
        #expect(r.configuration.maxEvents == 7 && !r.configuration.captureContent)
    }

    @Test func updatingConfigurationAppliesImmediately() {
        let r = recorder()
        r.update(configuration: ScopeConfiguration(isEnabled: false))
        #expect(r.record(.prewarm) == nil)
        #expect(r.configuration.isEnabled == false)
    }

    @Test func osLogSinkDoesNotCrashOnAnyPayload() {
        let sink = OSLogSink(logContent: true)
        sink.receive(Fixtures.event(.sessionCreated(Fixtures.sessionInfo)))
        sink.receive(Fixtures.event(.requestStarted(Fixtures.requestStart)))
        sink.receive(Fixtures.event(.requestFinished(Fixtures.requestEnd)))
        sink.receive(Fixtures.event(.error(Fixtures.errorRecord)))
        sink.receive(Fixtures.event(.note("n")))
        // Default sink (logContent: false) so the .private branches run too.
        OSLogSink().receive(Fixtures.event(.error(Fixtures.errorRecord)))
        OSLogSink().receive(Fixtures.event(.note("n")))
        #expect(OSLogSink.subsystem == "dev.iosunpi.emberscope")
    }

    /// Ruling (final review A1/B1): note text used to be interpolated `.public` in the metadata line.
    /// OSLog privacy annotations are not observable from a test process, so the gate is pinned where it
    /// is decided — `receive` logs every string `contentFields` returns (and only those) through
    /// `content(...)`, which is `.private` unless `logContent`.
    @Test func noteTextIsGatedLikeEveryOtherUserDerivedString() {
        #expect(OSLogSink.contentFields(of: .note("the user's secret")) ==
                [OSLogSink.ContentField(category: .session, label: "note", text: "the user's secret")])
        #expect(OSLogSink.contentFields(of: .sessionCreated(Fixtures.sessionInfo)).map(\.text) == ["You are terse."])
        #expect(OSLogSink.contentFields(of: .requestStarted(Fixtures.requestStart)).map(\.text) == ["Hello there"])
        #expect(OSLogSink.contentFields(of: .requestFinished(Fixtures.requestEnd)).map(\.text) == ["Hi!"])
        let call = ToolCallStart(callID: Fixtures.callID, toolName: "echo", arguments: "{\"text\":\"hi\"}")
        #expect(OSLogSink.contentFields(of: .toolCallStarted(call)).map(\.label) == ["arguments"])
        #expect(OSLogSink.contentFields(of: .toolCallFinished(ToolCallEnd(callID: Fixtures.callID, toolName: "echo",
                                                                          status: .succeeded, duration: .zero,
                                                                          output: "echo: hi"))).map(\.text) == ["echo: hi"])
        // Metadata-only payloads contribute nothing to the gated path.
        #expect(OSLogSink.contentFields(of: .prewarm).isEmpty)
        #expect(OSLogSink.contentFields(of: .modelStatus(ModelStatus(availability: "a", isAvailable: true, contextSize: 1,
                                                                     supportsExactTokenCounts: false,
                                                                     supportedLanguageCount: 1, osVersion: "26"))).isEmpty)
    }

    /// Ruling (final review B10): the OSLog length metadata must measure the ORIGINAL string, so a
    /// metadata-only run still reports real sizes instead of the placeholder's length.
    @Test func redactionKeepsPreRedactionLengths() {
        let r = recorder(ScopeConfiguration(isEnabled: true, captureContent: false))
        guard case .requestStarted(let start)? = r.record(.requestStarted(Fixtures.requestStart))?.payload
        else { Issue.record("wrong payload"); return }
        #expect(start.promptChars == 11 && ScopeRedaction.isRedacted(start.prompt ?? ""))
        let call = ToolCallStart(callID: Fixtures.callID, toolName: "echo", arguments: "{\"text\":\"hi\"}")
        guard case .toolCallStarted(let s)? = r.record(.toolCallStarted(call))?.payload
        else { Issue.record("wrong payload"); return }
        #expect(s.argumentChars == call.arguments.count && ScopeRedaction.isRedacted(s.arguments))
        let end = ToolCallEnd(callID: Fixtures.callID, toolName: "echo", status: .succeeded,
                              duration: .milliseconds(1), output: "echo: hi")
        guard case .toolCallFinished(let e)? = r.record(.toolCallFinished(end))?.payload
        else { Issue.record("wrong payload"); return }
        #expect(e.outputChars == 8 && ScopeRedaction.isRedacted(e.output ?? ""))
    }
}
