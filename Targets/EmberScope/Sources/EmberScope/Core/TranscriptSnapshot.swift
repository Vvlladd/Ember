import Foundation
import FoundationModels

public struct ToolDefinitionInfo: Sendable, Codable, Equatable {
    public var name: String
    public var description: String
    public init(name: String, description: String) { self.name = name; self.description = description }
}

/// Framework-agnostic mirror of one `Transcript.Entry`, plus its token cost.
public struct ScopeEntry: Sendable, Codable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case instructions, prompt, response, toolCalls, toolOutput
    }
    /// `Transcript.Entry.id` — stable across snapshots of the same session.
    public var id: String
    public var kind: Kind
    /// Text segments joined; tool calls rendered as `name(argumentsJSON)` one per line.
    public var text: String
    /// JSON of structured segments / single tool-call arguments.
    public var structuredJSON: String?
    public var toolName: String?
    /// Instructions only: the tool definitions the model sees.
    public var toolDefinitions: [ToolDefinitionInfo]
    /// Prompt only.
    public var options: RequestOptions?
    /// Prompt only: guided-generation type name.
    public var responseFormat: String?
    public var tokens: Int
    public var isExact: Bool

    public init(id: String, kind: Kind, text: String, structuredJSON: String? = nil, toolName: String? = nil,
                toolDefinitions: [ToolDefinitionInfo] = [], options: RequestOptions? = nil,
                responseFormat: String? = nil, tokens: Int, isExact: Bool = false) {
        self.id = id; self.kind = kind; self.text = text; self.structuredJSON = structuredJSON
        self.toolName = toolName; self.toolDefinitions = toolDefinitions; self.options = options
        self.responseFormat = responseFormat; self.tokens = tokens; self.isExact = isExact
    }
}

/// The context window of one session at one moment, with per-entry token cost.
public struct TranscriptSnapshot: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var sessionID: UUID
    public var takenAt: Date
    public var contextSize: Int
    public var entries: [ScopeEntry]
    /// Cost of the tool definitions (name + description + schema). Informational: the model receives
    /// them inside the instructions entry, whose count already includes them — never add this to `usedTokens`.
    public var toolsTokens: Int?
    /// True when `toolsTokens` was derived from real `Tool` values (name + description + schema JSON),
    /// false when only the transcript's `toolDefinitions` were available (name + description), which
    /// makes the figure a LOWER BOUND. The UI labels the two cases differently.
    public var toolSchemasIncluded: Bool

    public init(id: UUID = UUID(), sessionID: UUID, takenAt: Date, contextSize: Int, entries: [ScopeEntry],
                toolsTokens: Int?, toolSchemasIncluded: Bool = false) {
        self.id = id; self.sessionID = sessionID; self.takenAt = takenAt
        self.contextSize = contextSize; self.entries = entries; self.toolsTokens = toolsTokens
        self.toolSchemasIncluded = toolSchemasIncluded
    }

    /// An empty transcript is never "exact": there is nothing to count, and `applying` can never make
    /// it true (it only upgrades entries that exist), so a fresh session reads as an estimate.
    public var isExact: Bool { !entries.isEmpty && entries.allSatisfy(\.isExact) }
    public var usedTokens: Int { entries.reduce(0) { $0 + $1.tokens } }
    public var remainingTokens: Int { max(0, contextSize - usedTokens) }
    public var fraction: Double { contextSize <= 0 ? 0 : min(1, Double(usedTokens) / Double(contextSize)) }

    public func tokens(by kind: ScopeEntry.Kind) -> Int {
        entries.filter { $0.kind == kind }.reduce(0) { $0 + $1.tokens }
    }

    /// Replace estimates with exact counts for matching entry ids. Unknown ids are ignored; a nil
    /// `toolsTokens` keeps the current value.
    ///
    /// ASSUMPTION (unverified on hardware — Apple Intelligence is not enabled on the development Mac):
    /// the SDK's per-entry `tokenCount(for:)` for the INSTRUCTIONS entry is taken to already include
    /// that entry's `toolDefinitions`, exactly as the estimate does. If it did not, `usedTokens` would
    /// under-report by the tool-definition cost once counts are marked exact. No defensive arithmetic
    /// is applied here: adding `toolsTokens` on a hunch would relabel a guess as an exact count.
    public func applying(_ counts: TokenCounts) -> TranscriptSnapshot {
        var copy = self
        copy.entries = entries.map { entry in
            guard let exact = counts.entryTokens[entry.id] else { return entry }
            var e = entry
            e.tokens = exact
            e.isExact = true
            return e
        }
        if let tools = counts.toolsTokens { copy.toolsTokens = tools }
        return copy
    }

    func redacted() -> TranscriptSnapshot {
        var copy = self
        copy.entries = entries.map { entry in
            var e = entry
            e.text = ScopeRedaction.redact(entry.text)
            e.structuredJSON = ScopeRedaction.redact(entry.structuredJSON)
            return e
        }
        return copy
    }
}

public extension RequestOptions {
    init(_ options: GenerationOptions) {
        self.init(temperature: options.temperature,
                  maximumResponseTokens: options.maximumResponseTokens,
                  samplingDescription: TranscriptRendering.samplingDescription(options))
    }
}

enum TranscriptRendering {
    static func text(of segments: [Transcript.Segment]) -> String {
        segments.map { segment -> String in
            switch segment {
            case .text(let t): return t.content
            case .structure(let s): return s.content.jsonString
            @unknown default: return String(describing: segment)
            }
        }.joined()
    }

    static func structuredJSON(of segments: [Transcript.Segment]) -> String? {
        let parts = segments.compactMap { segment -> String? in
            if case .structure(let s) = segment { return s.content.jsonString }
            return nil
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    static func samplingDescription(_ options: GenerationOptions) -> String {
        guard let sampling = options.sampling else { return "default" }
        return sampling == .greedy ? "greedy" : "random"
    }

    /// Estimated cost of the tool definitions as the model sees them (name + description + schema JSON).
    static func estimatedToolsTokens(tools: [any Tool], fallback definitions: [ToolDefinitionInfo],
                                     estimator: ScopeTokenEstimator) -> Int {
        if !tools.isEmpty {
            return tools.reduce(0) { sum, tool in
                let info = ToolInfo(tool)
                return sum + estimator.estimate(info.name + " " + info.description + " " + (info.parametersJSON ?? ""))
            }
        }
        return definitions.reduce(0) { $0 + estimator.estimate($1.name + " " + $1.description) }
    }
}

public extension TranscriptSnapshot {
    /// Pure mapping. `tools` (when the session was created through EmberScope) lets the instructions
    /// estimate include each tool's schema JSON; otherwise only the transcript's name + description.
    static func make(from transcript: Transcript, sessionID: UUID, contextSize: Int, tools: [any Tool] = [],
                     takenAt: Date = Date(), estimator: ScopeTokenEstimator = ScopeTokenEstimator()) -> TranscriptSnapshot {
        var toolsTokens: Int? = nil
        // Real `Tool` values carry their parameter schema; the transcript's `ToolDefinition` does not,
        // so a snapshot made without them can only produce a lower bound.
        let toolSchemasIncluded = !tools.isEmpty
        let entries = transcript.map { entry -> ScopeEntry in
            switch entry {
            case .instructions(let i):
                let text = TranscriptRendering.text(of: i.segments)
                let defs = i.toolDefinitions.map { ToolDefinitionInfo(name: $0.name, description: $0.description) }
                let toolCost = TranscriptRendering.estimatedToolsTokens(tools: tools, fallback: defs, estimator: estimator)
                if !defs.isEmpty || !tools.isEmpty { toolsTokens = toolCost }
                return ScopeEntry(id: i.id, kind: .instructions, text: text, toolDefinitions: defs,
                                  tokens: estimator.estimate(text) + toolCost)
            case .prompt(let p):
                let text = TranscriptRendering.text(of: p.segments)
                return ScopeEntry(id: p.id, kind: .prompt, text: text,
                                  structuredJSON: TranscriptRendering.structuredJSON(of: p.segments),
                                  options: RequestOptions(p.options), responseFormat: p.responseFormat?.name,
                                  tokens: estimator.estimate(text))
            case .response(let r):
                let text = TranscriptRendering.text(of: r.segments)
                return ScopeEntry(id: r.id, kind: .response, text: text,
                                  structuredJSON: TranscriptRendering.structuredJSON(of: r.segments),
                                  tokens: estimator.estimate(text))
            case .toolCalls(let calls):
                let lines = calls.map { "\($0.toolName)(\($0.arguments.jsonString))" }
                let text = lines.joined(separator: "\n")
                let single = calls.count == 1 ? calls.first : nil
                return ScopeEntry(id: calls.id, kind: .toolCalls, text: text,
                                  structuredJSON: single?.arguments.jsonString, toolName: single?.toolName,
                                  tokens: estimator.estimate(text))
            case .toolOutput(let o):
                let text = TranscriptRendering.text(of: o.segments)
                return ScopeEntry(id: o.id, kind: .toolOutput, text: text,
                                  structuredJSON: TranscriptRendering.structuredJSON(of: o.segments),
                                  toolName: o.toolName, tokens: estimator.estimate(text))
            @unknown default:
                let text = String(describing: entry)
                return ScopeEntry(id: entry.id, kind: .response, text: text, tokens: estimator.estimate(text))
            }
        }
        return TranscriptSnapshot(sessionID: sessionID, takenAt: takenAt, contextSize: contextSize,
                                  entries: entries, toolsTokens: toolsTokens,
                                  toolSchemasIncluded: toolSchemasIncluded)
    }
}
