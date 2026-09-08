import Foundation
import os
import Synchronization

/// Receives every recorded event synchronously (outside the recorder's lock). Must be cheap and thread-safe.
///
/// A sink must never call `ScopeRecorder.record` (directly or indirectly): `record` delivers to every sink,
/// so a sink that records would recurse without bound.
public protocol ScopeSink: Sendable {
    func receive(_ event: ScopeEvent)
}

/// The library's own diagnostics (never user content).
enum ScopeDiagnostics {
    static let log = Logger(subsystem: OSLogSink.subsystem, category: "EmberScope")
}

/// Unified-logging sink. Metadata only by default; content is interpolated `.private` unless `logContent`.
/// Filter: `log stream --predicate 'subsystem == "dev.iosunpi.emberscope"' --info --debug`
public final class OSLogSink: ScopeSink {
    public static let subsystem = "dev.iosunpi.emberscope"
    private let session = Logger(subsystem: OSLogSink.subsystem, category: "Session")
    private let request = Logger(subsystem: OSLogSink.subsystem, category: "Request")
    private let tool = Logger(subsystem: OSLogSink.subsystem, category: "Tool")
    private let error = Logger(subsystem: OSLogSink.subsystem, category: "Error")
    private let tokens = Logger(subsystem: OSLogSink.subsystem, category: "Tokens")
    private let model = Logger(subsystem: OSLogSink.subsystem, category: "Model")
    private struct Settings: Sendable { var isEnabled: Bool; var logContent: Bool }
    private let settings: Mutex<Settings>

    public init(logContent: Bool = false, isEnabled: Bool = true) {
        settings = Mutex(Settings(isEnabled: isEnabled, logContent: logContent))
    }

    /// Live reconfiguration — `EmberScope.start()` calls this on EVERY start, so a second start with a
    /// changed configuration takes effect on the already-installed sink (Task 11 review ruling).
    public func update(isEnabled: Bool, logContent: Bool) {
        settings.withLock { $0 = Settings(isEnabled: isEnabled, logContent: logContent) }
    }
    public var isEnabled: Bool { settings.withLock { $0.isEnabled } }
    public var logsContent: Bool { settings.withLock { $0.logContent } }

    public func receive(_ event: ScopeEvent) {
        let current = settings.withLock { $0 }
        guard current.isEnabled else { return }
        let logContent = current.logContent
        let sid = event.sessionID.map { String($0.uuidString.prefix(8)) } ?? "-"
        switch event.payload {
        case .sessionCreated(let info):
            session.info("[\(sid, privacy: .public)] created label=\(info.label, privacy: .public) tools=\(info.tools.count) contextSize=\(info.contextSize) restored=\(info.restoredFromTranscript)")
        case .prewarm:
            session.debug("[\(sid, privacy: .public)] prewarm")
        case .requestStarted(let r):
            request.info("[\(sid, privacy: .public)] \(r.kind.rawValue, privacy: .public) start id=\(r.requestID.uuidString.prefix(8), privacy: .public) promptChars=\(r.promptChars) format=\(r.responseFormat ?? "text", privacy: .public) temp=\(r.options.temperature ?? -1) maxTokens=\(r.options.maximumResponseTokens ?? -1) sampling=\(r.options.samplingDescription, privacy: .public)")
        case .streamProgress(let p):
            request.debug("[\(sid, privacy: .public)] progress id=\(p.requestID.uuidString.prefix(8), privacy: .public) chunks=\(p.chunkCount) chars=\(p.contentChars)")
        case .requestFinished(let e):
            request.info("[\(sid, privacy: .public)] finished id=\(e.requestID.uuidString.prefix(8), privacy: .public) status=\(String(describing: e.status), privacy: .public) duration=\(String(describing: e.duration), privacy: .public) ttft=\(e.timeToFirstToken.map { String(describing: $0) } ?? "-", privacy: .public) chunks=\(e.chunkCount) outputChars=\(e.outputChars) appended=\(e.appendedEntryCount)")
        case .toolCallStarted(let t):
            tool.info("[\(sid, privacy: .public)] call \(t.toolName, privacy: .public) id=\(t.callID.uuidString.prefix(8), privacy: .public) argChars=\(t.argumentChars)")
        case .toolCallFinished(let t):
            tool.info("[\(sid, privacy: .public)] \(t.toolName, privacy: .public) \(String(describing: t.status), privacy: .public) duration=\(String(describing: t.duration), privacy: .public) outputChars=\(t.outputChars)")
        case .error(let e):
            // kind / retryable / tool / chain are structured metadata; message + debugDescription can quote
            // prompt text (see ScopeRedaction), so they follow the logContent gate like every content field.
            let message = e.message
            let debug = e.debugDescription ?? "-"
            let chain = e.underlyingChain.joined(separator: " > ")
            if logContent {
                error.error("[\(sid, privacy: .public)] \(e.kind.rawValue, privacy: .public) retryable=\(e.isRetryable) tool=\(e.toolName ?? "-", privacy: .public) chain=\(chain, privacy: .public) message=\(message, privacy: .public) debug=\(debug, privacy: .public)")
            } else {
                error.error("[\(sid, privacy: .public)] \(e.kind.rawValue, privacy: .public) retryable=\(e.isRetryable) tool=\(e.toolName ?? "-", privacy: .public) chain=\(chain, privacy: .public) message=\(message, privacy: .private) debug=\(debug, privacy: .private)")
            }
        case .transcriptSnapshot(let s):
            tokens.info("[\(sid, privacy: .public)] snapshot entries=\(s.entries.count) used=\(s.usedTokens)/\(s.contextSize) exact=\(s.isExact)")
        case .tokenCountsResolved(let c):
            tokens.info("[\(sid, privacy: .public)] exact counts resolved entries=\(c.entryTokens.count) tools=\(c.toolsTokens ?? -1)")
        case .modelStatus(let m):
            model.info("availability=\(m.availability, privacy: .public) contextSize=\(m.contextSize) exactTokens=\(m.supportsExactTokenCounts) languages=\(m.supportedLanguageCount) os=\(m.osVersion, privacy: .public)")
        case .note:
            // The text itself is a content field (below): notes are developer annotations, but a host
            // could still put user text in one, so it takes the same `logContent` gate as a prompt.
            session.info("[\(sid, privacy: .public)] note")
        }
        for field in Self.contentFields(of: event.payload) {
            content(logger(for: field.category), field.label, field.text, logContent: logContent)
        }
    }

    enum Category: Sendable, Equatable { case session, request, tool }

    /// One free-form, user-derived string carried by a payload.
    struct ContentField: Sendable, Equatable {
        var category: Category
        var label: String
        var text: String
    }

    /// Every user-derived string `receive` logs through the `logContent` gate — `.private` unless the
    /// developer opted in. The metadata lines `receive` interpolates `.public` carry only lengths,
    /// counts, ids, kinds and tool names; the sole exception is `.error`, whose `message` / `debug`
    /// take the same gate inline so its structured fields stay on one searchable line.
    static func contentFields(of payload: ScopePayload) -> [ContentField] {
        switch payload {
        case .sessionCreated(let info):
            return info.instructions.map { [ContentField(category: .session, label: "instructions", text: $0)] } ?? []
        case .requestStarted(let r):
            return r.prompt.map { [ContentField(category: .request, label: "prompt", text: $0)] } ?? []
        case .requestFinished(let e):
            return e.output.map { [ContentField(category: .request, label: "output", text: $0)] } ?? []
        case .toolCallStarted(let t):
            return [ContentField(category: .tool, label: "arguments", text: t.arguments)]
        case .toolCallFinished(let t):
            return t.output.map { [ContentField(category: .tool, label: "output", text: $0)] } ?? []
        case .note(let text):
            return [ContentField(category: .session, label: "note", text: text)]
        case .prewarm, .streamProgress, .error, .transcriptSnapshot, .tokenCountsResolved, .modelStatus:
            return []
        }
    }

    private func logger(for category: Category) -> Logger {
        switch category {
        case .session: session
        case .request: request
        case .tool: tool
        }
    }

    /// User-derived content: `.private` unless the developer opted into `logContent`.
    private func content(_ logger: Logger, _ label: String, _ text: String, logContent: Bool) {
        if logContent {
            logger.debug("\(label, privacy: .public): \(text, privacy: .public)")
        } else {
            logger.debug("\(label, privacy: .public): \(text, privacy: .private)")
        }
    }
}
