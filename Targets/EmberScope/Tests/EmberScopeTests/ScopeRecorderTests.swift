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
        #expect(OSLogSink.subsystem == "dev.emberscope")
    }
}
