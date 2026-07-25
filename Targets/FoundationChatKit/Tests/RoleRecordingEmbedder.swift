import Foundation
@testable import FoundationChatKit

/// Wraps MockEmbedder and records every role passed to `embed` (lock-guarded — Sendable).
final class RoleRecordingEmbedder: TextEmbedder, @unchecked Sendable {
    private let lock = NSLock()
    private var _roles: [EmbeddingRole] = []
    private let base = MockEmbedder()
    var identity: EmbedderIdentity { base.identity }
    var recordedRoles: [EmbeddingRole] { lock.lock(); defer { lock.unlock() }; return _roles }
    func embed(_ text: String, role: EmbeddingRole) -> [Float]? {
        lock.lock(); _roles.append(role); lock.unlock()
        return base.embed(text, role: role)
    }
}
