import Foundation

/// A Sendable scratchpad the `saveMemory` tool writes to during a turn. Buffering (rather than
/// writing inside the tool) keeps the tool pure and avoids hopping a `@MainActor` SwiftData store
/// into a Sendable tool: the coordinator drains and persists the facts after the turn completes.
public actor MemoryWriteBuffer {
    private var facts: [String] = []
    public init() {}

    /// Append a fact the model chose to remember.
    public func add(_ fact: String) { facts.append(fact) }

    /// Return and clear all buffered facts.
    public func drain() -> [String] {
        let drained = facts
        facts.removeAll()
        return drained
    }
}
