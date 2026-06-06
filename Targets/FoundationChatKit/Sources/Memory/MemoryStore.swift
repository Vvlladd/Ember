import Foundation
import SwiftData

/// Embeds messages on save (and via one-time backfill) and serves brute-force cosine retrieval.
@MainActor
public final class MemoryStore {
    private let context: ModelContext
    public let embedder: any TextEmbedder

    /// Lazily built snapshot; `nil` means "rebuild on next read". Invalidated only when a vector is
    /// actually written (see `index`), so repeated reads avoid re-fetching and re-unarchiving.
    private var cachedSnapshot: [MemoryRecord]?
    /// Counts how many times the snapshot cache has actually (re)built — for tests only.
    private(set) var snapshotBuildCount = 0

    public init(context: ModelContext, embedder: any TextEmbedder) {
        self.context = context
        self.embedder = embedder
    }

    /// Embed and persist a vector for `message` if it lacks one (skips system notices / empty text).
    public func index(_ message: Message) {
        guard message.embedding == nil, message.role != .systemNotice else { return }
        guard let vector = embedder.embed(message.text) else { return }
        message.embedding = Self.archive(vector)
        try? context.save()
        cachedSnapshot = nil  // a vector was written — invalidate the cache
    }

    /// One-time embedding of all persisted messages lacking a vector.
    public func backfill() {
        let all = (try? context.fetch(FetchDescriptor<Message>())) ?? []
        for message in all where message.embedding == nil { index(message) }
    }

    /// Immutable snapshot of every embedded message for off-actor cosine search.
    /// Cached and reused until an invalidating write (see `index`) occurs.
    public func snapshot() -> [MemoryRecord] {
        if let cachedSnapshot { return cachedSnapshot }
        let all = (try? context.fetch(FetchDescriptor<Message>())) ?? []
        let records = all.compactMap { message -> MemoryRecord? in
            guard let data = message.embedding, message.role != .systemNotice else { return nil }
            return MemoryRecord(
                messageID: message.id,
                conversationID: message.conversation?.id ?? UUID(),
                conversationTitle: message.conversation?.title ?? "Untitled",
                role: message.role,
                text: message.text,
                vector: Self.unarchive(data)
            )
        }
        cachedSnapshot = records
        snapshotBuildCount += 1
        return records
    }

    /// Pure brute-force cosine top-k over a snapshot; drops excluded ids and scores below `threshold`.
    /// `nonisolated` so off-actor callers (e.g. `MemorySearchTool`) can run it without an actor hop.
    public nonisolated static func search(_ snapshot: [MemoryRecord], queryVector: [Float],
                              topK: Int = 3, threshold: Float = 0.2,
                              excludingMessageIDs excluded: Set<UUID> = []) -> [MemoryHit] {
        snapshot
            .filter { !excluded.contains($0.messageID) }
            .map { MemoryHit(record: $0, score: Vector.cosineSimilarity(queryVector, $0.vector)) }
            .filter { $0.score >= threshold }
            .sorted { $0.score > $1.score }
            .prefix(max(0, topK))
            .map { $0 }
    }

    static func archive(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }
    static func unarchive(_ d: Data) -> [Float] {
        let count = d.count / MemoryLayout<Float>.stride
        return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(count)) }
    }
}
