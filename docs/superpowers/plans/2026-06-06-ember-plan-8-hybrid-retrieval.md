# Ember — Plan 8 (proposal): Hybrid lexical + semantic memory retrieval

> **Status:** PROPOSAL / not yet implemented. Implement via superpowers subagent-driven TDD (fresh implementer per task, red→green→commit, reviewer gate). One branch (`plan-8-hybrid-retrieval`) + merge to `main`.
> **Relationship:** Follows Plan 7 (`docs/superpowers/plans/2026-06-06-ember-plan-7-auto-rag.md`). Independent of Plan 9 (auto-fact-extraction); **combining 8 + 9 is the strongest outcome**. Either order works; if you only do one, Plan 9 is higher-leverage for cross-conversation recall.

## Why (the problem this solves)

On-device validation of Plan 7 surfaced the core limitation: **`NLEmbedding` retrieves on lexical/surface overlap, not deep semantics.** It nails "What's my favorite color?" ↔ "my favorite color is teal" (shared phrase → high cosine), but misses "What should I pack?" ↔ "I'm planning a trip to Lisbon" because they share no keywords — the cosine falls below even the loose 0.2 tool threshold, so nothing is retrieved. (Conversation messages *are* embedded and *are* candidates — verified — so this is the embedder's quality ceiling, not a bug.)

Today retrieval is **embedding-only**: `MemoryStore.search(_:queryVector:topK:threshold:excludingMessageIDs:)` scores by cosine alone. This plan adds a **lexical signal** (token/lemma overlap) blended with the semantic signal, so recall no longer depends on a single weak embedder.

**Honest scope:** a lexical signal raises recall for queries that share *words* (lemmas) with stored text even when sentence-cosine under-scores them, and makes retrieval robust when embedding is unavailable (returns nil). It does **NOT** solve pure-semantic gaps with zero shared words (e.g. "pack" ↔ "Lisbon"); for that see the optional **query-expansion** task below, Plan 9 (cleaner stored facts), or a better on-device embedding model (out of scope — the project deliberately uses `NLEmbedding`, no asset download, fully on-device/private).

## Current code (ground truth — read these first)

- `Targets/FoundationChatKit/Sources/Memory/MemoryRecord.swift` — `MemoryRecord { messageID, conversationID, conversationTitle, role: MessageRole, text: String, vector: [Float], source: Source }` where `Source { conversation, note }`; `MemoryHit { record: MemoryRecord, score: Float }`. Both `Sendable, Equatable`.
- `Targets/FoundationChatKit/Sources/Memory/MemoryStore.swift` — `@MainActor final class`. Key API:
  - `func snapshot() -> [MemoryRecord]` (cached; includes embedded `Message` rows as `.conversation` and `MemoryNote` rows as `.note`; unembedded notes get an empty `vector`).
  - `nonisolated static func search(_ snapshot:[MemoryRecord], queryVector:[Float], topK:Int = 3, threshold:Float = 0.2, excludingMessageIDs:Set<UUID> = []) -> [MemoryHit]` — pure cosine top-k. `nonisolated` so it runs off-actor.
- `Targets/FoundationChatKit/Sources/Memory/Vector.swift` — `Vector.cosineSimilarity(_:[Float], _:[Float]) -> Float` (mismatched length → 0; range roughly [-1, 1]).
- `Targets/FoundationChatKit/Sources/Memory/TextEmbedder.swift` — `protocol TextEmbedder: Sendable { func embed(_:String) -> [Float]? }`; `NLTextEmbedder` (caches `NLEmbedding`).
- `Targets/FoundationChatKit/Sources/Tools/MemorySearchTool.swift` — `searchMemory` tool; its `call` does `MemoryStore.search(snapshot, queryVector: embedder.embed(query)…)`.
- `Targets/FoundationChatKit/Sources/App/ChatCoordinator.swift` — `makeEngine` builds, inside `if let memory`, a single `let snapshot = memory.snapshot()` reused by BOTH `MemorySearchTool(embedder:snapshot:excludedIDs:)` AND the auto-RAG retriever closure:
  ```swift
  retrieval = ConversationEngine.MemoryRetrieval { query in
      guard let qv = embedder.embed(query) else { return [] }
      return MemoryStore.search(snapshot, queryVector: qv, topK: topK,
                                threshold: threshold, excludingMessageIDs: excluded)
  }
  ```
  `topK`/`threshold` come from `settings.memoryRetrievalTopK` (1) / `settings.memoryRetrievalThreshold` (0.5).
- `Targets/FoundationChatKit/Sources/Engine/ConversationEngine.swift` — `MemoryRetrieval { retrieve: @Sendable (String) -> [MemoryHit] }`; `performTurn` calls `memoryRetrieval?.retrieve(prompt)` then `MemoryContextBlock.augment(prompt:with:)`.
- `Targets/FoundationChatKit/Sources/Model/GenerationSettings.swift` — `Sendable, Equatable` struct; already has `memoryRetrievalTopK`/`memoryRetrievalThreshold`.
- Tests live in `Targets/FoundationChatKit/Tests/` (Swift Testing, `@testable import FoundationChatKit`). Doubles: `MockEmbedder` (fixed vocab `swift,trip,paris,budget,weather,dog,music,code`), `MockModelProvider`. `MemoryStoreTests` has a `makeStore()` factory (in-memory `ModelContainer(for: Conversation.self, Message.self, MemoryNote.self)`).

## Design

Add a **lexical relevance scorer** and a **hybrid ranker** that unions the two signals. Keep everything **pure, `Sendable`, `nonisolated`** so it's testable off-device and usable from the existing `@Sendable` retriever closure.

1. **Lexical scoring** (`LexicalScorer`, new file): normalize text → lowercase, tokenize into word units, drop stopwords, lemmatize. On-device use `NLTokenizer(unit: .word)` and optionally `NLTagger(tagSchemes: [.lemma])`. **Gotcha:** `NLTokenizer`/`NLTagger` are reference types and NOT `Sendable` — instantiate them locally inside the scoring function (no shared/stored instance). Score query↔text by a token-overlap metric: start simple with **weighted Jaccard / shared-lemma count normalized by query length**; optionally upgrade to **BM25** with IDF computed over the snapshot corpus (the snapshot is the corpus). Score range normalized to [0, 1].
2. **Hybrid search** (`MemoryStore.hybridSearch`, new `nonisolated static`): for each non-excluded record, compute `semantic = cosine(queryVector, record.vector)` (if a query vector + record vector exist) and `lexical = LexicalScorer.score(query, record.text)`. **Union with per-signal thresholds**: include a record if `semantic >= semanticThreshold` OR `lexical >= lexicalThreshold`; rank by a combined score (e.g. `max(semantic, lexical)` or a weighted blend `wSem*semantic + wLex*lexical`); return top-K `MemoryHit` (set `.score` to the combined score). Records with no vector (unembedded notes) can still match lexically. Signature suggestion:
   ```swift
   nonisolated static func hybridSearch(_ snapshot: [MemoryRecord], query: String, queryVector: [Float]?,
       topK: Int, semanticThreshold: Float, lexicalThreshold: Float,
       excludingMessageIDs: Set<UUID> = []) -> [MemoryHit]
   ```
3. **Wire it in:** `ChatCoordinator.makeEngine` retriever closure calls `hybridSearch(snapshot, query: query, queryVector: embedder.embed(query), …)` (note: pass the raw `query` string AND the optional vector — lexical needs the text). Do the same in `MemorySearchTool` (it already has the query string + embedder + snapshot). Add `GenerationSettings.memoryLexicalThreshold: Float` (default ~0.34) and (optional) blend weights; reuse `memoryRetrievalThreshold` as the semantic threshold. Keep the closure `@Sendable` (LexicalScorer is pure; instantiate `NLTokenizer` locally).

### Optional stretch task — LLM query expansion (the only thing that bridges zero-overlap gaps)
Before retrieval, call the model to expand the query into related terms ("what should I pack" → "trip, travel, luggage, clothes, vacation, packing"), then run hybrid search on the expansion ∪ original. This bridges vocabulary gaps but costs a model call per turn — gate behind a `GenerationSettings.expandRetrievalQuery: Bool` (default false). Add a `ChatModelProvider` seam (`func expandQuery(_:) async -> [String]?`) mirroring the `summarize`/`generateTitle` throwaway-session pattern; mock it in tests. Document the latency cost.

## Tasks (TDD: write the failing test, watch it fail, implement, commit)

- **Task 1 — `LexicalScorer`** (`Sources/Memory/LexicalScorer.swift`, pure `nonisolated`): tokenize/lowercase/stopword/lemma + a normalized overlap score. Tests (`LexicalScorerTests.swift`): exact-word-overlap scores high; no-overlap scores ~0; stopwords ignored ("the a of" vs anything ≈ 0); case/lemma-insensitive ("running" ≈ "run" if you lemmatize); deterministic. Tolerate `NLTagger` lemma being unavailable on the host (fall back to lowercase tokens).
- **Task 2 — `MemoryStore.hybridSearch`** + tests (`MemoryStoreTests`): a record with a strong lexical match but weak/zero cosine is now returned (the Lisbon-style miss the embedding-only path drops); a strong semantic match with no lexical overlap still returned; an unembedded note matches lexically; ranking orders by combined score; exclusion set respected; topK respected. Build `[MemoryRecord]` by hand (use `MockEmbedder` vectors where you want cosine to fire, real text for lexical).
- **Task 3 — Wire retriever + tool + settings**: add `GenerationSettings.memoryLexicalThreshold` (defaulted; update the memberwise init last-param + any defaults test in `SupportingTypesTests`); switch `ChatCoordinator.makeEngine`'s retriever closure and `MemorySearchTool.call` to `hybridSearch`; keep the closure `@Sendable`. Tests: extend `ChatCoordinatorTests`/`ConversationEngineTests` so a query that shares words with a past message (but would miss on cosine alone) now produces a `.retrievedMemory` injection.
- **Task 4 (optional) — query expansion**: `ChatModelProvider.expandQuery` seam + mock + real impl + `expandRetrievalQuery` setting + gated wiring. Tests with the mock.

## Tests / verification (house rules — CLAUDE.md)
- After adding files: `tuist generate --no-open` BEFORE xcodebuild. SourceKit "No such module 'Testing'"/"cannot find type" squiggles are unreliable (no editor module graph) — trust xcodebuild. Sandbox/permission Bash error → retry with `dangerouslyDisableSandbox: true`.
- `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -20` → `** TEST SUCCEEDED **`.
- `xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=macOS' build` and `-destination 'platform=iOS Simulator,name=iPhone 17 Pro' build` → `** BUILD SUCCEEDED **`.
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Invoke the `foundation-models-best-practices` skill; ground any `NLTokenizer`/`NLTagger`/`NLEmbedding` API claims in Apple docs (sosumi `fetchAppleDocumentation`).
- **On-device E2E** (erase the sim first for a clean memory store — `xcrun simctl erase "iPhone 17 Pro"`): state a fact in one chat, then in a NEW chat ask with overlapping vocabulary; confirm a teal MEMORY block now appears (it didn't pre-hybrid) and a matching Tokens "Memory" line.

## Gotchas
- `NLTokenizer`/`NLTagger` are NOT `Sendable` — create locally per call; never store on a `Sendable` type or capture in a `@Sendable` closure.
- Keep the lexical scorer pure & deterministic (no `Date`/random) so tests are stable.
- Don't regress precision: the union-with-thresholds means a *low* `lexicalThreshold` will re-admit noise (the exact problem Plan 7.1 fixed). Tune `memoryLexicalThreshold` conservatively and keep the Plan 7.1 "use only if directly relevant; otherwise ignore" framing (in `MemoryContextBlock.header`) as the safety net.
- `MemorySearchTool` keeps its looser tool-facing thresholds; the auto-RAG path uses the (stricter) `GenerationSettings` ones. Keep them separate.

## Out of scope
ANN indexing (brute-force is fine at this scale), bundling a new embedding model, network/cloud retrieval, multilingual.
