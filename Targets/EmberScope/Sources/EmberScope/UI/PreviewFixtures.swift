import Foundation
import FoundationModels

// Previews and their fixtures are DEBUG-only: a Release build of the library must not carry a
// synthetic transcript or the code that builds it. Tests build DEBUG and use @testable import.
#if DEBUG
extension ScopeStore {
    /// A populated store for SwiftUI previews: a chat session with tools, a streamed turn, a tool call,
    /// a failed request, a hidden "title" session, notes, and model status.
    @MainActor static var preview: ScopeStore {
        let recorder = ScopeRecorder(configuration: ScopeConfiguration(isEnabled: true, logToOSLog: false), isRecording: true)
        let chat = UUID(), title = UUID()
        let base = Date()

        recorder.record(.modelStatus(ModelStatus(availability: "unavailable: Apple Intelligence not enabled", isAvailable: false,
                                                 contextSize: 4096, supportsExactTokenCounts: true, supportedLanguageCount: 23,
                                                 osVersion: "Version 26.6 (Build 25G83)")))
        let tools = [ToolInfo(name: "dateTime", description: "Current date and time.", parametersJSON: "{\"type\":\"object\",\"properties\":{}}", includesSchemaInInstructions: true),
                     ToolInfo(name: "calculator", description: "Evaluate an arithmetic expression.", parametersJSON: "{\"type\":\"object\",\"properties\":{\"expression\":{\"type\":\"string\"}},\"required\":[\"expression\"]}", includesSchemaInInstructions: true),
                     ToolInfo(name: "searchMemory", description: "Search the user's past conversations.", parametersJSON: "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}},\"required\":[\"query\"]}", includesSchemaInInstructions: true)]
        recorder.record(.sessionCreated(SessionInfo(label: "chat", instructions: "You are Ember, a helpful, concise on-device assistant. Keep answers short.",
                                                    tools: tools, contextSize: 4096, modelDescription: "SystemLanguageModel", restoredFromTranscript: false)), sessionID: chat)
        let transcript = Transcript(entries: [
            .instructions(.init(id: "i", segments: [.text(.init(content: "You are Ember, a helpful, concise on-device assistant. Keep answers short."))],
                                toolDefinitions: tools.map { .init(name: $0.name, description: $0.description, parameters: GeneratedContent.generationSchema) })),
            .prompt(.init(id: "p1", segments: [.text(.init(content: "⟦memory⟧\nthe user said: I'm planning a trip to Lisbon in September\n⟦/memory⟧\nWhat should I pack?"))],
                          options: GenerationOptions(temperature: 0.7))),
            .response(.init(id: "r1", assetIDs: [], segments: [.text(.init(content: "Light layers, a rain shell for evenings, comfortable shoes for the hills, and sunscreen."))])),
            .prompt(.init(id: "p2", segments: [.text(.init(content: "What's 4892 * 1773?"))], options: GenerationOptions(temperature: 0.7))),
            .toolCalls(.init(id: "c1", [.init(id: "call-1", toolName: "calculator", arguments: GeneratedContent(properties: ["expression": "4892*1773"]))])),
            .toolOutput(.init(id: "o1", toolName: "calculator", segments: [.text(.init(content: "8673516"))])),
            .response(.init(id: "r2", assetIDs: [], segments: [.text(.init(content: "4892 × 1773 = 8,673,516."))])),
        ])
        let snapshot = TranscriptSnapshot.make(from: transcript, sessionID: chat, contextSize: 4096, takenAt: base)
        recorder.record(.transcriptSnapshot(snapshot), sessionID: chat)
        recorder.record(.note("retrieval: 1 hit injected (78 chars)"), sessionID: chat)

        let r1 = UUID()
        recorder.record(.requestStarted(RequestStart(requestID: r1, kind: .stream, prompt: "⟦memory⟧…⟦/memory⟧\nWhat should I pack?",
                                                     options: RequestOptions(temperature: 0.7, maximumResponseTokens: nil, samplingDescription: "default"),
                                                     responseFormat: nil, includeSchemaInPrompt: nil)), sessionID: chat)
        recorder.record(.streamProgress(RequestProgress(requestID: r1, chunkCount: 14, contentChars: 61)), sessionID: chat)
        recorder.record(.requestFinished(RequestEnd(requestID: r1, status: .succeeded, duration: .milliseconds(1_840), timeToFirstToken: .milliseconds(410),
                                                    chunkCount: 23, output: "Light layers, a rain shell for evenings, comfortable shoes for the hills, and sunscreen.",
                                                    outputChars: 88, appendedEntryCount: 2, resolvedPrompt: nil)), sessionID: chat)
        let r2 = UUID(), call = UUID()
        recorder.record(.requestStarted(RequestStart(requestID: r2, kind: .stream, prompt: "What's 4892 * 1773?",
                                                     options: RequestOptions(temperature: 0.7, maximumResponseTokens: nil, samplingDescription: "default"),
                                                     responseFormat: nil, includeSchemaInPrompt: nil)), sessionID: chat)
        recorder.record(.toolCallStarted(ToolCallStart(callID: call, toolName: "calculator", arguments: "{\"expression\":\"4892*1773\"}")), sessionID: chat)
        recorder.record(.toolCallFinished(ToolCallEnd(callID: call, toolName: "calculator", status: .succeeded, duration: .microseconds(640), output: "8673516")), sessionID: chat)
        recorder.record(.requestFinished(RequestEnd(requestID: r2, status: .succeeded, duration: .milliseconds(2_310), timeToFirstToken: .milliseconds(1_120),
                                                    chunkCount: 9, output: "4892 × 1773 = 8,673,516.", outputChars: 24, appendedEntryCount: 4, resolvedPrompt: nil)), sessionID: chat)
        recorder.record(.transcriptSnapshot(snapshot), sessionID: chat)
        recorder.record(.tokenCountsResolved(TokenCounts(snapshotID: snapshot.id,
                                                         entryTokens: Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.id, Int(Double($0.tokens) * 1.1)) }),
                                                         toolsTokens: 212)), sessionID: chat)
        let r3 = UUID()
        recorder.record(.requestStarted(RequestStart(requestID: r3, kind: .stream, prompt: String(repeating: "Tell me more. ", count: 40),
                                                     options: RequestOptions(temperature: 0.7, maximumResponseTokens: nil, samplingDescription: "default"),
                                                     responseFormat: nil, includeSchemaInPrompt: nil)), sessionID: chat)
        let overflow = ScopeErrorRecord(kind: .exceededContextWindowSize, requestID: r3, toolCallID: nil, toolName: nil,
                                        message: "The prompt exceeds the model's context window.",
                                        debugDescription: "exceededContextWindowSize: 4312 > 4096", recoverySuggestion: "Shorten the prompt or start a new session.",
                                        failureReason: nil, underlyingChain: [], isRetryable: false)
        recorder.record(.error(overflow), sessionID: chat)
        recorder.record(.requestFinished(RequestEnd(requestID: r3, status: .failed(errorID: overflow.id), duration: .milliseconds(95), timeToFirstToken: nil,
                                                    chunkCount: 0, output: nil, outputChars: 0, appendedEntryCount: 0, resolvedPrompt: nil)), sessionID: chat)
        recorder.record(.note("compaction (overflow): 7 entries → 3 seeded entries"), sessionID: chat)

        recorder.record(.sessionCreated(SessionInfo(label: "title", instructions: "You write very short, descriptive chat titles. No quotes, 3-5 words.",
                                                    tools: [], contextSize: 4096, modelDescription: "SystemLanguageModel", restoredFromTranscript: false)), sessionID: title)
        let r4 = UUID()
        recorder.record(.requestStarted(RequestStart(requestID: r4, kind: .respond, prompt: "Summarize this conversation's topic as a 3-5 word title.\nUser: What should I pack?\nAssistant: Light layers…",
                                                     options: RequestOptions(temperature: 0, maximumResponseTokens: 24, samplingDescription: "greedy"),
                                                     responseFormat: "ConversationTitle", includeSchemaInPrompt: true)), sessionID: title)
        let transient = ScopeErrorRecord(kind: .transientGeneration, requestID: r4, toolCallID: nil, toolName: nil,
                                         message: "FoundationModels.LanguageModelSession.GenerationError (-1)", debugDescription: "Error Domain=… Code=-1",
                                         recoverySuggestion: nil, failureReason: nil, underlyingChain: ["com.apple.tokengeneration(10)"], isRetryable: true)
        recorder.record(.error(transient), sessionID: title)
        recorder.record(.requestFinished(RequestEnd(requestID: r4, status: .failed(errorID: transient.id), duration: .milliseconds(620), timeToFirstToken: nil,
                                                    chunkCount: 0, output: nil, outputChars: 0, appendedEntryCount: 0, resolvedPrompt: nil)), sessionID: title)
        recorder.record(.note("retrying after transient error"), sessionID: title)

        return ScopeStore(recorder: recorder)   // `init` folds synchronously
    }
}
#endif
