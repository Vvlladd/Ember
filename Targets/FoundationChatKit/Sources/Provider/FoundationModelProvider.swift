import Foundation
import FoundationModels

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

    public func makeSession(settings: GenerationSettings, restoring encodedTranscript: Data?) -> any ChatSessionHandle {
        let session: LanguageModelSession
        if let data = encodedTranscript,
           let transcript = try? JSONDecoder().decode(Transcript.self, from: data) {
            session = LanguageModelSession(transcript: transcript)
        } else if let instructions = settings.instructions {
            session = LanguageModelSession(instructions: instructions)
        } else {
            session = LanguageModelSession()
        }
        session.prewarm()
        return FoundationModelSession(session: session, settings: settings)
    }

    public func makeSession(settings: GenerationSettings, seeding entries: [ContextEntry]) -> any ChatSessionHandle {
        // Phase 1: carry the condensed entries into a fresh session as an instructions recap.
        // Robust (no fragile Transcript reconstruction) and cannot re-overflow.
        let recap = entries.map { entry -> String in
            let speaker: String
            switch entry.kind {
            case .userPrompt: speaker = "User"
            case .modelResponse: speaker = "Assistant"
            case .instructions: speaker = "System"
            case .toolCall: speaker = "Tool call"
            case .toolOutput: speaker = "Tool output"
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
        let session = combined.map { LanguageModelSession(instructions: $0) } ?? LanguageModelSession()
        session.prewarm()
        return FoundationModelSession(session: session, settings: settings)
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
            Task { @MainActor in
                do {
                    let responseStream = session.streamResponse(to: Prompt(prompt), options: options)
                    for try await snapshot in responseStream {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
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
        guard let genError = error as? LanguageModelSession.GenerationError else { return error }
        switch genError {
        case .exceededContextWindowSize: return ChatError.contextOverflow
        case .guardrailViolation: return ChatError.guardrailViolation
        case .rateLimited: return ChatError.rateLimited
        case .refusal: return ChatError.refusal(nil)
        case .decodingFailure: return ChatError.decodingFailure
        default: return ChatError.unknown(String(describing: genError))
        }
    }
}
