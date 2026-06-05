import Foundation
import Observation

/// The app's brain: owns the model provider, the SwiftData store, the conversation list,
/// the current selection, and the live `ConversationEngine`. Persistence is injected into
/// each engine so completed turns are saved durably as they happen.
@MainActor
@Observable
public final class ChatCoordinator {
    public private(set) var conversations: [Conversation] = []
    public private(set) var engine: ConversationEngine?
    public private(set) var selectedID: UUID?
    public private(set) var availability: ModelAvailability
    public private(set) var isProcessing = false
    public var searchText: String = ""

    private let provider: any ChatModelProvider
    private let store: ConversationStore
    private let settings: GenerationSettings
    private let modelVersionTag: String
    private let now: () -> Date

    public init(
        provider: any ChatModelProvider,
        store: ConversationStore,
        settings: GenerationSettings = GenerationSettings(
            instructions: "You are Ember, a helpful, concise on-device assistant. Keep answers short."),
        modelVersionTag: String = ProcessInfo.processInfo.operatingSystemVersionString,
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.store = store
        self.settings = settings
        self.modelVersionTag = modelVersionTag
        self.now = now
        self.availability = provider.availability
        reload()
    }

    public func reload() {
        conversations = (try? store.allConversations()) ?? []
    }

    public func refreshAvailability() {
        availability = provider.availability
    }

    @discardableResult
    public func newConversation() -> Conversation {
        let convo = store.createConversation(now: now())
        reload()
        select(convo.id)
        return convo
    }

    public func select(_ id: UUID?) {
        selectedID = id
        guard let id, let convo = conversations.first(where: { $0.id == id }) else {
            engine = nil
            return
        }
        engine = makeEngine(for: convo)
        // Refresh to exact token counts (26.4+) for the reopened conversation; init only ran
        // the synchronous estimator (spec 3.A "after resume").
        let engineRef = engine
        Task { await engineRef?.refreshExactBudget() }
    }

    public func deleteConversation(_ id: UUID) {
        guard let convo = conversations.first(where: { $0.id == id }) else { return }
        store.delete(convo)
        if selectedID == id { selectedID = nil; engine = nil }
        reload()
    }

    /// The conversation list filtered by `searchText`. Filters the observed `conversations`
    /// array in-memory (case-insensitive title + message match) so the sidebar stays reactive to
    /// create/delete and avoids a SwiftData fetch on every render.
    public var visibleConversations: [Conversation] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return conversations }
        return conversations.filter { convo in
            convo.title.lowercased().contains(q) ||
            convo.messages.contains { $0.text.lowercased().contains(q) }
        }
    }

    public func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let convo = conversations.first(where: { $0.id == id }) else { return }
        store.setTitle(trimmed, for: convo, custom: true)
        reload()
    }

    public func send(_ text: String) async {
        guard let engine,
              let id = selectedID,
              let convo = conversations.first(where: { $0.id == id }) else { return }
        isProcessing = true
        defer { isProcessing = false }
        let isFirstExchange = convo.orderedMessages.isEmpty
        await engine.send(text)
        // Title only after a genuinely completed first exchange (no error, non-empty reply),
        // never clobbering a user-renamed conversation, and only if it still exists.
        if isFirstExchange,
           engine.lastError == nil,
           let assistantText = engine.messages.last(where: { $0.role == .assistant })?.text,
           !assistantText.isEmpty {
            let seed = TitleSeed(userText: text, assistantText: assistantText)
            if let title = await provider.generateTitle(forFirstExchange: seed),
               conversations.contains(where: { $0.id == id }),
               !convo.titleIsCustom {
                store.setTitle(title, for: convo)
            }
        }
        reload()
    }

    private func makeEngine(for convo: Conversation) -> ConversationEngine {
        let store = self.store
        let tag = self.modelVersionTag
        let persistence = ConversationEngine.ConversationPersistence(
            recordMessage: { @MainActor message in
                store.appendMessage(role: message.role, text: message.text, to: convo, now: message.createdAt)
            },
            recordResumeState: { @MainActor data, tokens in
                store.updateResumeState(convo, transcriptData: data, modelVersionTag: tag, tokenCount: tokens)
            }
        )
        let canUseTranscript = convo.transcriptData != nil && convo.modelVersionTag == tag
        return ConversationEngine(
            provider: provider,
            settings: settings,
            restoring: canUseTranscript ? convo.transcriptData : nil,
            restoringEntries: canUseTranscript ? nil : store.contextEntries(for: convo),
            tools: Toolbox.defaultTools(),
            persistence: persistence,
            now: now
        )
    }
}
