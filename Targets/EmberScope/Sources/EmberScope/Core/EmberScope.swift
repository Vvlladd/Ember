import Foundation
import FoundationModels
import Synchronization

/// EmberScope — an in-app inspector for Apple Foundation Models.
///
/// ```swift
/// #if DEBUG
/// EmberScope.start()
/// #endif
/// let session = EmberScope.session(tools: [WeatherTool()], instructions: "…", label: "chat")
/// let reply = try await session.respond(to: "Weather in Lisbon?")
/// ContentView().emberScope()          // shake (iOS) / ⌘⇧E (macOS) opens the inspector
/// ```
///
/// The facade is a namespace; all mutable state lives in `recorder` (thread-safe) and `store` (main actor).
public enum EmberScope {
    /// The process-wide event log every wrapper records into by default.
    public static let recorder = ScopeRecorder()

    /// Observable projection for the UI (main actor).
    @MainActor public static let store = ScopeStore(recorder: recorder)

    public static var configuration: ScopeConfiguration { recorder.configuration }
    public static var isRecording: Bool { recorder.isRecording }
    /// Enabled AND recording — the gate for anything user-visible (shake, buttons).
    public static var isActive: Bool { recorder.isActive }

    /// The single OSLog sink: installed once, reconfigured on every `start()` (disabled when `logToOSLog` is off).
    static let osLogSink = OSLogSink(logContent: false, isEnabled: false)
    private static let osLogSinkInstalls = Mutex(0)
    static func osLogSinkInstallCount() -> Int { osLogSinkInstalls.withLock { $0 } }

    /// Start recording. Idempotent: a later call replaces the configuration (including the OSLog sink's
    /// enablement and content privacy), re-captures the model status and refreshes the store.
    public static func start(configuration: ScopeConfiguration = ScopeConfiguration(),
                             model: SystemLanguageModel = .default) {
        recorder.start(configuration: configuration)
        osLogSink.update(isEnabled: configuration.logToOSLog, logContent: configuration.logContent)
        let installNow = osLogSinkInstalls.withLock { count -> Bool in
            guard count == 0 else { return false }
            count += 1
            return true
        }
        if installNow { recorder.addSink(osLogSink) }
        refreshModelStatus(model)
        Task { @MainActor in await store.refresh() }
    }

    /// Pause recording (keeps what was captured).
    public static func stop() {
        recorder.setRecording(false)
        Task { @MainActor in await store.refresh() }
    }

    /// Drop every captured event and session.
    public static func clear() {
        recorder.clear()
        Task { @MainActor in await store.refresh() }
    }

    // MARK: Sessions

    public static func session(model: SystemLanguageModel = .default, tools: [any Tool] = [],
                               instructions: Instructions? = nil, label: String? = nil) -> InspectedSession {
        InspectedSession(model: model, tools: tools, instructions: instructions, label: label, recorder: recorder)
    }

    @_disfavoredOverload
    public static func session(model: SystemLanguageModel = .default, tools: [any Tool] = [],
                               instructions: String? = nil, label: String? = nil) -> InspectedSession {
        InspectedSession(model: model, tools: tools, instructions: instructions, label: label, recorder: recorder)
    }

    public static func session(model: SystemLanguageModel = .default, tools: [any Tool] = [],
                               transcript: Transcript, label: String? = nil) -> InspectedSession {
        InspectedSession(model: model, tools: tools, transcript: transcript, label: label, recorder: recorder)
    }

    // MARK: Annotations & status

    /// App-level annotation shown in the timeline (and on the session when `session` is given).
    ///
    /// Notes are developer annotations, so the text is recorded **verbatim even in metadata-only mode**
    /// (`captureContent: false` does not redact it). Put counts, kinds and ids in a note — never user
    /// content. In the unified log the text still takes the `logContent` gate like any other string.
    public static func note(_ text: String, session: UUID? = nil) {
        recorder.record(.note(text), sessionID: session)
    }

    public static func refreshModelStatus(_ model: SystemLanguageModel = .default) {
        recorder.record(.modelStatus(ModelStatus(model)))
    }

    public static func addSink(_ sink: any ScopeSink) { recorder.addSink(sink) }

    // MARK: Presentation

    @MainActor public static func present() { store.isPresented = true }
    @MainActor public static func dismiss() { store.isPresented = false }
}

public extension ModelStatus {
    init(_ model: SystemLanguageModel) {
        let availability: String
        switch model.availability {
        case .available:
            availability = "available"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: availability = "unavailable: device not eligible"
            case .appleIntelligenceNotEnabled: availability = "unavailable: Apple Intelligence not enabled"
            case .modelNotReady: availability = "unavailable: model not ready"
            @unknown default: availability = "unavailable"
            }
        }
        var exact = false
        if #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) { exact = true }
        self.init(availability: availability, isAvailable: model.isAvailable, contextSize: model.contextSize,
                  supportsExactTokenCounts: exact, supportedLanguageCount: model.supportedLanguages.count,
                  osVersion: ProcessInfo.processInfo.operatingSystemVersionString)
    }
}

public extension LanguageModelSession {
    /// Inspect a session you already created. Live tool telemetry needs `EmberScope.session(...)` instead.
    func inspected(label: String? = nil, model: SystemLanguageModel = .default, tools: [any Tool] = []) -> InspectedSession {
        InspectedSession(wrapping: self, model: model, tools: tools, label: label, recorder: EmberScope.recorder)
    }
}
