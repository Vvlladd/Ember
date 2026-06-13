import Foundation
import FoundationModels
import os

@MainActor
public final class FoundationModelProvider: ChatModelProvider {
    private let model = SystemLanguageModel.default
    public init() {}

    public var availability: ModelAvailability {
        switch model.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable(.deviceNotEligible)
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(.appleIntelligenceNotEnabled)
        case .unavailable(.modelNotReady):
            return .unavailable(.modelNotReady)
        case .unavailable:
            return .unavailable(.unknown)
        }
    }

    public var maxContextTokens: Int {
        // SDK: `contextSize` is a non-throwing computed property (26.4+, back-deployed).
        if #available(iOS 26.4, macOS 26.4, *) {
            return model.contextSize
        }
        return 4096
    }

    public func tokenCount(for text: String) -> Int? {
        // SDK: the real `model.tokenCount(for:)` overloads are all `async throws`, which
        // cannot be called from this synchronous protocol method. Return nil so the caller
        // falls back to its own estimator.
        nil
    }

    public func exactTokenCount(for text: String) async -> Int? {
        if #available(iOS 26.4, macOS 26.4, *) {
            return try? await model.tokenCount(for: text)
        }
        return nil
    }

    public func makeSession(settings: GenerationSettings, tools: [any Tool], restoring encodedTranscript: Data?) -> any ChatSessionHandle {
        let session: LanguageModelSession
        if let data = encodedTranscript,
           let transcript = try? JSONDecoder().decode(Transcript.self, from: data) {
            session = LanguageModelSession(tools: tools, transcript: transcript)
        } else if let instructions = settings.instructions {
            session = LanguageModelSession(tools: tools, instructions: instructions)
        } else {
            session = LanguageModelSession(tools: tools)
        }
        session.prewarm()
        return FoundationModelSession(session: session, settings: settings)
    }

    public func makeSession(settings: GenerationSettings, tools: [any Tool], seeding entries: [ContextEntry]) -> any ChatSessionHandle {
        let recap = entries.compactMap { entry -> String? in
            let speaker: String
            switch entry.kind {
            case .userPrompt: speaker = "User"
            case .modelResponse: speaker = "Assistant"
            case .instructions: speaker = "System"
            case .toolCall: speaker = "Tool call"
            case .toolOutput: speaker = "Tool output"
            case .retrievedMemory: return nil   // re-retrieved fresh each turn; never carry stale memory into the recap
            }
            return "\(speaker): \(entry.text)"
        }.joined(separator: "\n")
        let combined: String?
        if recap.isEmpty {
            combined = settings.instructions
        } else {
            let base = settings.instructions.map { $0 + "\n\n" } ?? ""
            combined = base + "Summary of earlier conversation:\n" + recap
        }
        let session = combined.map { LanguageModelSession(tools: tools, instructions: $0) }
            ?? LanguageModelSession(tools: tools)
        session.prewarm()
        return FoundationModelSession(session: session, settings: settings)
    }

    public func generateTitle(forFirstExchange exchange: TitleSeed) async -> String? {
        guard case .available = availability else { return nil }
        return await ConversationTitler.generate(from: exchange)
    }

    public func summarize(_ text: String) async -> String? {
        guard case .available = availability else { return nil }
        let session = LanguageModelSession(
            instructions: "You compress chat history into a brief, factual summary.")
        do {
            let response = try await session.respond(
                to: "Summarize the following conversation in a few sentences, preserving names, facts, and decisions:\n\(text)",
                options: UtilityGenerationOptions.summary)
            let summary = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return summary.isEmpty ? nil : summary
        } catch {
            return nil
        }
    }

    public func summarizeStructured(_ text: String) async -> ConversationSummary? {
        guard case .available = availability else { return nil }
        let session = LanguageModelSession(
            instructions: "You compress chat history into a structured recap: a brief summary, key topics, and durable user preferences (third person).")
        do {
            let response = try await session.respond(
                to: "Summarize the following conversation. Preserve names, facts, and decisions.\n\(text)",
                generating: ConversationSummary.self,
                options: UtilityGenerationOptions.summary)
            return response.content.isEmpty ? nil : response.content
        } catch {
            return nil
        }
    }

    public func extractMemories(userText: String, assistantText: String) async -> [String]? {
        guard case .available = availability else {
            EmberLog.extraction.notice("extractMemories: model unavailable — returning nil")
            return nil
        }
        return await MemoryExtractor.generate(userText: userText, assistantText: assistantText)
    }
}

@MainActor
final class FoundationModelSession: ChatSessionHandle {
    private let session: LanguageModelSession
    private let settings: GenerationSettings

    init(session: LanguageModelSession, settings: GenerationSettings) {
        self.session = session
        self.settings = settings
    }

    var isResponding: Bool { session.isResponding }
    var contextEntries: [ContextEntry] { TranscriptMapping.entries(from: session.transcript) }

    private var options: GenerationOptions {
        GenerationOptions(temperature: settings.temperature, maximumResponseTokens: settings.maximumResponseTokens)
    }

    func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        let session = self.session
        let options = self.options
        return AsyncThrowingStream { continuation in
            let producer = Task { @MainActor in
                do {
                    let responseStream = session.streamResponse(to: Prompt(prompt), options: options)
                    for try await snapshot in responseStream {
                        if Task.isCancelled { break }
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    func respond(prompt: String) async throws -> String {
        do {
            return try await session.respond(to: Prompt(prompt), options: options).content
        } catch {
            throw Self.map(error)
        }
    }

    func prewarm() { session.prewarm() }
    func encodedTranscript() -> Data? { try? JSONEncoder().encode(session.transcript) }

    static func map(_ error: Error) -> Error {
        EmberLog.turn.error("session error (raw): \(String(describing: error), privacy: .public)")
        if let toolError = error as? LanguageModelSession.ToolCallError {
            return ChatError.toolFailed(tool: toolError.tool.name,
                                        message: String(describing: toolError.underlyingError))
        }
        if let genError = error as? LanguageModelSession.GenerationError {
            switch genError {
            case .exceededContextWindowSize: return ChatError.contextOverflow
            case .guardrailViolation: return ChatError.guardrailViolation
            case .rateLimited: return ChatError.rateLimited
            case .refusal: return ChatError.refusal(nil)
            case .decodingFailure: return ChatError.decodingFailure
            default:
                // A generic GenerationError (Code=-1) wrapping an internal token-generation failure
                // is transient and retryable — map it instead of dumping the raw NSError.
                if isTransientGenerationFailure(error) { return ChatError.generationInterrupted }
                return ChatError.unknown(String(describing: genError))
            }
        }
        if isTransientGenerationFailure(error) { return ChatError.generationInterrupted }
        return error
    }

    /// True if `error` (or anything in its underlying-error chain) is an Apple on-device
    /// token-generation failure — domain `com.apple.tokengeneration`. These are intermittent
    /// runtime failures (resource pressure / internal model state), distinct from context overflow.
    static func isTransientGenerationFailure(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == "com.apple.tokengeneration" { return true }
        var chain: [Error] = []
        if let single = ns.userInfo[NSUnderlyingErrorKey] as? Error { chain.append(single) }
        if let many = ns.userInfo[NSMultipleUnderlyingErrorsKey] as? [Error] { chain.append(contentsOf: many) }
        return chain.contains { isTransientGenerationFailure($0) }
    }
}
