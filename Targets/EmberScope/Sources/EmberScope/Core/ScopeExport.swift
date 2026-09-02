import Foundation

/// Everything worth sharing, as one Codable document.
public struct ScopeArchive: Sendable, Codable, Equatable {
    public var exportedAt: Date
    public var version: String
    public var modelStatus: ModelStatus?
    public var sessions: [SessionRecord]
    public var errors: [ScopeErrorRecord]
    public var notes: [NoteRecord]

    public init(projection: ScopeProjection, exportedAt: Date = Date()) {
        self.exportedAt = exportedAt
        self.version = EmberScopeVersion.current
        self.modelStatus = projection.modelStatus
        self.sessions = projection.sessions
        self.errors = projection.errors
        self.notes = projection.notes
    }
}

public enum ScopeExport {
    public static func json(_ archive: ScopeArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(archive)
    }

    public static func decode(_ data: Data) throws -> ScopeArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ScopeArchive.self, from: data)
    }

    public static func markdown(_ archive: ScopeArchive) -> String {
        var out: [String] = []
        out.append("# EmberScope export")
        out.append("")
        out.append("- Exported: \(ScopeFormatting.timestamp(archive.exportedAt))")
        out.append("- EmberScope \(archive.version)")
        out.append("")
        out.append("## Model")
        if let m = archive.modelStatus {
            out.append("- availability: \(m.availability)")
            out.append("- contextSize: \(m.contextSize)")
            out.append("- exact token counts: \(m.supportsExactTokenCounts ? "supported" : "not supported (needs 26.4+)")")
            out.append("- supported languages: \(m.supportedLanguageCount)")
            out.append("- OS: \(m.osVersion)")
        } else {
            out.append("- (not captured — call EmberScope.start())")
        }
        out.append("")
        out.append("## Sessions (\(archive.sessions.count))")
        for session in archive.sessions {
            out.append("")
            out.append("### \(session.label) · \(ScopeFormatting.short(session.id)) · created \(ScopeFormatting.timestamp(session.createdAt))")
            out.append("- Instructions: \(session.info.instructions ?? "(none)")")
            if session.info.tools.isEmpty {
                out.append("- Tools: (none)")
            } else {
                out.append("- Tools:")
                for tool in session.info.tools { out.append("  - `\(tool.name)` — \(tool.description)") }
            }
            if let snap = session.latestSnapshot {
                out.append("- Context window: \(ScopeFormatting.tokens(snap.usedTokens)) / \(ScopeFormatting.tokens(snap.contextSize)) tokens (\(snap.isExact ? "exact" : "estimated")), \(ScopeFormatting.tokens(snap.remainingTokens)) remaining")
                out.append("")
                out.append("| # | kind | tokens | preview |")
                out.append("|---|---|---|---|")
                for (i, entry) in snap.entries.enumerated() {
                    out.append("| \(i + 1) | \(entry.kind.rawValue) | \(entry.tokens)\(entry.isExact ? "" : "~") | \(ScopeFormatting.preview(entry.text, max: 60).replacingOccurrences(of: "|", with: "\\|")) |")
                }
                out.append("")
            }
            if !session.requests.isEmpty {
                out.append("- Requests:")
                for r in session.requests {
                    let status: String
                    switch r.end?.status {
                    case .succeeded?: status = "ok"
                    case .failed?: status = "FAILED"
                    case .cancelled?: status = "cancelled"
                    case nil: status = "in flight"
                    }
                    var line = "  - [\(r.start.kind.rawValue)] \(status)"
                    if let end = r.end {
                        line += " · \(ScopeFormatting.duration(end.duration))"
                        if let ttft = end.timeToFirstToken { line += " · first token \(ScopeFormatting.duration(ttft))" }
                        line += " · \(end.chunkCount) chunks"
                    }
                    if let format = r.start.responseFormat { line += " · → \(format)" }
                    out.append(line)
                    if let prompt = r.promptText { out.append("    - prompt: \(prompt)") }
                    if let output = r.end?.output { out.append("    - output: \(output)") }
                    if let error = r.error { out.append("    - error: \(error.kind.title) — \(error.message)") }
                }
            }
            if !session.toolCalls.isEmpty {
                out.append("- Tool calls:")
                for c in session.toolCalls {
                    var line = "  - \(c.start.toolName)(\(c.start.arguments))"
                    if let end = c.end {
                        line += " → \(end.output ?? "(no output)") · \(ScopeFormatting.duration(end.duration))"
                        if case .failed = end.status { line += " · FAILED" }
                    }
                    out.append(line)
                }
            }
            if !session.errors.isEmpty {
                out.append("- Errors:")
                for e in session.errors { out.append("  - \(e.kind.title): \(e.message)\(e.debugDescription.map { " (\($0))" } ?? "")") }
            }
            if !session.notes.isEmpty {
                out.append("- Notes:")
                for n in session.notes { out.append("  - \(ScopeFormatting.timestamp(n.timestamp)) \(n.text)") }
            }
        }
        out.append("")
        out.append("## Errors (\(archive.errors.count))")
        for e in archive.errors {
            out.append("- \(e.kind.title) — \(e.message)")
            if let d = e.debugDescription { out.append("  - debug: \(d)") }
            if let r = e.recoverySuggestion { out.append("  - recovery: \(r)") }
            if !e.underlyingChain.isEmpty { out.append("  - chain: \(e.underlyingChain.joined(separator: " > "))") }
            out.append("  - retryable: \(e.isRetryable)")
        }
        if !archive.notes.isEmpty {
            out.append("")
            out.append("## Notes")
            for n in archive.notes { out.append("- \(ScopeFormatting.timestamp(n.timestamp)) \(n.text)") }
        }
        out.append("")
        return out.joined(separator: "\n")
    }
}
