import Foundation

public enum MessageRole: String, Sendable, Codable, Equatable {
    case user
    case assistant
    case systemNotice
}
