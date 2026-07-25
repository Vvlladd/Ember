# Plan 11 research — better local memory, local RAG, context-window management, and a model-agnostic seam (future Gemma backend)

**Date:** 2026-07-25 · **Status:** research synthesis (pre-brainstorm/spec) · produced by a 6-agent research workflow (codebase grounding, GitHub/OSS memory systems, context-window literature, Apple docs via sosumi, Gemma/on-device runtime survey, completeness critic).

Baseline: `main` @ `fa93dbb` (Plans 1–10 merged, 224 tests).

---

## Where we are (codebase grounding)

The memory/RAG layer is already **~80% model-agnostic**: MemoryStore, LexicalScorer, MemoryContextBlock, ContextCompactor, all of Tokens/, ChatCoordinator have **zero** FoundationModels imports. FoundationModels leaks outside `Provider/` in exactly six places:

1. `ChatModelProvider` itself: `makeSession(tools: [any Tool])` bakes `FoundationModels.Tool` into the seam (`ChatModelProvider.swift:2,39,42`).
2. `ConversationEngine` imports FM solely for `tools: [any Tool]` (`ConversationEngine.swift:2,53,77`).
3. `ConversationSummary` is `@Generable`/`@Guide` in `Context/` (`ConversationSummary.swift:2-15`).
4. All `Tools/*` conform to `FoundationModels.Tool` with `@Generable` args; `Toolbox.accountingMetadata` reads `GenerationSchema` via `String(describing:)` (`Toolbox.swift:17-28`).
5. `MemoryExtractor` / `ConversationTitler` construct `LanguageModelSession` directly in `Tools/` (bypass the seam structurally).
6. `UtilityGenerationOptions` wraps `GenerationOptions`.

Four tokenizer assumptions break on any non-Apple model: the 3.5 chars/token estimator; sum-of-independent-lines (no chat-template overhead — Gemma adds `<start_of_turn>` wrappers per message); tool cost = estimator over a `String(describing: GenerationSchema)` debug digest; and `TokenBudgetCalculator.breakdown` bucketing by **English label string** matching.

Known carried-forward limitations confirmed: memory blocks persist in-transcript between compactions; NLEmbedding hardcoded `.english`, silently degrades to lexical-only; no `embedderID` tag on stored vectors (embedder swap ⇒ full re-backfill, undesigned); snapshot is point-in-time per engine build; sync `tokenCount` permanently nil so the live gauge is always an estimate; `try? context.save()` swallows persistence errors.

---

## Track A — Model-agnostic seam (do first; everything else builds on it)

1. **Neutral tool descriptor** in the seam: Ember-owned `ToolDescriptor` (name/description/schema/callback); `FoundationModelProvider` adapts to `FoundationModels.Tool` internally. Removes FM from `ChatModelProvider` + `ConversationEngine`.
2. **Move utility generation behind the provider**: `MemoryExtractor`, `ConversationTitler`, `UtilityGenerationOptions`, and the `@Generable` mirror of a now-plain `ConversationSummary` struct all live in `Provider/` (TranscriptMapping is the precedent). The seam already abstracts at the right level — capability methods (`generateTitle`, `summarizeStructured`, `extractMemories`), all Optional-returning so `nil = unavailable` is built-in degradation.
3. **`ProviderCapabilities`**: `supportsGuidedGeneration`, `supportsToolCalling`, `supportsSystemRole`, `maxTools`, and `effectiveContextTokens` **distinct from** `maxContextTokens` (Gemma 3 4B advertises 128K but phone KV-RAM caps effective use at ~8K). Engine drops tools / gates compaction off capabilities.
4. **Provider-vended `TokenCounter`** (`count(_:) -> Int?` sync, `countExact(_:) async`): key inversion — Gemma runtimes tokenize **synchronously** (SentencePiece via swift-transformers / `llama_tokenize`) while Apple is async-only. Routes all counting through the provider; replaces schemaDigest with the provider's real serialized tool spec; replace label-string breakdown bucketing with an enum kind tag on `BudgetLine`.
5. **Embedder versioning**: `embedderID` + `dimension` stored with every vector; `TextEmbedder.embed(_, role: .query/.document)` (EmbeddingGemma requires task prefixes); chunked background re-backfill design + mixed-version query rule (critic: currently undesigned — without it a swap corrupts retrieval).
6. **Shared conformance test suite** both `FoundationModelProvider` and a future `GemmaModelProvider` must pass (token-count semantics, overflow error mapping, no-system-role template, tool-descriptor round-trip). MockModelProvider today only tests FM-shaped behavior — without this the "agnostic" claim is untestable.

**Platform note (big):** iOS 27 beta ships the `LanguageModel` **protocol** — Apple built exactly this seam — with open-source conformers: `MLXLanguageModel` (ml-explore/mlx-swift-lm, Gemma-3 1B QAT registry entry, local-weight loading), `CoreAILanguageModel`, `ChatCompletionsLanguageModel` (apple/foundation-models-utilities). WWDC26-339 covers custom providers + KV-cache. **Recommendation:** keep Ember's own capability-level `ChatModelProvider` seam (it's higher-level and better fitted than session-level abstraction), but shape it to be implementable atop `LanguageModel` on 27+. Prior art: **mattt/AnyLanguageModel** v0.8 (FM-API-compatible over 9 backends, `@Generable` re-implemented outside the OS, trait-gated deps) — borrow the **package-trait gating** so the Gemma runtime never bloats the default build.

**Gemma runtime pick (2026 iPhone 17 Pro benchmarks, Gemma 4 E2B):** LiteRT-LM 55.4 tok/s @ **641 MB** peak (official Swift API, built-in constrained decoding + function calling; MediaPipe is deprecated into it) > MLX Swift 47.5 tok/s @ 2.9 GB (best Swift ergonomics, no constrained decoding) > llama.cpp 37.8 tok/s @ 3.1 GB (best structured-output guarantee: JSON-Schema→GBNF) > CoreML 33.4 tok/s (lowest RAM, immature). Structured output is the hardest capability to abstract — need a per-backend degradation strategy (grammar-constrained where available, prompted-JSON + validate/retry fallback, or feature-off via `nil`).

**Blockers to decide early:** (a) weights acquisition — 0.8–2.5 GB vs the **no-network entitlement** (bundle / On-Demand Resources / documented one-time download exception); (b) Gemma Terms of Use require flowing the Prohibited Use Policy down to end users.

---

## Track B — Local memory quality (what transfers from mem0 / Letta / Zep / LangMem)

Cross-cutting small-model recipe (all sources agree): closed-vocabulary decisions, one decision per LLM call with a tiny evidence set, heuristic pre-gates to skip LLM calls, background execution, deterministic enforcement in code.

1. **`MemoryOperation` enum — add/update(id)/invalidate(id)/noop** (mem0's update phase): per extracted fact, one guided-generation call with 1 fact + top 3–4 candidate notes (~300–500 tokens), run in the existing post-turn background pass, **gated by the existing `saveNoteIfNovel` novelty check** (the cheap gate mem0 lacks). Completes the pipeline: Ember has extraction + NOOP; missing UPDATE/DELETE. mem0 measures ~7k tokens/conversation vs 26k full-context.
2. **Bitemporal invalidation instead of deletion** (Zep/Graphiti): `validAt`/`invalidatedAt`/`supersededByID` on `MemoryNote` — pure SwiftData schema change, zero inference-time tokens. Retrieval filters `invalidatedAt == nil`; inspector gains a "superseded memories" history view (a transparency feature no cloud product surfaces — perfect for Ember's ethos). Reversible, unlike letting a 3B model DELETE.
3. **Capped always-injected `UserProfile` core block** (Letta memory blocks / ChatGPT saved memories): ~150–250 tokens hard cap, **regenerated whole in background, never self-patched** (free-form self-editing fails on small models), its own `TokenBreakdown` line. Splits memory into tiny-unconditional-core + retrieved-on-relevance pool.
4. **Pre-compaction fact salvage** (MemGPT memory pressure): at ~75% budget utilization run `extractMemories` **before** `ContextCompactor` destroys detail. Deterministic trigger off `TokenBudgetCalculator`.
5. **Periodic consolidation**: cluster notes by embedding similarity in Swift (deterministic, cheap), one guided-gen merge call per cluster; stops memory hoarding. Optional: store `(subject, predicate, object)` triple alongside prose notes → contradiction candidates found by string/embedding match, no LLM call.
6. **Memory lifecycle UX** (critic gap): manage/inspect/edit/delete memories UI, snippet TTL/decay, conversation-delete → embedding cascade, SwiftData growth bounds. Privacy-first app without a "manage my memories" surface is a trust + App-Store-privacy problem.

Skip: full knowledge graphs (Zep ingestion measured >600k tokens/conversation; mem0-graph 2× cost for marginal gains), procedural/meta-prompting memory (3B rewriting its own instructions is a reliability hazard).

---

## Track C — Context-window management

1. **Retrieval budgeting replaces fixed topK=4**: budget-greedy selection under a token budget (fill from `TokenBudgetCalculator.breakdown`) with an absolute relevance floor, elbow/score-gap cutoff (CAR reports −60% tokens, −10% hallucinations), redundancy penalty `score − λ·maxSim(selected)` (embeddings already computed), and a **retrieval gate** that skips retrieval for low-signal follow-ups ("yes", "shorter please"). All deterministic, mock-testable, model-agnostic.
2. **Recursive compaction**: feed prior `ConversationSummary` + newly evicted turns back into the summarizer (`M_new = LLM(M_old + delta)`) instead of re-summarizing from scratch — O(1) memory cost, and a 3B model can't one-shot a long transcript anyway. Anchored shape: stable instruction prefix → structured summary → verbatim recent tail (StreamingLLM attention-sink justification). Trigger on **headroom** (`window − replyReserve − summarizerCost`), not a raw percentage.
3. **Eviction ladder** (highest-leverage principle across all sources — evict regenerable before summarized before truncated): (1) drop/shrink retrieved-memory blocks (retrieval can re-run), (2) clear old tool outputs, (3) fold oldest tail into recursive summary (preceded by the Track-B fact salvage), (4) only then hard-truncate. Apple's own `foundation-models-utilities` (Apache-2.0, June 2026) ships "drop completed tool calls" / "summarize selected entries" strategies to benchmark against.
4. **KV-cache hygiene** (Apple doc: cache is coupled to the append-only session): keep Instructions **byte-stable** across turns; injected memory stays in the per-turn prompt (Ember already does this — keep it that way); compact once, late, in one operation; `session.prewarm(promptPrefix:)` on conversation open (cold start is 1–2 s); expect cold cache after transcript rehydrate. **Open conflict to decide (critic):** ephemeral memory injection (Plan 10 carry-forward) requires transcript rewrite ⇒ full cache invalidation — needs an explicit cost/benefit call, or wait for iOS 27 `DynamicProfile.historyTransform` / `@SessionProperty(\.history)` which are the native hooks.
5. **Self-calibrating estimator**: after each async exact refresh, keep an EMA `exact/estimated` correction ratio **per content class** (prose vs summary vs tool JSON tokenize very differently); plan against estimate × 1.1; CJK-aware (~1 char/token per TN3193). On 26.4+/27, `response.usage` / `LanguageModelSession.usage` give free exact totals — and cache-read tokens for a "cache hits" inspector line.
6. **Error-surface update**: `GenerationError.exceededContextWindowSize` is deprecated → `LanguageModelError.contextSizeExceeded` (26.4+); must handle **both** by OS version. iOS 27 `TranscriptErrorHandlingPolicy.revertTranscript` fixes the poisoned-transcript-after-interrupted-turn problem natively; 27's `ContextOptions.reasoningLevel` introduces thinking tokens as a new budget line the inspector doesn't yet model.

Reference 4096 layout (synthesis): instructions+tools ~400–600 · core memory ~100–150 · recursive summary ~300–400 · retrieved memory 0–500 (budget-greedy) · verbatim tail ~1200–1500 · reply reserve ~700–1000.

---

## Track D — Retrieval quality, evaluation, performance

1. **Retrieval eval harness first** (critic's #1 gap): golden query→memory fixtures, recall@k / MRR, runnable in `FoundationChatKitTests`. Every knob (w=0.5, topK, thresholds, embedder swap, budget-greedy) is currently unvalidatable — and the base model **silently changes** at 26.4/27.0, so prompt+retrieval regression fixtures are needed anyway (Apple explicitly warns to re-test prompts per model version).
2. **Better embedder behind the existing seam**: nearest term — distilled-E5 CoreML (SimilaritySearchKit's proven approach) fixes the documented "NLEmbedding retrieves on lexical overlap" weakness with no network, no architecture change; later — **EmbeddingGemma** (308M, Matryoshka 768→128 dims, <200 MB QAT int4, top open multilingual <500M on MTEB; 256-dim truncation is the storage sweet spot). `NLContextualEmbedding` is NOT recommended: Apple's own docs steer similarity work back to NLEmbedding, it needs DIY pooling, and its OTA asset download inside a zero-network-entitlement sandbox is undocumented behavior (if adopted anyway: `hasAvailableAssets` + NLEmbedding fallback). Keep the hybrid lexical scorer; down-weight, don't remove.
3. **Keep the brute-force cosine scan**: Ember's scale (≤ thousands of vectors) is 2–3 orders below where ANN pays off (~50k–100k, sub-ms with Accelerate/vDSP batching if profiles ever demand). Escape hatch on record: sqlite-vec (jkrukowski/SQLiteVec or SQLiteVecKit with BM25 hybrid) — model-agnostic, survives any backend swap; ObjectBox rejected (binary-core commercial, conflicts with system-framework ethos). Note SwiftData-vs-separate-SQLite persistence split if ever adopted.
4. **Per-turn latency/energy budget** (critic gap): measure embed+extract+index cost per turn on device (Instruments energy template / xcode-instruments MCP) and gate any new per-turn work (MemoryOperation calls, profile regeneration) behind that budget.
5. **Multilingual/CJK** (critic gap): NLEmbedding `.english` hardcode means non-English users silently lose semantic memory; whitespace lexical tokenization breaks on CJK; estimator is CJK-wrong. Needs an explicit fallback decision, not a stub.
6. **Apple-native alternative worth tracking, not adopting**: Core Spotlight's `SpotlightSearchTool` (iOS 27 era) — built-in RAG tool with `FormatLevel.compact` for small windows and an observable `searchResults` stream (nice fit for the inspector) — but tool-mediated (TN3193 itself endorses Ember's retrieve-before-generate as cheaper) and Apple-only, so it belongs behind the retrieval seam if ever used.

---

## Suggested sequencing

- **Plan 11 — Agnostic seam + eval foundation** (Track A items 1–6 + D1): pure refactor + tests, no behavior change, unlocks everything; validated by the shared conformance suite.
- **Plan 12 — Memory operations** (Track B): MemoryOperation enum, bitemporal invalidation + superseded-inspector, UserProfile core block, pre-compaction salvage, lifecycle UX.
- **Plan 13 — Context-window engine** (Track C): budget-greedy retrieval + gating, recursive compaction, eviction ladder, prewarm/KV hygiene, calibrated estimator, dual error mapping.
- **Plan 14 — Embedder upgrade** (D2 + A5 migration mechanics): E5-CoreML or EmbeddingGemma behind versioned vectors.
- **Plan 15 — GemmaModelProvider** (LiteRT-LM first choice; trait-gated): only after 11 proves the seam; resolve weights-acquisition + license flow-down first.

Full source URLs are inline in the research agents' reports (workflow run `wf_c5f16059-ea1`).
