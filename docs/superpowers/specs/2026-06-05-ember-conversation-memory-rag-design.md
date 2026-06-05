# Ember — Plan 5: Conversation-Memory RAG (design)

- **Status:** Draft for review
- **Date:** 2026-06-05
- **Author:** Vlad Toma (with Claude)
- **Builds on:** Plans 1–4 (engine, UI, tool calling, hardening). Branches off `plan-4-hardening`; rebases onto `main` once Plans 3/4 merge.
- **Platforms:** iOS 26, iPadOS 26, macOS 26.
- **Tooling:** Tuist · MVVM + `@Observable` · SwiftData · FoundationModels · **NaturalLanguage** · Swift Testing.

---

## 1. Goal & scope

Give Ember **long-term memory**: the on-device model can recall relevant snippets from the user's past conversations (and earlier in the current one) by calling a `searchMemory` tool backed by on-device semantic search. This is the RAG half of roadmap Phase 3 (spec §14), realised in Ember's privacy-first, transparency-first way — **no network, no external dependency** (NaturalLanguage is a system framework), and every recall is visible in the Context inspector as a tool call.

### In scope
- An on-device **embedding seam** (`TextEmbedder`) over `NLEmbedding` sentence vectors, with a deterministic mock for tests.
- A **`MemoryStore`** that embeds messages on save (+ one-time backfill) and serves **brute-force cosine top-k** retrieval across **all** conversations and the current one, above a similarity threshold, **deduped against messages already in the context window**.
- A **`MemorySearchTool`** (`Tool`, reusing Plan 3) the model calls to recall; registered as the 4th tool.
- Recall surfaced via the **existing** Plan 3 inspector tool-call/output rows + the tool-definition token line. One additive schema field (`Message.embedding`).

### Out of scope (deferred)
- **Advanced budgeting** (the other §14 item: LLM-summarization compaction, sliding-window trimming, reserve-for-reply) → a future **Plan 6**. Independent of memory.
- Document import / external corpora / attachments. Cross-device sync. Re-ranking models.
- No network capability or entitlement added.

### Constraints carried forward
- 4,096-token window; everything on-device and mock-testable behind protocols.
- Apple's **3–5 tools** guidance: adding `searchMemory` to the existing 3 keeps us at 4.
- The branch must build (framework tests + macOS + iOS) at every milestone.

---

## 2. NaturalLanguage grounding (for embeddings)
> Verified via Apple docs (sosumi). Re-verify symbols during implementation.
- `NLContextualEmbedding`'s own doc says: **"For semantic similarity tasks, consider using `NLEmbedding`."** So we use `NLEmbedding`, not the contextual/BERT model (which needs `requestAssets`/`load` and targets classification).
- `NLEmbedding.sentenceEmbedding(for: NLLanguage)` → `NLEmbedding?` (a built-in, on-device model for supported languages; **no asset download**). `embedding.vector(for: String)` → `[Double]?` (fixed `dimension`). Returns `nil` for unsupported language / empty input — handle gracefully (message simply isn't indexed/retrievable).
- Default language `.english`; multilingual support is a documented future enhancement (could use `NLLanguageRecognizer` per message). Apple's "Finding similarities between pieces of text" guide is the reference pattern.

---

## 3. Architecture

```
FoundationChatKit/Sources/
  Memory/TextEmbedder.swift     # protocol + NLTextEmbedder (real) + Vector math (cosine)
  Memory/MemoryRecord.swift     # Sendable snapshot row + MemoryHit
  Memory/MemoryStore.swift      # @MainActor: index(on append) + backfill + search (brute-force cosine)
  Tools/MemorySearchTool.swift  # Tool: @Generable {query} -> ranked snippets over a Sendable snapshot
  Persistence/Message.swift     # MODIFY: + embedding: Data? (archived [Float])
  App/ChatCoordinator.swift     # MODIFY: index on send; build snapshot + register MemorySearchTool per open; backfill
FoundationChatKit/Tests/        # cosine, MockEmbedder, MemoryStore index/backfill/search, MemorySearchTool, coordinator
```

### `TextEmbedder` (seam)
```swift
public protocol TextEmbedder: Sendable {
    /// A unit-length-agnostic dense vector for `text`, or nil if it can't be embedded.
    func embed(_ text: String) -> [Float]?
}
```
- **Real** `NLTextEmbedder`: lazily holds `NLEmbedding.sentenceEmbedding(for: .english)`; `embed` → `vector(for:)` mapped to `[Float]`; `nil` if no model/empty. `NLEmbedding` query is read-only; the embedder is `Sendable` (immutable after init).
- **Mock** `MockEmbedder` (tests): deterministic bag-of-words vector over a fixed small vocabulary (lowercased tokens → counts), so semantically-overlapping strings score higher. No NaturalLanguage dependency.

`Vector.cosineSimilarity(_:_:) -> Float` is a pure free function (returns 0 for zero/empty/mismatched-length vectors).

### `MemoryRecord` / `MemoryHit`
```swift
public struct MemoryRecord: Sendable, Equatable {   // immutable snapshot row
    public let messageID: UUID
    public let conversationID: UUID
    public let conversationTitle: String
    public let role: MessageRole
    public let text: String
    public let vector: [Float]
}
public struct MemoryHit: Sendable, Equatable {       // a search result
    public let record: MemoryRecord
    public let score: Float
}
```

### `MemoryStore` (`@MainActor`)
- `func index(_ message: Message)` — if `message.embedding == nil` and the text is non-empty, compute `embedder.embed(text)`, archive to `Data`, store on `message.embedding`, save. (`systemNotice` messages are skipped.)
- `func backfill()` — embed every persisted user/assistant message lacking an `embedding` (one-time; cheap; bounded by message count).
- `func snapshot() -> [MemoryRecord]` — all messages with an embedding, decoded to `[Float]`, paired with their conversation id/title. (Built on the `@MainActor`; the resulting array is `Sendable` and handed to the tool.)
- `static func search(_ snapshot:, queryVector:, topK: Int = 3, threshold: Float = 0.2, excludingMessageIDs: Set<UUID>) -> [MemoryHit]` — pure: cosine vs every record, drop in-window/excluded ids, drop below `threshold`, sort desc, take `topK`. (Static + pure so it's testable without a store.)

### `MemorySearchTool` (`Tool`, pure & Sendable)
```swift
public struct MemorySearchTool: Tool {
    public let name = "searchMemory"
    public let description = "Search the user's past conversations for relevant context."
    @Generable public struct Arguments {
        @Guide(description: "What to recall, as a short query")
        public var query: String
    }
    // injected at construction (all Sendable): the embedder + an immutable snapshot + the in-window ids to exclude
    public func call(arguments: Arguments) async throws -> String { … }
}
```
- `call`: `embed(query)` → `MemoryStore.search(snapshot, queryVector:, excludingMessageIDs: inWindowIDs)` → format hits as `"From '<title>' — <role>: <text>"` joined by newlines, or `"No relevant earlier context found."` when empty. Pure (no actor hop), so it's unit-testable with `MockEmbedder` + a fixed snapshot. Consistent with Plan 3's pure-tool philosophy.

### `ChatCoordinator` wiring
- Holds a `MemoryStore` (real embedder). On `init`, run `backfill()` once.
- In `send`, after the turn persists messages, `index` the new user + assistant messages.
- In `makeEngine(for:)`, build the tool set = `Toolbox.defaultTools()` **+** a `MemorySearchTool` constructed with the embedder, the current `store.snapshot()`, and the set of message ids currently in `convo`'s window (so the tool never "recalls" what's already visible). Snapshot is fixed per conversation-open (documented staleness; reopening refreshes it).

---

## 4. Data model & persistence
Only addition: `Message.embedding: Data?` (archived `[Float]`; `nil` until indexed). Lightweight, additive migration. No relationship/shape change; resume/transcript logic untouched. Embeddings are derived data — safe to drop/rebuild via `backfill()`.

## 5. Retrieval algorithm
1. Embed the query (`TextEmbedder`).
2. Cosine vs every snapshot record.
3. Exclude records whose `messageID` is already in the current window (no echo).
4. Drop scores `< threshold` (default 0.2) to avoid irrelevant pulls from unrelated chats.
5. Sort desc, take `topK` (default 3). Format with source conversation title + role.
Token cost: the returned snippets enter the transcript as the tool's output (counted via the existing entries path); the tool definition adds a `Tool: searchMemory` budget line.

## 6. Surfacing (free from Plan 3)
- `searchMemory({"query":…})` renders as a `TOOL CALL` row; the snippets as a `TOOL OUTPUT` row (existing `TranscriptMapping` + `ContextInspectorView` + icons).
- Tokens tab shows `Tool: searchMemory`. No new inspector UI.

## 7. Testing (TDD)
- `VectorTests` — cosine: identical→1, orthogonal→0, zero/empty/length-mismatch→0.
- `MockEmbedderTests` — overlapping text scores higher than unrelated.
- `MemoryStoreTests` — `index` sets `embedding`; `backfill` embeds all prior messages; `snapshot` returns one record per embedded message with correct title/role; `search` honors topK, threshold, and exclusion (in-memory `ModelContainer`).
- `MemorySearchToolTests` — with `MockEmbedder` + a fixed snapshot: returns ranked snippets for a matching query; "No relevant earlier context found." when all below threshold; respects exclusion.
- `ChatCoordinatorTests` (extend) — `makeEngine` registers 4 tools incl. `searchMemory`; sending indexes the new messages.
- App views unchanged → build-verified (macOS + iOS). Final milestone: run on the sim and confirm the model calls `searchMemory` and the inspector shows the recall.

## 8. Milestones (each ends green + committed)
- **N** — `TextEmbedder` (protocol + `NLTextEmbedder`) + `Vector.cosineSimilarity` + `MockEmbedder` (TDD).
- **O** — `Message.embedding` + `MemoryStore` (index, backfill, snapshot, search) + `MemoryRecord`/`MemoryHit` (TDD).
- **P** — `MemorySearchTool` (TDD).
- **Q** — `ChatCoordinator` wiring (backfill, index-on-send, snapshot + register the tool) (TDD) + build both apps.
- **R** — run/verify on the iOS sim (model calls `searchMemory`, recall shows in inspector) + tag `plan-5-rag-complete` + PR.

## 9. Self-review
- **Placeholders:** none.
- **Consistency:** `TextEmbedder.embed -> [Float]?` used by `NLTextEmbedder`, `MockEmbedder`, `MemoryStore.index`, and `MemorySearchTool`. `MemoryRecord`/`MemoryHit` defined once, consumed by `MemoryStore.search` + the tool. `MemoryStore.search` is static/pure so the tool needs no `@MainActor` hop. `MemorySearchTool` follows the Plan 3 `Tool` shape exactly (so Plan 3's seam/inspector/budget accounting all apply unchanged).
- **Scope:** memory RAG only; advanced budgeting explicitly deferred to Plan 6; one additive schema field.
- **Ambiguity:** snapshot staleness (fixed per conversation-open) stated explicitly; default `topK`=3 and `threshold`=0.2 are explicit and tunable; `.english` default with multilingual as a noted enhancement.
- **Honesty:** `NLEmbedding` may return `nil` (unsupported language) → that message is simply not retrievable; the feature degrades, never crashes.

## 10. References
- NLEmbedding: https://developer.apple.com/documentation/naturallanguage/nlembedding (`sentenceEmbedding(for:)`, `vector(for:)`)
- Finding similarities between pieces of text: https://developer.apple.com/documentation/naturallanguage/finding-similarities-between-pieces-of-text
- NLContextualEmbedding (why we don't use it for similarity): https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding
- TN3193 — context window: https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window
- Plan 3 tool calling spec: `docs/superpowers/specs/2026-06-05-ember-phase-2-tool-calling-design.md`
