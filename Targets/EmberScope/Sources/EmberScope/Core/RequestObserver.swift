import Foundation
import FoundationModels
import Synchronization

/// Pure request-lifecycle bookkeeping for one session: emits `requestStarted`, throttled
/// `streamProgress`, `error` and `requestFinished` events with duration / time-to-first-token / chunk counts.
/// Time is injected as a monotonic `Duration` so tests are deterministic. Internal: `InspectedSession`
/// owns the lifecycle, and a host driving it directly would desynchronise the two.
final class RequestObserver: Sendable {
    struct Handle: Sendable, Hashable {
        let requestID: UUID
        let startedAt: Duration
        let transcriptCountAtStart: Int
    }

    private struct State: Sendable {
        var chunkCount = 0
        var firstChunkAt: Duration?
        var lastProgressAt: Duration?
        var contentChars = 0
    }

    private let recorder: ScopeRecorder
    private let sessionID: UUID
    /// Tests pin the interval; production leaves it nil and reads the recorder's CURRENT configuration
    /// per chunk, so a later `EmberScope.start(configuration:)` reaches sessions that already exist.
    private let progressIntervalOverride: Duration?
    private var progressInterval: Duration {
        progressIntervalOverride ?? recorder.configuration.streamProgressInterval
    }
    private let now: @Sendable () -> Duration
    private let states = Mutex<[UUID: State]>([:])

    init(recorder: ScopeRecorder, sessionID: UUID, progressInterval: Duration? = nil,
         now: (@Sendable () -> Duration)? = nil) {
        self.recorder = recorder
        self.sessionID = sessionID
        self.progressIntervalOverride = progressInterval
        // `MonotonicClock.now` as an unapplied reference is a non-Sendable function value: converting
        // it warns under strict concurrency (same as `ScopeRecorder.clock`). The literal captures nothing.
        self.now = now ?? { MonotonicClock.now() }
    }

    func start(kind: RequestKind, prompt: String?, options: GenerationOptions, responseFormat: String?,
               includeSchemaInPrompt: Bool?, transcriptCount: Int) -> Handle {
        let id = UUID()
        let t = now()
        // Nothing to track when the recorder is off: no per-request state is allocated at all.
        guard recorder.isActive else { return Handle(requestID: id, startedAt: t, transcriptCountAtStart: transcriptCount) }
        states.withLock { $0[id] = State() }
        recorder.record(.requestStarted(RequestStart(requestID: id, kind: kind, prompt: prompt,
                                                     options: RequestOptions(options), responseFormat: responseFormat,
                                                     includeSchemaInPrompt: includeSchemaInPrompt)),
                        sessionID: sessionID)
        return Handle(requestID: id, startedAt: t, transcriptCountAtStart: transcriptCount)
    }

    /// One streamed snapshot arrived. Emits `.streamProgress` at most once per `progressInterval`
    /// (the first chunk always emits).
    func chunk(_ handle: Handle, contentChars: Int) {
        let t = now()
        let progressInterval = self.progressInterval
        let progress: RequestProgress? = states.withLock { dict in
            guard var s = dict[handle.requestID] else { return nil }
            s.chunkCount += 1
            s.contentChars = contentChars
            if s.firstChunkAt == nil { s.firstChunkAt = t }
            let due = s.lastProgressAt.map { t - $0 >= progressInterval } ?? true
            if due { s.lastProgressAt = t }
            dict[handle.requestID] = s
            return due ? RequestProgress(requestID: handle.requestID, chunkCount: s.chunkCount, contentChars: contentChars) : nil
        }
        if let progress { recorder.record(.streamProgress(progress), sessionID: sessionID) }
    }

    @discardableResult
    func finish(_ handle: Handle, output: String?, resolvedPrompt: String? = nil, transcriptCount: Int) -> RequestEnd {
        end(handle, status: .succeeded, output: output, resolvedPrompt: resolvedPrompt, transcriptCount: transcriptCount)
    }

    @discardableResult
    func fail(_ handle: Handle, error: any Error, transcriptCount: Int) -> RequestEnd {
        let record = ScopeErrorClassifier.classify(error, requestID: handle.requestID)
        recorder.record(.error(record), sessionID: sessionID)
        return end(handle, status: .failed(errorID: record.id), output: nil, resolvedPrompt: nil, transcriptCount: transcriptCount)
    }

    @discardableResult
    func cancel(_ handle: Handle, transcriptCount: Int) -> RequestEnd {
        end(handle, status: .cancelled, output: nil, resolvedPrompt: nil, transcriptCount: transcriptCount)
    }

    private func end(_ handle: Handle, status: RequestStatus, output: String?, resolvedPrompt: String?,
                     transcriptCount: Int) -> RequestEnd {
        let t = now()
        let s = states.withLock { $0.removeValue(forKey: handle.requestID) } ?? State()
        let end = RequestEnd(requestID: handle.requestID, status: status, duration: t - handle.startedAt,
                             timeToFirstToken: s.firstChunkAt.map { $0 - handle.startedAt },
                             chunkCount: s.chunkCount, output: output,
                             outputChars: output?.count ?? s.contentChars,
                             appendedEntryCount: max(0, transcriptCount - handle.transcriptCountAtStart),
                             resolvedPrompt: resolvedPrompt)
        recorder.record(.requestFinished(end), sessionID: sessionID)
        return end
    }
}
