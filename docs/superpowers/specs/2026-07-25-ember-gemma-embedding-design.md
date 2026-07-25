# Ember — EmbeddingGemma as the memory embedder (design)

**Date:** 2026-07-25 · **Status:** approved design (brainstormed + user-approved this session)
**Research basis:** `2026-07-25-ember-plan-11-research-memory-rag-context-model-agnostic.md`

## Goal

Replace `NLTextEmbedder` (NLEmbedding sentence vectors) with **EmbeddingGemma-300m running on Core ML** behind the existing `TextEmbedder` seam, so memory retrieval keys on real semantics instead of lexical overlap. Ship with versioned vectors, a safe background migration, an NLEmbedding fallback, and a fixture-based eval gate that must show EmbeddingGemma beating NLEmbedding before the swap ships.

**Why:** the documented quality ceiling — NLEmbedding retrieves on surface lexical overlap ("what should I pack?" never matches "trip to Lisbon"); the Plan-10 hybrid lexical scorer is a mitigation, not a fix. EmbeddingGemma (308M params, Gemma-3 family, Matryoshka 768→128 dims, top open multilingual embedder <500M on MTEB) is purpose-trained for retrieval.

## Decisions (locked with user)

| Decision | Choice | Why |
|---|---|---|
| Model | **EmbeddingGemma-300m** (not raw Gemma 3 LLM pooling) | Purpose-built for retrieval; 3–13× smaller than the LLM route with better quality |
| Weights delivery | **Bundled in the app** (~150–200 MB quantized) | Preserves zero-network purity; works on iOS + macOS (ODR is iOS-only); no failure path |
| Runtime | **Core ML** (`.mlpackage`, ANE) | System inference framework — truest to Ember's ethos; lowest RAM/energy; only dep is the tokenizer |
| Output dims | **256** (Matryoshka truncation of 768, re-normalized) | 3× smaller storage, ~1–2% MTEB loss |
| Tokenizer | **swift-transformers `Tokenizers`** (Apache-2.0, SPM) | SentencePiece for Gemma; the one new dependency, tokenizer-only |

## Current state (what changes)

- `Targets/FoundationChatKit/Sources/Memory/TextEmbedder.swift` — protocol is `embed(_ text: String) -> [Float]?` (sync, no role, no identity); `NLTextEmbedder` caches `NLEmbedding` once, `.english` hardcoded.
- `MemoryStore` stores vectors as raw `Data` on `Message.embedding` and `MemoryNote` with **no embedder tag**; `snapshot()` unions them; brute-force cosine (stays — scale is far below ANN territory).
- `ChatCoordinator` wires one embedder instance app-wide; `saveNoteIfNovel` uses cosine ≥ 0.85 for de-dup; auto-RAG retriever embeds the query per turn.

## Components

### 1. Seam change — `TextEmbedder` v2

```swift
public enum EmbeddingRole: Sendable { case query, document }

public struct EmbedderIdentity: Sendable, Equatable {
    public let id: String        // e.g. "embeddinggemma-300m-256d", "nl-sentence-en-512d"
    public let dimension: Int
}

public protocol TextEmbedder: Sendable {
    var identity: EmbedderIdentity { get }
    func embed(_ text: String, role: EmbeddingRole) -> [Float]?
}
```

- EmbeddingGemma is trained with asymmetric task prefixes: documents embed as `"title: none | text: <text>"`, queries as `"task: search result | query: <text>"` (exact strings verified against the model card during implementation — treat the model card as ground truth).
- `NLTextEmbedder` conforms by ignoring `role`; `MockEmbedder` (tests) gains role capture + injectable identity.
- Call-site mapping: `MemoryStore.index`/`saveNote`/`backfill` → `.document`; retriever closure + `MemorySearchTool` queries → `.query`. `saveNoteIfNovel` embeds the candidate note as `.document` — its cosine de-dup is a document↔document comparison against stored note vectors, not a search.

### 2. `GemmaTextEmbedder`

Final class, `@unchecked Sendable`, mirroring `NLTextEmbedder`'s cached-resource pattern:

- Lazily loads the bundled `.mlpackage` on first `embed` (Core ML compiles/caches on first load; ANE-eligible). Load happens off the main actor.
- Tokenizes with swift-transformers (Gemma SentencePiece vocab bundled alongside the model), applies the role prefix, runs prediction, takes the pooled 768-dim output, truncates to 256, re-normalizes to unit length.
- Truncation to the model's max input tokens (2K for EmbeddingGemma; memory snippets are ≤240 chars so this is headroom, but guard anyway).
- Logs via `EmberLog.embed` exactly like `NLTextEmbedder` (ready/dim on load, nil-vector notices).

### 3. Weights + tokenizer packaging

- `Models/` directory at repo root, **gitignored**; `scripts/fetch-embeddinggemma.sh` downloads the Core ML conversion + tokenizer files once per dev machine (Hugging Face; community Matryoshka conversions exist — script pins an exact revision).
- Tuist `Project.swift` adds the `Models/` glob as an Ember-app resource (framework stays resource-free; the embedder receives the model URL via init injection, keeping FoundationChatKit unit-testable without weights).
- Build proceeds if the model is absent (resource glob is optional); the app then runs on the NLEmbedding fallback — so CI and contributors without weights are unaffected.

### 4. Vector versioning + migration

- Additive SwiftData fields (lightweight migration): `Message.embedderID: String?`, `MemoryNote.embedderID: String?`. `nil` = legacy NLEmbedding vector.
- `MemoryStore` tags every vector it writes with the active embedder's `identity.id`.
- `snapshot()`/`search`: a record's vector participates in cosine scoring **only if** its `embedderID` matches the active embedder; mismatched records behave as unembedded (lexical-only) until re-embedded. Old and new vector spaces are never compared.
- `backfill()` extends to **re-embed mismatched rows in chunks** (e.g. 50/launch pass, oldest first, idempotent per row, interruption-safe — each row updates vector + embedderID atomically). Store converges to the new space over a few launches; retrieval degrades gracefully (lexical-only for not-yet-migrated rows) in the interim.
- `saveNoteIfNovel` cosine de-dup only compares same-space vectors; cross-space candidates fall back to the text-equality/containment checks (already first in the chain).

### 5. Fallback + wiring

- App-level factory: try `GemmaTextEmbedder` (model URL present + loads) → else `NLTextEmbedder`. Logged prominently. `ChatCoordinator` keeps receiving a single `TextEmbedder` — no other wiring changes.
- `lexicalWeight` stays 0.5 at ship; retuning is a follow-up driven by the eval numbers, not folded into this change.

### 6. Eval gate (acceptance criterion)

- New fixture suite in `FoundationChatKitTests`: golden `(query, corpus, expected-hit)` cases including the documented lexical-miss regressions ("what should I pack?" → Lisbon-trip note; question↔question near-dup trap from the Plan-9 debugging) plus paraphrase, keyword, and negative (no-relevant-memory) cases. Helper computes recall@k / MRR over `MemoryStore.search`.
- Deterministic tests run on `MockEmbedder`. The real-model eval runs the same fixtures through `GemmaTextEmbedder` vs `NLTextEmbedder`, gated `.enabled(if: <model file present>)` so machines without weights skip cleanly.
- **Ship gate:** EmbeddingGemma must beat NLEmbedding on fixture recall@4 (and must not regress the keyword cases) or the default stays NLEmbedding.

## Error handling

| Failure | Behavior |
|---|---|
| Model file missing / load throws / OOM | Factory falls back to `NLTextEmbedder`; error logged; app behaves exactly as today |
| Tokenizer asset missing/corrupt | Same fallback (treated as load failure) |
| `embed` returns nil (empty text, prediction error) | Existing degradation: record stays unembedded, lexical-only scoring |
| Interrupted migration | Idempotent per-row backfill just resumes next launch |
| Dimension/space mismatch | Structurally impossible to compare: embedderID gate |

## Testing

TDD throughout (house rule). Unit: protocol change + role prefixes (mock asserts role/prefix), identity tagging, mismatch gating in `search`, chunked backfill idempotence, factory fallback, Matryoshka truncate+renormalize math. Integration (model-gated): real-vector eval suite above. App target must compile at every commit (exhaustive-switch rule applies to any new enum).

## Out of scope

Gemma chat provider (Plan 15), mem0-style memory operations, retrieval budgeting/gating, sqlite-vec, multilingual lexical scorer work. NLEmbedding remains in the codebase as the permanent fallback.

## Risks / verify-then-use (implementation must confirm)

1. **Core ML conversion source**: pin a specific community conversion revision (or convert with coremltools ourselves); verify pooled-output shape and that Matryoshka truncation matches the model card's procedure.
2. **Exact prefix strings** from the EmbeddingGemma model card (they differ between docs floating around; the model card is authoritative).
3. **Per-embed latency on device** (target: comparable to NLEmbedding's per-message cost; measure via the existing EmberLog timings before enabling by default on old devices).
4. **App size**: ~+200 MB bundle — confirm acceptable before shipping; App Thinning doesn't help a bundled resource.
5. **License**: Gemma Terms of Use flow-down text must be added to the app's terms in the same release that ships the weights.
