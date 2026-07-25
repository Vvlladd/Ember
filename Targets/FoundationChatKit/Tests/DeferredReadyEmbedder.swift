import Foundation
@testable import FoundationChatKit

/// Gemma-shaped test double: `embed` returns nil until the asynchronous load finishes, and
/// `ready()` suspends until it does. `finishLoading()` stands in for the loader task completing,
/// so tests can drive the exact ordering (backfill-before-ready vs backfill-after-ready)
/// deterministically instead of racing a real Core ML load.
final class DeferredReadyEmbedder: TextEmbedder, @unchecked Sendable {
    /// Same vector space as `MockEmbedder` so migration assertions read the familiar id.
    let identity = EmbedderIdentity(id: "mock-bag-of-words", dimension: 8)

    private let inner = MockEmbedder()
    private let lock = NSLock()
    private var loaded = false
    /// At most one waiter — enough for the coordinator's single readiness task.
    private var waiter: CheckedContinuation<Void, Never>?

    func embed(_ text: String, role: EmbeddingRole) -> [Float]? {
        lock.lock(); let isLoaded = loaded; lock.unlock()
        guard isLoaded else { return nil }
        return inner.embed(text, role: role)
    }

    func ready() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if loaded {
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func finishLoading() {
        lock.lock()
        loaded = true
        let continuation = waiter
        waiter = nil
        lock.unlock()
        continuation?.resume()
    }
}
