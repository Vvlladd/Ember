import Foundation
import FoundationModels
@testable import EmberScope

/// A trivial tool for wrapper tests. `Arguments` is @Generable so JSON rendering is exercised.
struct EchoTool: Tool {
    let name = "echo"
    let description = "Echo the text back."
    @Generable struct Arguments {
        @Guide(description: "Text to echo") var text: String
    }
    var shouldThrow = false
    func call(arguments: Arguments) async throws -> String {
        if shouldThrow { throw EchoError.boom }
        return "echo: \(arguments.text)"
    }
}
enum EchoError: Error { case boom }

enum Fixtures {
    static let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let requestID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let callID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let date = Date(timeIntervalSince1970: 1_700_000_000)

    static func event(_ payload: ScopePayload, sequence: UInt64 = 1, sessionID: UUID? = sessionID,
                      at date: Date = date) -> ScopeEvent {
        ScopeEvent(id: UUID(), sequence: sequence, timestamp: date, sessionID: sessionID, payload: payload)
    }

    static let sessionInfo = SessionInfo(
        label: "chat", instructions: "You are terse.",
        tools: [ToolInfo(name: "echo", description: "Echo the text back.",
                         parametersJSON: "{\"type\":\"object\"}", includesSchemaInInstructions: true)],
        contextSize: 4096, modelDescription: "SystemLanguageModel", restoredFromTranscript: false)

    static let requestStart = RequestStart(
        requestID: requestID, kind: .stream, prompt: "Hello there",
        options: RequestOptions(temperature: 0.7, maximumResponseTokens: 200, samplingDescription: "default"),
        responseFormat: nil, includeSchemaInPrompt: nil)

    static let requestEnd = RequestEnd(
        requestID: requestID, status: .succeeded, duration: .milliseconds(1_250),
        timeToFirstToken: .milliseconds(300), chunkCount: 12, output: "Hi!", outputChars: 3,
        appendedEntryCount: 2, resolvedPrompt: nil)

    static let errorRecord = ScopeErrorRecord(
        id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, kind: .rateLimited,
        requestID: requestID, toolCallID: nil, toolName: nil, message: "Rate limited",
        debugDescription: "too many requests", recoverySuggestion: "Try again later",
        failureReason: nil, underlyingChain: [], isRetryable: true)

    /// A synthetic transcript with every entry kind (used from Task 3 on).
    static func transcript() -> Transcript {
        let call = Transcript.ToolCall(id: "call-1", toolName: "echo",
                                       arguments: GeneratedContent(properties: ["text": "hi"]))
        return Transcript(entries: [
            .instructions(.init(id: "e-instr", segments: [.text(.init(id: "s1", content: "You are terse."))],
                                toolDefinitions: [.init(tool: EchoTool())])),
            .prompt(.init(id: "e-prompt", segments: [.text(.init(id: "s2", content: "Echo hi please"))],
                          options: GenerationOptions(sampling: .greedy, temperature: 0, maximumResponseTokens: 50),
                          responseFormat: nil)),
            .toolCalls(.init(id: "e-calls", [call])),
            .toolOutput(.init(id: "e-out", toolName: "echo", segments: [.text(.init(id: "s3", content: "echo: hi"))])),
            .response(.init(id: "e-resp", assetIDs: [], segments: [.text(.init(id: "s4", content: "Done: hi"))])),
        ])
    }
}
