import Foundation
import SwiftData

/// Thin persistence façade over a SwiftData context. Dual-truth: durable `Message` rows
/// for display + best-effort `transcriptData` for faithful model resume.
@MainActor
public final class ConversationStore {
    private let context: ModelContext
    public init(context: ModelContext) { self.context = context }

    public func allConversations() throws -> [Conversation] {
        let descriptor = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return try context.fetch(descriptor)
    }

    @discardableResult
    public func createConversation(now: Date) -> Conversation {
        let convo = Conversation(title: "New Chat", createdAt: now, updatedAt: now)
        context.insert(convo)
        try? context.save()
        return convo
    }

    public func appendMessage(role: MessageRole, text: String, to convo: Conversation, now: Date) {
        let message = Message(role: role, text: text, createdAt: now, conversation: convo)
        context.insert(message)
        convo.messages.append(message)
        convo.updatedAt = now
        if role == .user, convo.title == "New Chat", !text.isEmpty {
            convo.title = Self.title(from: text)
        }
        try? context.save()
    }

    public func updateResumeState(_ convo: Conversation, transcriptData: Data?, modelVersionTag: String?, tokenCount: Int) {
        convo.transcriptData = transcriptData
        convo.modelVersionTag = modelVersionTag
        convo.lastTokenCount = tokenCount
        try? context.save()
    }

    public func setTitle(_ title: String, for conversation: Conversation, custom: Bool = false) {
        conversation.title = title
        conversation.titleIsCustom = custom
        try? context.save()
    }

    /// Case-insensitive search over titles and message text. Empty query returns all.
    public func search(_ query: String) -> [Conversation] {
        let all = (try? allConversations()) ?? []
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { convo in
            convo.title.lowercased().contains(q) ||
            convo.messages.contains { $0.text.lowercased().contains(q) }
        }
    }

    public func delete(_ convo: Conversation) {
        context.delete(convo)
        try? context.save()
    }

    /// Rebuild engine context entries from durable messages (fallback when transcriptData is absent/stale).
    public func contextEntries(for convo: Conversation) -> [ContextEntry] {
        convo.orderedMessages.compactMap { message in
            switch message.role {
            case .user: return ContextEntry(kind: .userPrompt, text: message.text)
            case .assistant: return ContextEntry(kind: .modelResponse, text: message.text)
            case .systemNotice: return nil
            }
        }
    }

    static func title(from text: String, wordLimit: Int = 7) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace }).prefix(wordLimit)
        return words.joined(separator: " ")
    }
}
