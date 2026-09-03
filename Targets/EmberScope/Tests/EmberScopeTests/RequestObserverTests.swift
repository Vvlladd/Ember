import Foundation
import FoundationModels
import Synchronization
import Testing
@testable import EmberScope

final class FakeClock: Sendable {
    private let value = Mutex<Duration>(.zero)
    func advance(_ d: Duration) { value.withLock { $0 += d } }
    // `Mutex` is ~Copyable: it cannot be captured by value (that would consume a borrowed stored
    // property). Capture the clock itself instead — `FakeClock` is Sendable, so the closure is too.
    var now: @Sendable () -> Duration { { [self] in value.withLock { $0 } } }
}

struct RequestObserverTests {
    private func make(interval: Duration = .milliseconds(250)) -> (RequestObserver, ScopeRecorder, FakeClock) {
        let recorder = ScopeRecorder(configuration: ScopeConfiguration(isEnabled: true), isRecording: true)
        let clock = FakeClock()
        let observer = RequestObserver(recorder: recorder, sessionID: Fixtures.sessionID,
                                       progressInterval: interval, now: clock.now)
        return (observer, recorder, clock)
    }

    private func payloads(_ r: ScopeRecorder) -> [ScopePayload] { r.snapshot().map(\.payload) }

    @Test func startRecordsRequestStarted() {
        let (o, r, _) = make()
        let h = o.start(kind: .respond, prompt: "hi", options: GenerationOptions(temperature: 0.5, maximumResponseTokens: 10),
                        responseFormat: "Echo", includeSchemaInPrompt: true, transcriptCount: 1)
        guard case .requestStarted(let s)? = payloads(r).first else { Issue.record("no start"); return }
        #expect(s.requestID == h.requestID)
        #expect(s.kind == .respond && s.prompt == "hi" && s.responseFormat == "Echo" && s.includeSchemaInPrompt == true)
        #expect(s.options == RequestOptions(temperature: 0.5, maximumResponseTokens: 10, samplingDescription: "default"))
        #expect(r.snapshot().first?.sessionID == Fixtures.sessionID)
    }

    @Test func finishComputesTimingChunksAndAppendedEntries() {
        let (o, r, clock) = make()
        let h = o.start(kind: .stream, prompt: "p", options: GenerationOptions(), responseFormat: nil,
                        includeSchemaInPrompt: nil, transcriptCount: 1)
        clock.advance(.milliseconds(100)); o.chunk(h, contentChars: 20)
        clock.advance(.milliseconds(100)); o.chunk(h, contentChars: 45)     // 100 ms after last progress → throttled
        clock.advance(.milliseconds(300))
        let end = o.finish(h, output: "hello", transcriptCount: 3)
        #expect(end.status == .succeeded)
        #expect(end.duration == .milliseconds(500))
        #expect(end.timeToFirstToken == .milliseconds(100))
        #expect(end.chunkCount == 2)
        #expect(end.output == "hello" && end.outputChars == 5)
        #expect(end.appendedEntryCount == 2)
        let kinds = payloads(r).map { p -> String in
            switch p {
            case .requestStarted: return "start"
            case .streamProgress: return "progress"
            case .requestFinished: return "end"
            default: return "other"
            }
        }
        #expect(kinds == ["start", "progress", "end"])
    }

    @Test func progressIsThrottledByInterval() {
        let (o, r, clock) = make(interval: .milliseconds(250))
        let h = o.start(kind: .stream, prompt: "p", options: GenerationOptions(), responseFormat: nil,
                        includeSchemaInPrompt: nil, transcriptCount: 0)
        o.chunk(h, contentChars: 1)                                  // t=0 → emitted
        clock.advance(.milliseconds(100)); o.chunk(h, contentChars: 2) // suppressed
        clock.advance(.milliseconds(200)); o.chunk(h, contentChars: 3) // t=300 → emitted
        let progress = payloads(r).compactMap { if case .streamProgress(let p) = $0 { return p } else { return nil } }
        #expect(progress.map(\.chunkCount) == [1, 3])
        #expect(progress.map(\.contentChars) == [1, 3])
    }

    @Test func failRecordsErrorThenFinishedLinkedByErrorID() {
        let (o, r, clock) = make()
        let h = o.start(kind: .respond, prompt: "p", options: GenerationOptions(), responseFormat: nil,
                        includeSchemaInPrompt: nil, transcriptCount: 2)
        clock.advance(.seconds(1))
        let end = o.fail(h, error: LanguageModelSession.GenerationError.rateLimited(.init(debugDescription: "busy")),
                         transcriptCount: 2)
        let all = payloads(r)
        guard case .error(let record) = all[1], case .requestFinished(let recorded) = all[2] else {
            Issue.record("expected start, error, end"); return
        }
        #expect(record.kind == .rateLimited && record.requestID == h.requestID)
        #expect(recorded == end)
        #expect(end.status == .failed(errorID: record.id))
        #expect(end.duration == .seconds(1) && end.appendedEntryCount == 0 && end.output == nil)
    }

    @Test func cancelRecordsCancelledWithoutErrorEvent() {
        let (o, r, _) = make()
        let h = o.start(kind: .stream, prompt: nil, options: GenerationOptions(), responseFormat: nil,
                        includeSchemaInPrompt: nil, transcriptCount: 0)
        o.chunk(h, contentChars: 4)
        let end = o.cancel(h, transcriptCount: 1)
        #expect(end.status == .cancelled && end.chunkCount == 1 && end.outputChars == 4)
        #expect(!payloads(r).contains { if case .error = $0 { return true } else { return false } })
    }

    @Test func resolvedPromptIsCarriedOnFinish() {
        let (o, _, _) = make()
        let h = o.start(kind: .respond, prompt: nil, options: GenerationOptions(), responseFormat: nil,
                        includeSchemaInPrompt: nil, transcriptCount: 0)
        let end = o.finish(h, output: "o", resolvedPrompt: "the prompt", transcriptCount: 2)
        #expect(end.resolvedPrompt == "the prompt")
    }

    /// Ruling (final review B12): the interval was frozen at session construction, so a later
    /// `EmberScope.start(configuration:)` never reached sessions that already existed.
    @Test func progressIntervalFollowsTheRecordersCurrentConfiguration() {
        let recorder = ScopeRecorder(configuration: ScopeConfiguration(isEnabled: true, streamProgressInterval: .milliseconds(250)),
                                     isRecording: true)
        let clock = FakeClock()
        let o = RequestObserver(recorder: recorder, sessionID: Fixtures.sessionID, now: clock.now)   // no override
        let h = o.start(kind: .stream, prompt: "p", options: GenerationOptions(), responseFormat: nil,
                        includeSchemaInPrompt: nil, transcriptCount: 0)
        o.chunk(h, contentChars: 1)                                     // t=0 → emitted
        clock.advance(.milliseconds(100)); o.chunk(h, contentChars: 2)  // suppressed at 250 ms
        recorder.update(configuration: ScopeConfiguration(isEnabled: true, streamProgressInterval: .milliseconds(50)))
        clock.advance(.milliseconds(60)); o.chunk(h, contentChars: 3)   // 160 ms since the last → now due
        let progress = payloads(recorder).compactMap { if case .streamProgress(let p) = $0 { return p } else { return nil } }
        #expect(progress.map(\.chunkCount) == [1, 3])
    }

    /// Ruling (final review B15): an inactive recorder must not even allocate per-request state.
    @Test func inactiveRecorderProducesNoEventsButStillReturnsEnds() {
        let recorder = ScopeRecorder(configuration: ScopeConfiguration(isEnabled: false), isRecording: true)
        let o = RequestObserver(recorder: recorder, sessionID: Fixtures.sessionID)
        let h = o.start(kind: .respond, prompt: "p", options: GenerationOptions(), responseFormat: nil,
                        includeSchemaInPrompt: nil, transcriptCount: 0)
        let end = o.finish(h, output: "x", transcriptCount: 1)
        #expect(end.status == .succeeded)
        #expect(recorder.snapshot().isEmpty)
    }
}
