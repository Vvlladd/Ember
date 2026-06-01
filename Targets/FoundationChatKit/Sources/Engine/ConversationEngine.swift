import Foundation
import Observation

/// Owns one conversation's live session and drives the turn lifecycle. MVVM view model:
/// the SwiftUI layer binds to `messages`, `isResponding`, `budget`, `lastError`.
@MainActor
@Observable
public final class ConversationEngine {
    public private(set) var messages: [ChatMessage] = []
    public internal(set) var isResponding: Bool = false
    public private(set) var budget: TokenBudgetSnapshot
    public private(set) var lastError: ChatError?

    private let provider: any ChatModelProvider
    private var session: any ChatSessionHandle
    private var settings: GenerationSettings
    private let calculator: TokenBudgetCalculator
    private let now: () -> Date
    private var turnTask: Task<Void, Never>?

    public init(
        provider: any ChatModelProvider,
        settings: GenerationSettings = GenerationSettings(),
        restoring encodedTranscript: Data? = nil,
        calculator: TokenBudgetCalculator = TokenBudgetCalculator(),
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.settings = settings
        self.calculator = calculator
        self.now = now
        self.session = provider.makeSession(settings: settings, restoring: encodedTranscript)
        self.budget = TokenBudgetSnapshot(maxTokens: provider.maxContextTokens, usedTokens: 0, isExact: false, lines: [])
        self.messages = ContextProjection.bubbles(from: session.contextEntries, now: now)
        recomputeBudget(inFlight: nil)
    }

    public func send(_ text: String) async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isResponding else { return }
        lastError = nil
        isResponding = true

        messages.append(ChatMessage(role: .user, text: prompt, createdAt: now()))
        var assistant = ChatMessage(role: .assistant, text: "", createdAt: now(), isStreaming: true)
        messages.append(assistant)
        let assistantIndex = messages.count - 1

        do {
            for try await snapshot in session.stream(prompt: prompt) {
                assistant.text = snapshot
                messages[assistantIndex] = assistant
                recomputeBudget(inFlight: snapshot)
            }
            assistant.isStreaming = false
            messages[assistantIndex] = assistant
            recomputeBudget(inFlight: nil)
        } catch {
            handle(error, assistantIndex: assistantIndex)
        }
        isResponding = false
    }

    public func cancel() { turnTask?.cancel() }

    private func handle(_ error: Error, assistantIndex: Int) {
        if assistantIndex < messages.count, messages[assistantIndex].role == .assistant,
           messages[assistantIndex].text.isEmpty {
            messages.remove(at: assistantIndex)
        } else if assistantIndex < messages.count {
            messages[assistantIndex].isStreaming = false
        }
        let chatError = (error as? ChatError) ?? .unknown(String(describing: error))
        switch chatError {
        case .contextOverflow:
            recoverFromOverflow()
        default:
            lastError = chatError
        }
    }

    private func recoverFromOverflow() {
        let condensed = OverflowRecovery.condense(session.contextEntries)
        session = provider.makeSession(settings: settings, restoring: session.encodedTranscript())
        messages.append(ChatMessage(role: .systemNotice,
                                    text: "Context window was full — older turns were compacted to keep the chat going.",
                                    createdAt: now()))
        _ = condensed
        recomputeBudget(inFlight: nil)
    }

    private func recomputeBudget(inFlight: String?) {
        // Capture provider reference on MainActor before entering the synchronous closure
        let providerRef = provider
        budget = calculator.snapshot(
            maxTokens: providerRef.maxContextTokens,
            instructions: settings.instructions,
            entries: session.contextEntries,
            inFlight: inFlight,
            exactCount: { text in providerRef.tokenCount(for: text) }
        )
    }
}
