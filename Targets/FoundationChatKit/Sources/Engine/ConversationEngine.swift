import Foundation
import FoundationModels
import EmberScope
import Observation
import os

/// Owns one conversation's live session and drives the turn lifecycle. MVVM view model:
/// the SwiftUI layer binds to `messages`, `isResponding`, `budget`, `lastError`.
@MainActor
@Observable
public final class ConversationEngine {
    /// Sendable seam the app injects to retrieve relevant memory before each turn. Returns the
    /// top hits for a query; the engine augments the prompt with them (see `performTurn`). Default
    /// `nil` keeps retrieval off, so existing call sites/tests are unaffected.
    public struct MemoryRetrieval: Sendable {
        public var retrieve: @Sendable (String) -> [MemoryHit]
        public init(retrieve: @escaping @Sendable (String) -> [MemoryHit]) { self.retrieve = retrieve }
    }

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

    /// Tokens kept free for the model's reply (drives proactive compaction + the Tokens tab).
    public var reservedReplyTokens: Int { settings.reservedReplyTokens }

    /// Per-bucket token breakdown for the inspector (Plan 10 WS5), derived from the current
    /// budget snapshot plus the reserved reply headroom.
    public var tokenBreakdown: TokenBreakdown {
        calculator.breakdown(from: budget, replyReserve: settings.reservedReplyTokens)
    }

    private let provider: any ChatModelProvider
    private var session: any ChatSessionHandle
    private let tools: [any Tool]
    private let toolAccounting: [ToolAccounting]
    private var settings: GenerationSettings
    private let calculator: TokenBudgetCalculator
    private let persistence: ConversationPersistence?
    private let memoryRetrieval: MemoryRetrieval?
    /// Injected by the app to durably persist user preferences harvested during compaction (the
    /// structured summary's `userPreferences`). Routed into `ContextCompactor.compact(onPreference:)`
    /// at both compaction sites; `nil` (default) keeps harvesting off, so existing call sites compile.
    private let onCompactionPreference: (@MainActor (String) -> Void)?
    private let now: () -> Date
    private var turnTask: Task<Void, Never>?

    /// The memory block injected on the current turn (empty between turns). Accounted as a
    /// "Retrieved memory" budget line so the Tokens tab reflects RAG cost immediately, not
    /// only after the model commits the augmented prompt into the transcript. Cleared at the
    /// END of performTurn (after refreshExactBudget), so the post-turn budget keeps the line.
    private var pendingMemoryBlock: String = ""

    public init(
        provider: any ChatModelProvider,
        settings: GenerationSettings = GenerationSettings(),
        restoring encodedTranscript: Data? = nil,
        restoringEntries: [ContextEntry]? = nil,
        tools: [any Tool] = [],
        persistence: ConversationPersistence? = nil,
        memoryRetrieval: MemoryRetrieval? = nil,
        onCompactionPreference: (@MainActor (String) -> Void)? = nil,
        calculator: TokenBudgetCalculator = TokenBudgetCalculator(),
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.settings = settings
        self.calculator = calculator
        self.persistence = persistence
        self.memoryRetrieval = memoryRetrieval
        self.onCompactionPreference = onCompactionPreference
        self.now = now
        self.tools = tools
        self.toolAccounting = Toolbox.accountingMetadata(for: tools)
        if let encodedTranscript {
            self.session = provider.makeSession(settings: settings, tools: tools, restoring: encodedTranscript)
        } else if let restoringEntries, !restoringEntries.isEmpty {
            self.session = provider.makeSession(settings: settings, tools: tools, seeding: restoringEntries)
        } else {
            self.session = provider.makeSession(settings: settings, tools: tools, restoring: nil)
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

        await compactIfNeeded(for: prompt)

        // Retrieve-before-generate: augment the prompt sent to the model with relevant memory,
        // while the on-screen bubble and persisted row keep the RAW prompt (clean UX). The
        // augmented text lands in the transcript, so it's budgeted and shown in the inspector.
        let hits = memoryRetrieval?.retrieve(prompt) ?? []
        let memoryBlock = MemoryContextBlock.wrap(
            hits,
            maxHits: settings.memoryInjectionMaxHits,
            maxCharsPerHit: settings.memoryInjectionMaxCharsPerHit)
        pendingMemoryBlock = memoryBlock
        if memoryRetrieval != nil {
            EmberScope.note(hits.isEmpty ? "retrieval: no memory hits"
                                         : "retrieval: \(hits.count) hit(s) injected (\(memoryBlock.count) chars)",
                            session: session.inspectionID)
        }
        // Inline `"\(block)\n\(prompt)"` join — canonical equivalent is
        // `MemoryContextBlock.augment(prompt:with:...)` (same join). Keep the two sites in sync.
        let augmented = memoryBlock.isEmpty ? prompt : "\(memoryBlock)\n\(prompt)"
        if memoryRetrieval != nil {
            EmberLog.turn.info("performTurn: \(hits.count, privacy: .public) memory hit(s) → prompt \(augmented == prompt ? "NOT augmented" : "augmented", privacy: .public)")
        }

        let userMessage = ChatMessage(role: .user, text: prompt, createdAt: now())
        messages.append(userMessage)
        persistence?.recordMessage(userMessage)

        let assistant = ChatMessage(role: .assistant, text: "", createdAt: now(), isStreaming: true)
        messages.append(assistant)
        let assistantIndex = messages.count - 1

        // Retry a transient on-device generation failure ONCE before surfacing it: these are
        // intermittent runtime hiccups (not overflow), and a clean re-stream usually succeeds.
        var attempt = 0
        while true {
            do {
                try await streamTurn(augmented, into: assistantIndex)
                if assistantIndex < messages.count { messages[assistantIndex].isStreaming = false }
                recomputeBudget(inFlight: nil)
                finalizeAssistant(at: assistantIndex)
                await refreshExactBudget()
                pendingMemoryBlock = ""      // cleared AFTER the post-turn budget keeps the line
                return
            } catch is CancellationError {
                if assistantIndex < messages.count { messages[assistantIndex].isStreaming = false }
                finalizeAssistant(at: assistantIndex)
                await refreshExactBudget()
                pendingMemoryBlock = ""      // cleared AFTER the post-turn budget keeps the line
                return
            } catch {
                let chatError = (error as? ChatError) ?? .unknown(String(describing: error))
                if attempt == 0, Self.isRetryable(chatError) {
                    attempt += 1
                    EmberLog.turn.notice("performTurn: transient error \(String(describing: chatError), privacy: .public) — retrying once")
                    // A note carries counts and CATEGORIES, never a message: `String(describing:)` on a
                    // ChatError can interpolate the model's own text, and notes are not redacted.
                    let category: String
                    switch chatError {
                    case .generationInterrupted: category = "generationInterrupted"
                    case .rateLimited: category = "rateLimited"
                    default: category = "transient"
                    }
                    EmberScope.note("retrying after transient error: \(category)", session: session.inspectionID)
                    if assistantIndex < messages.count { messages[assistantIndex].text = "" }
                    continue
                }
                EmberLog.turn.error("performTurn: stream threw — \(String(describing: error), privacy: .public)")
                pendingMemoryBlock = ""      // failed turn must not leave a stale block
                await handle(error, assistantIndex: assistantIndex)
                return
            }
        }
    }

    /// One streaming attempt: drives the assistant bubble from the session's cumulative snapshots.
    /// Throws the (already-mapped) stream error so `performTurn` can decide whether to retry.
    private func streamTurn(_ prompt: String, into assistantIndex: Int) async throws {
        for try await snapshot in session.stream(prompt: prompt) {
            if Task.isCancelled { break }
            if assistantIndex < messages.count { messages[assistantIndex].text = snapshot }
            recomputeBudget(inFlight: snapshot)
        }
    }

    /// Errors worth one automatic retry: transient generation hiccups and momentary busy/rate limits.
    private static func isRetryable(_ error: ChatError) -> Bool {
        switch error {
        case .generationInterrupted, .rateLimited: true
        default: false
        }
    }

    private func finalizeAssistant(at index: Int) {
        guard index < messages.count, messages[index].role == .assistant else { return }
        let final = messages[index]
        if !final.text.isEmpty { persistence?.recordMessage(final) }
        persistence?.recordResumeState(session.encodedTranscript(), budget.usedTokens)
    }

    private func handle(_ error: Error, assistantIndex: Int) async {
        if assistantIndex < messages.count, messages[assistantIndex].role == .assistant,
           messages[assistantIndex].text.isEmpty {
            messages.remove(at: assistantIndex)
        } else if assistantIndex < messages.count {
            messages[assistantIndex].isStreaming = false
        }
        let chatError = (error as? ChatError) ?? .unknown(String(describing: error))
        switch chatError {
        case .contextOverflow:
            await recoverFromOverflow()
        default:
            lastError = chatError
        }
    }

    /// Compact proactively when the projected turn (current context + this prompt + the reserved
    /// reply headroom) would exceed the window, so the reply always has room.
    private func compactIfNeeded(for prompt: String) async {
        let projected = budget.usedTokens + calculator.estimate(prompt) + settings.reservedReplyTokens
        guard projected > provider.maxContextTokens else { return }
        // `contextEntries` re-maps the whole transcript on every read — take it ONCE, and note the
        // count we actually compacted rather than re-reading after the await.
        let before = session.contextEntries
        guard before.count > 1 else { return }
        let condensed = await ContextCompactor.compact(before, using: provider,
                                                       onPreference: onCompactionPreference)
        EmberScope.note("compaction (proactive): \(before.count) entries → \(condensed.count) seeded entries",
                        session: session.inspectionID)
        session = provider.makeSession(settings: settings, tools: tools, seeding: condensed)
        let notice = ChatMessage(role: .systemNotice,
                                 text: "Older turns were summarized to make room.",
                                 createdAt: now())
        messages.append(notice)
        persistence?.recordMessage(notice)
        recomputeBudget(inFlight: nil)
        persistence?.recordResumeState(session.encodedTranscript(), budget.usedTokens)
    }

    private func recoverFromOverflow() async {
        let before = session.contextEntries      // read once; see compactIfNeeded
        let condensed = await ContextCompactor.compact(before, using: provider,
                                                       onPreference: onCompactionPreference)
        EmberScope.note("compaction (overflow): \(before.count) entries → \(condensed.count) seeded entries",
                        session: session.inspectionID)
        session = provider.makeSession(settings: settings, tools: tools, seeding: condensed)
        let notice = ChatMessage(role: .systemNotice,
                                 text: "Context window was full — older turns were compacted to keep the chat going.",
                                 createdAt: now())
        messages.append(notice)
        persistence?.recordMessage(notice)
        recomputeBudget(inFlight: nil)
        persistence?.recordResumeState(session.encodedTranscript(), budget.usedTokens)
    }

    /// Append a synthetic "Retrieved memory" budget line for the in-flight injected block, unless
    /// the session already committed it as a `.retrievedMemory` entry (then the calculator counts
    /// it and we must not double-count). Shared by recomputeBudget + refreshExactBudget so the
    /// line survives the post-turn exact rebuild.
    private func injectingPendingMemory(into snapshot: TokenBudgetSnapshot) -> TokenBudgetSnapshot {
        guard !pendingMemoryBlock.isEmpty,
              !session.contextEntries.contains(where: { $0.kind == .retrievedMemory }) else {
            return snapshot
        }
        let tokens = calculator.estimate(pendingMemoryBlock)
        var lines = snapshot.lines
        lines.append(BudgetLine(id: lines.count, label: TokenBudgetCalculator.retrievedMemoryInFlightLabel, tokens: tokens))
        return TokenBudgetSnapshot(maxTokens: snapshot.maxTokens,
                                   usedTokens: snapshot.usedTokens + tokens,
                                   isExact: snapshot.isExact, lines: lines)
    }

    private func recomputeBudget(inFlight: String?) {
        let providerRef = provider
        let snapshot = calculator.snapshot(
            maxTokens: providerRef.maxContextTokens,
            instructions: settings.instructions,
            entries: session.contextEntries,
            inFlight: inFlight,
            tools: toolAccounting,
            exactCount: { text in providerRef.tokenCount(for: text) }
        )
        budget = injectingPendingMemory(into: snapshot)
    }

    /// Recompute the budget using exact async token counts (26.4+). Reuses the synchronous
    /// snapshot with a prefilled cache, so there is no duplicated budget logic. Called after a
    /// turn completes; live typing keeps the estimator. Falls back to estimates per-string when
    /// the exact API is unavailable.
    public func refreshExactBudget() async {
        let providerRef = provider
        var cache: [String: Int] = [:]
        func fill(_ s: String) async {
            guard !s.isEmpty, cache[s] == nil else { return }
            if let n = await providerRef.exactTokenCount(for: s) { cache[s] = n }
        }
        if let instructions = settings.instructions { await fill(instructions) }
        for entry in session.contextEntries { await fill(entry.text) }
        for tool in toolAccounting { await fill(tool.schemaDigest) }
        let snapshot = calculator.snapshot(
            maxTokens: providerRef.maxContextTokens,
            instructions: settings.instructions,
            entries: session.contextEntries,
            inFlight: nil,
            tools: toolAccounting,
            exactCount: { cache[$0] }
        )
        budget = injectingPendingMemory(into: snapshot)
    }
}
