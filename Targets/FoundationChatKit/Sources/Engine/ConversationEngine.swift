import Foundation
import Observation

/// Owns one conversation's live session and drives the turn lifecycle. MVVM view model:
/// the SwiftUI layer binds to `messages`, `isResponding`, `budget`, `lastError`.
@MainActor
@Observable
public final class ConversationEngine {
    /// Closures the app injects to durably persist a turn as it happens.
    public struct ConversationPersistence {
        public var recordMessage: @MainActor (ChatMessage) -> Void
        public var recordResumeState: @MainActor (_ encodedTranscript: Data?, _ usedTokens: Int) -> Void
        public init(
            recordMessage: @escaping @MainActor (ChatMessage) -> Void,
            recordResumeState: @escaping @MainActor (_ encodedTranscript: Data?, _ usedTokens: Int) -> Void
        ) {
            self.recordMessage = recordMessage
            self.recordResumeState = recordResumeState
        }
    }

    public private(set) var messages: [ChatMessage] = []
    public internal(set) var isResponding: Bool = false
    public private(set) var budget: TokenBudgetSnapshot
    public private(set) var lastError: ChatError?

    /// The exact context window currently held by the model session (drives the inspector).
    public var contextEntries: [ContextEntry] { session.contextEntries }
    /// Encoded transcript for fast/faithful resume (nil if the provider doesn't support it).
    public var encodedTranscript: Data? { session.encodedTranscript() }

    private let provider: any ChatModelProvider
    private var session: any ChatSessionHandle
    private var settings: GenerationSettings
    private let calculator: TokenBudgetCalculator
    private let persistence: ConversationPersistence?
    private let now: () -> Date
    private var turnTask: Task<Void, Never>?

    public init(
        provider: any ChatModelProvider,
        settings: GenerationSettings = GenerationSettings(),
        restoring encodedTranscript: Data? = nil,
        restoringEntries: [ContextEntry]? = nil,
        persistence: ConversationPersistence? = nil,
        calculator: TokenBudgetCalculator = TokenBudgetCalculator(),
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.settings = settings
        self.calculator = calculator
        self.persistence = persistence
        self.now = now
        if let encodedTranscript {
            self.session = provider.makeSession(settings: settings, restoring: encodedTranscript)
        } else if let restoringEntries, !restoringEntries.isEmpty {
            self.session = provider.makeSession(settings: settings, seeding: restoringEntries)
        } else {
            self.session = provider.makeSession(settings: settings, restoring: nil)
        }
        self.budget = TokenBudgetSnapshot(maxTokens: provider.maxContextTokens, usedTokens: 0, isExact: false, lines: [])
        self.messages = ContextProjection.bubbles(from: session.contextEntries, now: now)
        recomputeBudget(inFlight: nil)
    }

    public func send(_ text: String) async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isResponding else { return }
        let task = Task { await self.performTurn(prompt) }
        turnTask = task
        await task.value
    }

    public func cancel() { turnTask?.cancel() }

    private func performTurn(_ prompt: String) async {
        lastError = nil
        isResponding = true
        defer { isResponding = false }

        let userMessage = ChatMessage(role: .user, text: prompt, createdAt: now())
        messages.append(userMessage)
        persistence?.recordMessage(userMessage)

        let assistant = ChatMessage(role: .assistant, text: "", createdAt: now(), isStreaming: true)
        messages.append(assistant)
        let assistantIndex = messages.count - 1

        do {
            for try await snapshot in session.stream(prompt: prompt) {
                if Task.isCancelled { break }
                messages[assistantIndex].text = snapshot
                recomputeBudget(inFlight: snapshot)
            }
            if assistantIndex < messages.count { messages[assistantIndex].isStreaming = false }
            recomputeBudget(inFlight: nil)
            finalizeAssistant(at: assistantIndex)
        } catch is CancellationError {
            if assistantIndex < messages.count { messages[assistantIndex].isStreaming = false }
            finalizeAssistant(at: assistantIndex)
        } catch {
            handle(error, assistantIndex: assistantIndex)
        }
    }

    private func finalizeAssistant(at index: Int) {
        guard index < messages.count, messages[index].role == .assistant else { return }
        let final = messages[index]
        if !final.text.isEmpty { persistence?.recordMessage(final) }
        persistence?.recordResumeState(session.encodedTranscript(), budget.usedTokens)
    }

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
        session = provider.makeSession(settings: settings, seeding: condensed)
        let notice = ChatMessage(role: .systemNotice,
                                 text: "Context window was full — older turns were compacted to keep the chat going.",
                                 createdAt: now())
        messages.append(notice)
        persistence?.recordMessage(notice)
        recomputeBudget(inFlight: nil)
        persistence?.recordResumeState(session.encodedTranscript(), budget.usedTokens)
    }

    private func recomputeBudget(inFlight: String?) {
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
