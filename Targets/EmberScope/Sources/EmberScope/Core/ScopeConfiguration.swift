import Foundation

/// Runtime knobs for EmberScope. Value type; the live copy lives in `ScopeRecorder`.
public struct ScopeConfiguration: Sendable, Equatable {
    /// Master switch. When false every wrapper is a zero-cost pass-through and nothing is recorded.
    public var isEnabled: Bool
    /// Ring-buffer capacity for events; oldest are evicted first.
    public var maxEvents: Int
    /// Oldest sessions are dropped from the projection beyond this count.
    public var maxSessions: Int
    /// When false, prompts / outputs / tool arguments / transcript text and the free-form error strings are replaced by a
    /// `ScopeRedaction` placeholder at record time (metadata-only inspector).
    public var captureContent: Bool
    /// Install the built-in `OSLogSink` on `EmberScope.start()`.
    public var logToOSLog: Bool
    /// Interpolate content into OSLog with `.public` privacy. Off by default: content stays `.private`.
    public var logContent: Bool
    /// Minimum spacing between `.streamProgress` events for one streamed request.
    public var streamProgressInterval: Duration

    public init(isEnabled: Bool = ScopeConfiguration.defaultIsEnabled,
                maxEvents: Int = 2_000,
                maxSessions: Int = 50,
                captureContent: Bool = true,
                logToOSLog: Bool = true,
                logContent: Bool = false,
                streamProgressInterval: Duration = .milliseconds(250)) {
        self.isEnabled = isEnabled
        self.maxEvents = maxEvents
        self.maxSessions = maxSessions
        self.captureContent = captureContent
        self.logToOSLog = logToOSLog
        self.logContent = logContent
        self.streamProgressInterval = streamProgressInterval
    }

    /// `true` when the library itself is compiled with `DEBUG` (netfox convention).
    public static var defaultIsEnabled: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
