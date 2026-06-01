import Foundation

public enum ContextEntryKind: String, Sendable, Equatable {
    case instructions
    case userPrompt
    case modelResponse
    case toolCall
    case toolOutput
}

public struct ContextEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var kind: ContextEntryKind
    public var text: String
    public var isInWindow: Bool

    public init(id: UUID = UUID(), kind: ContextEntryKind, text: String, isInWindow: Bool = true) {
        self.id = id
        self.kind = kind
        self.text = text
        self.isInWindow = isInWindow
    }
}
