import Foundation

public struct SessionInfo: Sendable, Codable, Equatable {
    public var label: String
    public var instructions: String?
    public var tools: [ToolInfo]
    public var contextSize: Int
    public var modelDescription: String
    public var restoredFromTranscript: Bool
    public init(label: String, instructions: String?, tools: [ToolInfo], contextSize: Int,
                modelDescription: String, restoredFromTranscript: Bool) {
        self.label = label; self.instructions = instructions; self.tools = tools
        self.contextSize = contextSize; self.modelDescription = modelDescription
        self.restoredFromTranscript = restoredFromTranscript
    }
}

public struct ToolInfo: Sendable, Codable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String
    /// `GenerationSchema` encoded as JSON (nil when encoding failed or the tool is only known by name).
    public var parametersJSON: String?
    public var includesSchemaInInstructions: Bool
    public init(name: String, description: String, parametersJSON: String?, includesSchemaInInstructions: Bool) {
        self.name = name; self.description = description
        self.parametersJSON = parametersJSON; self.includesSchemaInInstructions = includesSchemaInInstructions
    }
}

/// Plain-value mirror of `GenerationOptions` (its `SamplingMode` has no public cases).
public struct RequestOptions: Sendable, Codable, Equatable {
    public var temperature: Double?
    public var maximumResponseTokens: Int?
    /// "default" (nil sampling), "greedy", or "random".
    public var samplingDescription: String
    public init(temperature: Double?, maximumResponseTokens: Int?, samplingDescription: String) {
        self.temperature = temperature; self.maximumResponseTokens = maximumResponseTokens
        self.samplingDescription = samplingDescription
    }
}

public enum RequestKind: String, Sendable, Codable { case respond, stream }

public struct RequestStart: Sendable, Codable, Equatable {
    public var requestID: UUID
    public var kind: RequestKind
    /// Known immediately for `String` prompts; nil for `Prompt` values (resolved at finish from the transcript).
    public var prompt: String?
    public var options: RequestOptions
    /// Guided-generation type name (`String(describing: Content.self)`) or nil for plain text.
    public var responseFormat: String?
    public var includeSchemaInPrompt: Bool?
    public init(requestID: UUID, kind: RequestKind, prompt: String?, options: RequestOptions,
                responseFormat: String?, includeSchemaInPrompt: Bool?) {
        self.requestID = requestID; self.kind = kind; self.prompt = prompt; self.options = options
        self.responseFormat = responseFormat; self.includeSchemaInPrompt = includeSchemaInPrompt
    }
}

public struct RequestProgress: Sendable, Codable, Equatable {
    public var requestID: UUID
    public var chunkCount: Int
    public var contentChars: Int
    public init(requestID: UUID, chunkCount: Int, contentChars: Int) {
        self.requestID = requestID; self.chunkCount = chunkCount; self.contentChars = contentChars
    }
}

public enum RequestStatus: Sendable, Codable, Equatable {
    case succeeded
    case failed(errorID: UUID)
    case cancelled
}

public struct RequestEnd: Sendable, Codable, Equatable {
    public var requestID: UUID
    public var status: RequestStatus
    public var duration: Duration
    public var timeToFirstToken: Duration?
    public var chunkCount: Int
    /// Final text (or JSON for guided generation). nil on failure/cancellation.
    public var output: String?
    public var outputChars: Int
    /// Transcript entries the SDK appended for this request (prompt + tool calls/outputs + response).
    public var appendedEntryCount: Int
    /// Prompt text recovered from the transcript when the request was made with a `Prompt` value.
    public var resolvedPrompt: String?
    public init(requestID: UUID, status: RequestStatus, duration: Duration, timeToFirstToken: Duration?,
                chunkCount: Int, output: String?, outputChars: Int, appendedEntryCount: Int, resolvedPrompt: String?) {
        self.requestID = requestID; self.status = status; self.duration = duration
        self.timeToFirstToken = timeToFirstToken; self.chunkCount = chunkCount; self.output = output
        self.outputChars = outputChars; self.appendedEntryCount = appendedEntryCount; self.resolvedPrompt = resolvedPrompt
    }
}

public struct ToolCallStart: Sendable, Codable, Equatable {
    public var callID: UUID
    public var toolName: String
    /// Arguments rendered as JSON when possible.
    public var arguments: String
    public init(callID: UUID, toolName: String, arguments: String) {
        self.callID = callID; self.toolName = toolName; self.arguments = arguments
    }
}

public enum ToolCallStatus: Sendable, Codable, Equatable {
    case succeeded
    case failed(errorID: UUID)
}

public struct ToolCallEnd: Sendable, Codable, Equatable {
    public var callID: UUID
    public var toolName: String
    public var status: ToolCallStatus
    public var duration: Duration
    public var output: String?
    public init(callID: UUID, toolName: String, status: ToolCallStatus, duration: Duration, output: String?) {
        self.callID = callID; self.toolName = toolName; self.status = status; self.duration = duration; self.output = output
    }
}

public struct ModelStatus: Sendable, Codable, Equatable {
    public var availability: String
    public var isAvailable: Bool
    public var contextSize: Int
    public var supportsExactTokenCounts: Bool
    public var supportedLanguageCount: Int
    public var osVersion: String
    public init(availability: String, isAvailable: Bool, contextSize: Int, supportsExactTokenCounts: Bool,
                supportedLanguageCount: Int, osVersion: String) {
        self.availability = availability; self.isAvailable = isAvailable; self.contextSize = contextSize
        self.supportsExactTokenCounts = supportsExactTokenCounts; self.supportedLanguageCount = supportedLanguageCount
        self.osVersion = osVersion
    }
}

/// Exact token counts for one `TranscriptSnapshot`, keyed by `ScopeEntry.id`.
public struct TokenCounts: Sendable, Codable, Equatable {
    public var snapshotID: UUID
    public var entryTokens: [String: Int]
    public var toolsTokens: Int?
    public init(snapshotID: UUID, entryTokens: [String: Int], toolsTokens: Int?) {
        self.snapshotID = snapshotID; self.entryTokens = entryTokens; self.toolsTokens = toolsTokens
    }
}

// Temporary stub — Task 3 replaces this with the real snapshot type in TranscriptSnapshot.swift.
public struct TranscriptSnapshot: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var sessionID: UUID
    public init(id: UUID, sessionID: UUID) { self.id = id; self.sessionID = sessionID }
}
