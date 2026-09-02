import Foundation
import os

/// Receives every recorded event synchronously (outside the recorder's lock). Must be cheap and thread-safe.
public protocol ScopeSink: Sendable {
    func receive(_ event: ScopeEvent)
}

/// The library's own diagnostics (never user content).
enum ScopeDiagnostics {
    static let log = Logger(subsystem: OSLogSink.subsystem, category: "EmberScope")
}

/// Unified-logging sink. Metadata only by default; content is interpolated `.private` unless `logContent`.
/// Filter: `log stream --predicate 'subsystem == "dev.emberscope"' --info --debug`
public struct OSLogSink: ScopeSink {
    public static let subsystem = "dev.emberscope"
    private let session = Logger(subsystem: OSLogSink.subsystem, category: "Session")
    private let request = Logger(subsystem: OSLogSink.subsystem, category: "Request")
    private let tool = Logger(subsystem: OSLogSink.subsystem, category: "Tool")
    private let error = Logger(subsystem: OSLogSink.subsystem, category: "Error")
    private let tokens = Logger(subsystem: OSLogSink.subsystem, category: "Tokens")
    private let model = Logger(subsystem: OSLogSink.subsystem, category: "Model")
    private let logContent: Bool

    public init(logContent: Bool = false) { self.logContent = logContent }

    public func receive(_ event: ScopeEvent) {
        let sid = event.sessionID.map { String($0.uuidString.prefix(8)) } ?? "-"
        switch event.payload {
        case .sessionCreated(let info):
            session.info("[\(sid, privacy: .public)] created label=\(info.label, privacy: .public) tools=\(info.tools.count) contextSize=\(info.contextSize) restored=\(info.restoredFromTranscript)")
            content(session, "instructions", info.instructions)
        case .prewarm:
            session.debug("[\(sid, privacy: .public)] prewarm")
        case .requestStarted(let r):
            request.info("[\(sid, privacy: .public)] \(r.kind.rawValue, privacy: .public) start id=\(r.requestID.uuidString.prefix(8), privacy: .public) promptChars=\(r.prompt?.count ?? -1) format=\(r.responseFormat ?? "text", privacy: .public) temp=\(r.options.temperature ?? -1) maxTokens=\(r.options.maximumResponseTokens ?? -1) sampling=\(r.options.samplingDescription, privacy: .public)")
            content(request, "prompt", r.prompt)
        case .streamProgress(let p):
            request.debug("[\(sid, privacy: .public)] progress id=\(p.requestID.uuidString.prefix(8), privacy: .public) chunks=\(p.chunkCount) chars=\(p.contentChars)")
        case .requestFinished(let e):
            request.info("[\(sid, privacy: .public)] finished id=\(e.requestID.uuidString.prefix(8), privacy: .public) status=\(String(describing: e.status), privacy: .public) duration=\(String(describing: e.duration), privacy: .public) ttft=\(e.timeToFirstToken.map { String(describing: $0) } ?? "-", privacy: .public) chunks=\(e.chunkCount) outputChars=\(e.outputChars) appended=\(e.appendedEntryCount)")
            content(request, "output", e.output)
        case .toolCallStarted(let t):
            tool.info("[\(sid, privacy: .public)] call \(t.toolName, privacy: .public) id=\(t.callID.uuidString.prefix(8), privacy: .public) argChars=\(t.arguments.count)")
            content(tool, "arguments", t.arguments)
        case .toolCallFinished(let t):
            tool.info("[\(sid, privacy: .public)] \(t.toolName, privacy: .public) \(String(describing: t.status), privacy: .public) duration=\(String(describing: t.duration), privacy: .public) outputChars=\(t.output?.count ?? 0)")
            content(tool, "output", t.output)
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
        case .note(let text):
            session.info("[\(sid, privacy: .public)] note: \(text, privacy: .public)")
        }
    }

    /// User-derived content: `.private` unless the developer opted into `logContent`.
    private func content(_ logger: Logger, _ label: String, _ text: String?) {
        guard let text else { return }
        if logContent {
            logger.debug("\(label, privacy: .public): \(text, privacy: .public)")
        } else {
            logger.debug("\(label, privacy: .public): \(text, privacy: .private)")
        }
    }
}
