import Foundation
import Synchronization

/// The single shared mutable state on the hot path: an ordered, capacity-bounded event log guarded by a
/// `Mutex`. Recording is synchronous and cheap; sinks run outside the lock; the UI is refreshed through a
/// coalesced flush handler (installed by `ScopeStore`).
public final class ScopeRecorder: Sendable {
    private struct State: Sendable {
        var configuration: ScopeConfiguration
        var isRecording: Bool
        var nextSequence: UInt64 = 1
        var events: [ScopeEvent] = []
        var evictedCount = 0
        var sinks: [any ScopeSink] = []
        var flushHandler: (@Sendable () -> Void)?
        var flushScheduled = false
    }

    private let state: Mutex<State>
    private let clock: @Sendable () -> Date

    public init(configuration: ScopeConfiguration = ScopeConfiguration(),
                isRecording: Bool = false,
                // `Date.init` as an unapplied reference is a non-Sendable function value: converting it
                // warns under strict concurrency (and errors for Swift-6 hosts). The closure captures nothing.
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.state = Mutex(State(configuration: configuration, isRecording: isRecording))
        self.clock = clock
    }

    public var configuration: ScopeConfiguration { state.withLock { $0.configuration } }
    public var isRecording: Bool { state.withLock { $0.isRecording } }
    /// True when events are actually being kept (enabled AND recording).
    public var isActive: Bool { state.withLock { $0.configuration.isEnabled && $0.isRecording } }
    public var evictedEventCount: Int { state.withLock { $0.evictedCount } }

    public func update(configuration: ScopeConfiguration) { state.withLock { $0.configuration = configuration } }
    public func setRecording(_ on: Bool) { state.withLock { $0.isRecording = on } }
    public func addSink(_ sink: any ScopeSink) { state.withLock { $0.sinks.append(sink) } }
    /// Called (at most once per batch) after new events arrive; the handler must eventually call `snapshot()`.
    public func setFlushHandler(_ handler: (@Sendable () -> Void)?) {
        state.withLock { $0.flushHandler = handler; $0.flushScheduled = false }
    }

    /// Append one event. Returns nil (and does nothing) when disabled or paused.
    @discardableResult
    public func record(_ payload: ScopePayload, sessionID: UUID? = nil) -> ScopeEvent? {
        let now = clock()
        let (event, sinks, flush) = state.withLock { s -> (ScopeEvent?, [any ScopeSink], (@Sendable () -> Void)?) in
            guard s.configuration.isEnabled, s.isRecording else { return (nil, [], nil) }
            let stored = s.configuration.captureContent ? payload : payload.redacted()
            let event = ScopeEvent(id: UUID(), sequence: s.nextSequence, timestamp: now,
                                   sessionID: sessionID, payload: stored)
            s.nextSequence += 1
            s.events.append(event)
            let overflow = s.events.count - max(1, s.configuration.maxEvents)
            if overflow > 0 {
                s.events.removeFirst(overflow)
                s.evictedCount += overflow
            }
            var flush: (@Sendable () -> Void)? = nil
            if !s.flushScheduled, let handler = s.flushHandler {
                s.flushScheduled = true
                flush = handler
            }
            return (event, s.sinks, flush)
        }
        guard let event else { return nil }
        for sink in sinks { sink.receive(event) }
        flush?()
        return event
    }

    /// Ordered copy of the log. Re-arms the flush handler for the next batch.
    public func snapshot() -> [ScopeEvent] {
        state.withLock { s in
            s.flushScheduled = false
            return s.events
        }
    }

    public func clear() {
        state.withLock { s in
            s.events.removeAll()
            s.evictedCount = 0
        }
    }
}
