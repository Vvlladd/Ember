import Testing
import Foundation
import SwiftData
@testable import FoundationChatKit

@MainActor
struct MemoryStoreTests {
    @Test func messageStoresEmbedding() {
        let m = Message(role: .user, text: "hi", createdAt: Date(timeIntervalSince1970: 0),
                        embedding: Data([1, 2, 3]))
        #expect(m.embedding == Data([1, 2, 3]))
    }
    @Test func memoryRecordInit() {
        let r = MemoryRecord(messageID: UUID(), conversationID: UUID(), conversationTitle: "T",
                             role: .user, text: "x", vector: [1, 2])
        #expect(r.vector == [1, 2])
        #expect(MemoryHit(record: r, score: 0.5).score == 0.5)
    }

    private func makeStore() throws -> (MemoryStore, ConversationStore) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Conversation.self, Message.self, MemoryNote.self,
                                           configurations: config)
        let context = ModelContext(container)
        return (MemoryStore(context: context, embedder: MockEmbedder()),
                ConversationStore(context: context))
    }

    @Test func indexSetsEmbedding() throws {
        let (mem, store) = try makeStore()
        let c = store.createConversation(now: Date(timeIntervalSince1970: 0))
        store.appendMessage(role: .user, text: "trip to paris", to: c, now: Date(timeIntervalSince1970: 0))
        let m = c.orderedMessages.first!
        #expect(m.embedding == nil)
        mem.index(m)
        #expect(m.embedding != nil)
    }
    @Test func backfillEmbedsAllAndSnapshots() throws {
        let (mem, store) = try makeStore()
        let c = store.createConversation(now: Date(timeIntervalSince1970: 0))
        store.appendMessage(role: .user, text: "trip to paris", to: c, now: Date(timeIntervalSince1970: 0))
        store.appendMessage(role: .assistant, text: "paris is great", to: c, now: Date(timeIntervalSince1970: 1))
        mem.backfill()
        #expect(c.orderedMessages.allSatisfy { $0.embedding != nil })
        #expect(mem.snapshot().count == 2)
    }
    @Test func searchRanksAndExcludes() throws {
        let (mem, store) = try makeStore()
        let c = store.createConversation(now: Date(timeIntervalSince1970: 0))
        store.appendMessage(role: .user, text: "trip to paris", to: c, now: Date(timeIntervalSince1970: 0))
        store.appendMessage(role: .user, text: "debugging swift code", to: c, now: Date(timeIntervalSince1970: 1))
        mem.backfill()
        let snap = mem.snapshot()
        let q = MockEmbedder().embed("paris trip")!
        let hits = MemoryStore.search(snap, queryVector: q, topK: 3, threshold: 0.1)
        #expect(hits.first?.record.text == "trip to paris")
        let excluded = Set(snap.filter { $0.text == "trip to paris" }.map(\.messageID))
        let hits2 = MemoryStore.search(snap, queryVector: q, topK: 3, threshold: 0.1, excludingMessageIDs: excluded)
        #expect(!hits2.contains { $0.record.text == "trip to paris" })
    }

    @Test func snapshotIsCachedUntilInvalidatingWrite() throws {
        let (mem, store) = try makeStore()
        let c = store.createConversation(now: Date(timeIntervalSince1970: 0))
        store.appendMessage(role: .user, text: "trip to paris", to: c, now: Date(timeIntervalSince1970: 0))
        mem.backfill()

        // First call builds the cache.
        let first = mem.snapshot()
        #expect(mem.snapshotBuildCount == 1)
        #expect(first.count == 1)

        // Repeated calls reuse the cache (no rebuild) and return identical results.
        let second = mem.snapshot()
        #expect(mem.snapshotBuildCount == 1)
        #expect(second == first)

        // Adding a message without indexing it does NOT invalidate the cache:
        // snapshot() stays stale (still 1 record) and does not rebuild.
        store.appendMessage(role: .assistant, text: "paris is great", to: c, now: Date(timeIntervalSince1970: 1))
        let stillStale = mem.snapshot()
        #expect(mem.snapshotBuildCount == 1)
        #expect(stillStale.count == 1)

        // An invalidating write (indexing the new message) rebuilds on next snapshot()
        // and reflects the change.
        mem.index(c.orderedMessages.first { $0.role == .assistant }!)
        let fresh = mem.snapshot()
        #expect(mem.snapshotBuildCount == 2)
        #expect(fresh.count == 2)
    }

    @Test func saveNoteAppearsInSnapshotAsNote() throws {
        let (mem, _) = try makeStore()
        mem.saveNote("planning a trip to paris")
        let snap = mem.snapshot()
        #expect(snap.contains { $0.source == .note && $0.text == "planning a trip to paris" })
    }

    @Test func saveNoteIgnoresEmptyAndTrims() throws {
        let (mem, _) = try makeStore()
        mem.saveNote("   ")
        #expect(mem.snapshot().isEmpty)
        mem.saveNote("  trip to paris  ")
        #expect(mem.snapshot().contains { $0.text == "trip to paris" && $0.source == .note })
    }

    /// "Saved." must be honest: a fact whose words the embedder does NOT know (so `embed` returns
    /// nil) is STILL persisted and visible in `snapshot()` as a `.note`, rather than silently dropped.
    @Test func saveNotePersistsEvenWhenEmbeddingUnavailable() throws {
        let (mem, _) = try makeStore()
        #expect(MockEmbedder().embed("zzz qqq") == nil)   // precondition: unembeddable text
        mem.saveNote("zzz qqq")
        #expect(mem.snapshot().contains { $0.source == .note && $0.text == "zzz qqq" })
    }

    // MARK: - saveNoteIfNovel (de-dupe)

    /// Saving the SAME fact twice yields exactly ONE `.note`; the 2nd call returns false.
    @Test func saveNoteIfNovelSkipsExactDuplicate() throws {
        let (mem, _) = try makeStore()
        #expect(mem.saveNoteIfNovel("planning a trip to paris") == true)
        #expect(mem.saveNoteIfNovel("planning a trip to paris") == false)
        let notes = mem.snapshot().filter { $0.source == .note }
        #expect(notes.count == 1)
        #expect(notes.first?.text == "planning a trip to paris")
    }

    /// A clearly DIFFERENT fact IS saved (returns true; two notes present).
    @Test func saveNoteIfNovelSavesDifferentFact() throws {
        let (mem, _) = try makeStore()
        #expect(mem.saveNoteIfNovel("trip to paris") == true)
        #expect(mem.saveNoteIfNovel("debugging swift code") == true)
        #expect(mem.snapshot().filter { $0.source == .note }.count == 2)
    }

    /// Near-duplicate path (a): normalized-equal but different case/spacing is skipped.
    @Test func saveNoteIfNovelSkipsNormalizedEqual() throws {
        let (mem, _) = try makeStore()
        #expect(mem.saveNoteIfNovel("Trip To Paris") == true)
        #expect(mem.saveNoteIfNovel("trip   to  paris") == false)
        #expect(mem.snapshot().filter { $0.source == .note }.count == 1)
    }

    /// Near-duplicate path (b): high-cosine but different word order is skipped.
    /// MockEmbedder maps "trip to paris" and "paris trip" to identical vectors (cosine 1.0).
    @Test func saveNoteIfNovelSkipsHighCosineDuplicate() throws {
        let (mem, _) = try makeStore()
        #expect(mem.saveNoteIfNovel("trip to paris") == true)
        #expect(mem.saveNoteIfNovel("paris trip") == false)
        #expect(mem.snapshot().filter { $0.source == .note }.count == 1)
    }

    /// An empty/whitespace candidate returns false and saves nothing.
    @Test func saveNoteIfNovelIgnoresEmpty() throws {
        let (mem, _) = try makeStore()
        #expect(mem.saveNoteIfNovel("   ") == false)
        #expect(mem.snapshot().isEmpty)
    }

    /// `preferNotes` ranks any qualifying curated note ABOVE conversation snippets, even when a
    /// snippet scores higher — so durable facts can't be buried by near-identical past questions
    /// (the on-device recall bug). Without the flag, pure score ordering is unchanged.
    @Test func searchPreferNotesRanksNotesFirst() throws {
        let (mem, store) = try makeStore()
        let c = store.createConversation(now: Date(timeIntervalSince1970: 0))
        // Conversation snippet shares MORE query words → higher cosine than the note.
        store.appendMessage(role: .user, text: "trip to paris budget", to: c, now: Date(timeIntervalSince1970: 0))
        mem.backfill()
        mem.saveNote("paris")                       // note shares only "paris"
        let snap = mem.snapshot()
        let q = MockEmbedder().embed("paris trip")!

        // Pure score: the snippet (shares paris+trip) outranks the note (shares paris).
        let byScore = MemoryStore.search(snap, queryVector: q, topK: 3, threshold: 0.01)
        #expect(byScore.first?.record.source == .conversation)

        // preferNotes: the note is surfaced first despite its lower score.
        let preferred = MemoryStore.search(snap, queryVector: q, topK: 3, threshold: 0.01, preferNotes: true)
        #expect(preferred.first?.record.source == .note)
        #expect(preferred.first?.record.text == "paris")
    }

    /// De-dupe path (c): a candidate that is a normalized substring of an existing note (or vice
    /// versa) is skipped — stops fragment notes like "trip to paris" piling up next to
    /// "trip to paris in september".
    @Test func saveNoteIfNovelSkipsContainedFragment() throws {
        let (mem, _) = try makeStore()
        #expect(mem.saveNoteIfNovel("trip to paris in september") == true)
        #expect(mem.saveNoteIfNovel("trip to paris") == false)              // contained → dup
        #expect(mem.snapshot().filter { $0.source == .note }.count == 1)
    }

    @Test func indexEarlyReturnDoesNotInvalidateCache() throws {
        let (mem, store) = try makeStore()
        let c = store.createConversation(now: Date(timeIntervalSince1970: 0))
        store.appendMessage(role: .user, text: "trip to paris", to: c, now: Date(timeIntervalSince1970: 0))
        let indexed = c.orderedMessages.first!
        mem.index(indexed)
        _ = mem.snapshot()
        #expect(mem.snapshotBuildCount == 1)

        // Re-indexing an already-embedded message writes nothing -> cache stays valid.
        mem.index(indexed)
        _ = mem.snapshot()
        #expect(mem.snapshotBuildCount == 1)
    }
}
