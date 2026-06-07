import Foundation
import SwiftData
import os

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
        EmberLog.memory.info("saveNote: persisted (embedded=\(vector != nil ? "yes" : "NO", privacy: .public)) \"\(trimmed, privacy: .public)\"")
    }

    /// Cosine similarity at or above which a candidate note is treated as a near-duplicate of an
    /// existing note (so auto-extraction skips it). Tuned for reorderings/paraphrases, not exact text.
    private static let noteDuplicateCosineThreshold: Float = 0.85

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

        // 1) Normalized-text equality OR substring containment: lowercase + collapse whitespace,
        // then reject if either string contains the other. Containment only counts when the SHORTER
        // (contained) side is ≥3 words, so a one-word note ("paris") can't swallow every richer fact
        // mentioning it — only genuine fragments ("trip to paris" ⊂ "trip to paris in september").
        let normalizedCandidate = Self.normalizedForDedup(trimmed)
        if let dup = notes.first(where: {
            let n = Self.normalizedForDedup($0.text)
            if n == normalizedCandidate { return true }
            let shorter = n.count <= normalizedCandidate.count ? n : normalizedCandidate
            let longer = n.count <= normalizedCandidate.count ? normalizedCandidate : n
            return Self.wordCount(shorter) >= 3 && longer.contains(shorter)
        }) {
            EmberLog.memory.notice("saveNoteIfNovel: REJECT (text contained/equal vs \"\(dup.text, privacy: .public)\") \"\(trimmed, privacy: .public)\"")
            return false
        }

        // 2) Cosine near-duplicate: only meaningful when both sides actually embed.
        if let candidateVector = embedder.embed(trimmed) {
            for note in notes where !note.vector.isEmpty {
                let sim = Vector.cosineSimilarity(candidateVector, note.vector)
                if sim >= Self.noteDuplicateCosineThreshold {
                    EmberLog.memory.notice("saveNoteIfNovel: REJECT (cosine \(sim, privacy: .public) ≥ \(Self.noteDuplicateCosineThreshold, privacy: .public) vs \"\(note.text, privacy: .public)\") new=\"\(trimmed, privacy: .public)\"")
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

    private static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).count
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
    ///
    /// `preferNotes`: when true, any qualifying curated `.note` (a durable fact) ranks ABOVE every
    /// conversation snippet regardless of score, so facts can't be buried under near-identical past
    /// questions (which embed almost identically to each other). Within each group, score still
    /// orders. Default false preserves pure-score ordering for the explicit search tool.
    public nonisolated static func search(_ snapshot: [MemoryRecord], queryVector: [Float],
                              topK: Int = 3, threshold: Float = 0.2,
                              excludingMessageIDs excluded: Set<UUID> = [],
                              preferNotes: Bool = false) -> [MemoryHit] {
        let scored = snapshot
            .filter { !excluded.contains($0.messageID) }
            .map { MemoryHit(record: $0, score: Vector.cosineSimilarity(queryVector, $0.vector)) }
            .filter { $0.score >= threshold }
        let ordered = scored.sorted { lhs, rhs in
            if preferNotes {
                let lNote = lhs.record.source == .note, rNote = rhs.record.source == .note
                if lNote != rNote { return lNote }   // notes ahead of conversation snippets
            }
            return lhs.score > rhs.score
        }
        return Array(ordered.prefix(max(0, topK)))
    }

    /// Hybrid retrieval: blends cosine similarity with a pure lexical-overlap signal so recall
    /// doesn't hinge on a single weak embedder. `hybrid = (1 - lexicalWeight) * cosine +
    /// lexicalWeight * lexical`. Records with no vector still match lexically. Plan 10 WS3
    /// (absorbs Plan 8). When `lexicalWeight == 0` this returns the cosine-only path verbatim.
    public nonisolated static func search(_ snapshot: [MemoryRecord], query: String,
                              queryVector: [Float], topK: Int = 3, threshold: Float = 0.2,
                              lexicalWeight: Float = 0.5,
                              excludingMessageIDs excluded: Set<UUID> = [],
                              preferNotes: Bool = false) -> [MemoryHit] {
        let w = min(max(lexicalWeight, 0), 1)
        // Construction-level guarantee: with no lexical weight, defer to the cosine-only path so
        // the score is bit-identical (no multiply), not merely approximately equal.
        guard w > 0 else {
            return search(snapshot, queryVector: queryVector, topK: topK, threshold: threshold,
                          excludingMessageIDs: excluded, preferNotes: preferNotes)
        }
        let scored = snapshot
            .filter { !excluded.contains($0.messageID) }
            .map { record -> MemoryHit in
                let cosine = Vector.cosineSimilarity(queryVector, record.vector)
                let lexical = LexicalScorer.score(query: query, text: record.text)
                let hybrid = (1 - w) * cosine + w * lexical
                return MemoryHit(record: record, score: hybrid)
            }
            .filter { $0.score >= threshold }
        let ordered = scored.sorted { lhs, rhs in
            if preferNotes {
                let lNote = lhs.record.source == .note, rNote = rhs.record.source == .note
                if lNote != rNote { return lNote }
            }
            return lhs.score > rhs.score
        }
        return Array(ordered.prefix(max(0, topK)))
    }

    static func archive(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }
    static func unarchive(_ d: Data) -> [Float] {
        let count = d.count / MemoryLayout<Float>.stride
        return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(count)) }
    }
}
