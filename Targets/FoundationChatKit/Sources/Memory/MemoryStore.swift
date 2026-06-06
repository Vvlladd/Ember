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

    /// Persist a model-curated fact as a `MemoryNote`. Trims; ignores empty. ALWAYS persists a
    /// non-empty fact so `SaveMemoryTool`'s "Saved." is honest — even when embedding is unavailable
    /// (non-Apple-Intelligence host, or OOV/empty-after-`@Guide` text). The embedding is optional:
    /// when present the note is retrievable (auto-RAG + searchMemory) in FUTURE conversations; when
    /// absent the note is still stored and visible/recoverable in `snapshot()` (scores 0 in cosine,
    /// so it is harmlessly filtered out of search by the threshold).
    /// Invalidates the snapshot cache so the next read includes the new note.
    public func saveNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let vector = embedder.embed(trimmed)   // may be nil if embedding is unavailable
        let note = MemoryNote(text: trimmed, createdAt: Date(),
                              embedding: vector.map { Self.archive($0) })
        context.insert(note)
        try? context.save()
        cachedSnapshot = nil  // a note was written — invalidate the cache
    }

    /// Cosine similarity at or above which a candidate note is treated as a near-duplicate of an
    /// existing note (so auto-extraction skips it). Tuned for reorderings/paraphrases, not exact text.
    private static let noteDuplicateCosineThreshold: Float = 0.9

    /// Novelty-aware variant of `saveNote` for AUTO-extraction: persists `text` ONLY if it is not a
    /// near-duplicate of an EXISTING note (`snapshot()` records with `source == .note`). Returns
    /// whether it actually saved. Checks cheapest-first: trim/empty → normalized-text equality →
    /// cosine near-duplicate. The explicit `saveMemory` drain path keeps calling `saveNote` directly,
    /// so honest "Saved." duplicates are still allowed there; only auto-extraction de-dupes.
    @discardableResult
    public func saveNoteIfNovel(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let notes = snapshot().filter { $0.source == .note }

        // 1) Normalized-text equality: lowercase + collapse internal whitespace.
        let normalizedCandidate = Self.normalizedForDedup(trimmed)
        if notes.contains(where: { Self.normalizedForDedup($0.text) == normalizedCandidate }) {
            return false
        }

        // 2) Cosine near-duplicate: only meaningful when both sides actually embed.
        if let candidateVector = embedder.embed(trimmed) {
            for note in notes where !note.vector.isEmpty {
                if Vector.cosineSimilarity(candidateVector, note.vector) >= Self.noteDuplicateCosineThreshold {
                    return false
                }
            }
        }

        saveNote(trimmed)
        return true
    }

    /// Normalize for de-dup comparison: lowercase, collapse runs of whitespace to single spaces, trim.
    private static func normalizedForDedup(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
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
        var records = all.compactMap { message -> MemoryRecord? in
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
        let notes = (try? context.fetch(FetchDescriptor<MemoryNote>())) ?? []
        records += notes.map { note -> MemoryRecord in
            MemoryRecord(
                messageID: note.id,
                conversationID: note.id,
                conversationTitle: "Saved memory",
                role: .user,
                text: note.text,
                vector: note.embedding.map { Self.unarchive($0) } ?? [],  // unembedded note: empty vector, never matches search
                source: .note
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
