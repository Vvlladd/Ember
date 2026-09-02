import Foundation
import FoundationModels
import Synchronization

/// Records `.cancelled` if a stream is dropped before it completes or fails (e.g. the consumer broke out of
/// the loop). Marked done by the iterator on any terminal outcome.
final class RequestFinalizer: Sendable {
    private let done = Mutex(false)
    let session: InspectedSession
    let handle: RequestObserver.Handle

    init(session: InspectedSession, handle: RequestObserver.Handle) {
        self.session = session
        self.handle = handle
    }

    /// Returns true the first time; false afterwards.
    func markDone() -> Bool { done.withLock { let was = $0; $0 = true; return !was } }

    deinit {
        if markDone() { session.cancel(handle) }
    }
}

/// The SDK's `ResponseStream` with recording. Yields the SDK's own `Snapshot` values.
public struct InspectedResponseStream<Content: Generable>: AsyncSequence {
    public typealias Element = LanguageModelSession.ResponseStream<Content>.Snapshot

    let base: LanguageModelSession.ResponseStream<Content>
    let session: InspectedSession
    /// nil when the recorder was inactive at creation → pure pass-through.
    let finalizer: RequestFinalizer?

    init(base: LanguageModelSession.ResponseStream<Content>, session: InspectedSession, handle: RequestObserver.Handle?) {
        self.base = base
        self.session = session
        self.finalizer = handle.map { RequestFinalizer(session: session, handle: $0) }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator(), session: session, finalizer: finalizer)
    }

    /// Consume the whole stream (like the SDK's `collect()`).
    nonisolated(nonsending) public func collect() async throws -> LanguageModelSession.Response<Content> {
        guard let finalizer else { return try await base.collect() }
        do {
            let response = try await base.collect()
            if finalizer.markDone() {
                session.finish(finalizer.handle, output: InspectedSession.outputText(response), entries: response.transcriptEntries)
            }
            return response
        } catch {
            if finalizer.markDone() { session.fail(finalizer.handle, error: error) }
            throw error
        }
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: LanguageModelSession.ResponseStream<Content>.AsyncIterator
        let session: InspectedSession
        let finalizer: RequestFinalizer?
        var lastOutput: String?
        var isFinished = false

        // Mirrors the SDK: runs in the caller's isolation so non-Sendable Snapshots never cross a boundary.
        public mutating func next(isolation actor: isolated (any Actor)? = #isolation) async throws -> Element? {
            if isFinished { return nil }
            do {
                guard let snapshot = try await base.next(isolation: actor) else {
                    isFinished = true
                    if let finalizer, finalizer.markDone() {
                        session.finishFromTranscript(finalizer.handle, output: lastOutput)
                    }
                    return nil
                }
                if let finalizer {
                    lastOutput = InspectedSession.outputText(partial: snapshot.content, raw: snapshot.rawContent)
                    session.observer.chunk(finalizer.handle, contentChars: lastOutput?.count ?? 0)
                }
                return snapshot
            } catch {
                isFinished = true
                if let finalizer, finalizer.markDone() { session.fail(finalizer.handle, error: error) }
                throw error
            }
        }
    }
}
