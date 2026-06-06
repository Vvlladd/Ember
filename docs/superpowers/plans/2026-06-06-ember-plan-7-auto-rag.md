# Ember — Plan 7: RAG made automatic, faster, and writable

> **For agentic workers:** implemented via superpowers subagent-driven TDD (fresh implementer per task, red→green→commit, reviewer gate). One branch (`plan-7-auto-rag`) + one PR.

**Goal:** Turn Phase-3 conversation-memory RAG from a model-discretion tool into automatic, high-precision retrieval-augmentation; remove hot-path waste (embedder/snapshot caching); and let the model deliberately persist curated facts via a `saveMemory` write tool. All retrieved memory stays visible in the Context inspector and counted in the token budget.

## Context — three weaknesses found reviewing against the Foundation-Models-Framework-Example

1. **Recall depended on the model.** RAG was exposed only as the `searchMemory` tool. On a 4,096-token window with a small on-device model, the model often won't choose to call it, so relevant past context was silently missed. No automatic retrieval-augmentation.
2. **Hot-path waste.** `NLTextEmbedder.embed` re-resolved the `NLEmbedding` asset on every call (once per message during backfill, once per query). `MemoryStore.snapshot()` re-fetched and unarchived every vector on every conversation open.
3. **Memory was read-only to the model.** Every message was auto-embedded, but the model could never deliberately persist a curated fact.

Networked tools from the reference (Weather, WebSearch, Contacts, …) are **out of scope** — Ember has no network entitlement by design.

## Shape of the change

```
User prompt → ConversationEngine.performTurn
  → MemoryRetrieval seam (embed prompt, top-k cosine over snapshot)
  → MemoryContextBlock.wrap → augment(prompt) → session.stream(AUGMENTED)
  → raw prompt stays in the on-screen bubble + persisted Message row
Transcript → TranscriptMapping.split → .retrievedMemory entry + clean .userPrompt
  → Context inspector ("MEMORY", teal) + token budget ("Memory" + "You")

Model calls saveMemory → MemoryWriteBuffer (actor)
ChatCoordinator.send (after the turn) → drain → MemoryStore.saveNote → MemoryNote @Model
  → next snapshot includes the note as a .note record (retrievable next engine build)
```

## Tasks (each: TDD red→green→commit, one Opus implementer, reviewer gate)

- **Task 1 — Performance** (`eaa93ee`): `NLTextEmbedder` struct→`final class … @unchecked Sendable` caching `NLEmbedding` once in `init`; `MemoryStore` lazy `cachedSnapshot` invalidated only on an actual vector write.
- **Task 2 — RAG foundation** (`8d1d817`): new `ContextEntryKind.retrievedMemory`; updated **all five** exhaustive switches (`ContextProjection.bubbles`, `TokenBudgetCalculator.label`, `FoundationModelProvider.makeSession(seeding:)`, `ContextCompactor` recap, app `ContextInspectorView` label/color → teal "MEMORY"); new `MemoryContextBlock` (single source of truth for `⟦memory⟧…⟦/memory⟧` framing: `formatHit`/`wrap`/`augment`/`split`); `GenerationSettings.memoryRetrievalTopK = 2`, `memoryRetrievalThreshold = 0.35`. (The `ContextCompactor` switch was an exhaustive-switch site the original plan missed.)
- **Task 3 — Automatic hybrid RAG** (`696e847`): `ConversationEngine.MemoryRetrieval { @Sendable (String) -> [MemoryHit] }` injected (default `nil`); `performTurn` augments the streamed prompt while the bubble/persisted row stay raw; `TranscriptMapping` `map`→`flatMap`, splitting an augmented `.prompt` into `.retrievedMemory` + clean `.userPrompt`; `ChatCoordinator.makeEngine` builds the retriever from one shared snapshot reused by the retained `searchMemory` fallback.
- **Task 4 — Model-decided saves** (`831a258`): `MemoryNote @Model`; `MemoryRecord.Source { conversation, note }` (defaulted `.conversation`); `MemoryContextBlock.formatHit` renders notes as "Saved memory: …"; `MemoryStore.saveNote` + notes in `snapshot()`; `MemoryWriteBuffer` (actor) + `SaveMemoryTool`; `ChatCoordinator` drains the buffer to `saveNote` after the turn; `EmberApp` registers `MemoryNote` in the schema. Five tools when memory is on.

## Review addendum (adversarial review → fixes, `6f99987`)

A multi-lens adversarial review (concurrency/Sendable, Foundation-Models best practices, silent-failure hunt) found and we fixed:

- **Honest `saveNote`** — previously dropped the fact when `embed` returned nil, though the tool already told the model "Saved." Now always persists a non-empty fact (embedding optional); an unembedded note maps to an empty vector and is harmlessly filtered out of search.
- **Buffer capture before the await** — `ChatCoordinator.send` now captures the write buffer *before* `await engine.send`, so a mid-turn conversation switch can't misroute/lose facts.
- **No stale memory in recaps** — `ContextCompactor` and the seeding recap exclude `.retrievedMemory` (re-retrieved fresh each turn; kept out of the instructions channel per Apple's "don't put untrusted content in instructions" guidance).
- **Mock surfaces tool throws** instead of swallowing with `try?`.

## Known limitations / future work (deliberately out of scope)

- **Within-window memory accumulation.** Each turn's augmented prompt persists in the `Transcript`, so memory blocks can accumulate between compactions on the 4K window. Mitigated by excluding `.retrievedMemory` from compaction; a stronger fix (ephemeral, non-persisted injection, or per-turn dedupe) is future work.
- **`searchMemory` retained** alongside auto-RAG per the stated requirement (5 tools). If the window proves tight on-device, gating it behind a setting is the natural follow-up now that reads are automatic.
- **Notes share one ranked pool** with conversation snippets (no source weighting); brute-force cosine (no ANN). Fine at this scale.

## Verification

```bash
tuist generate --no-open
xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test   # 142 tests → ** TEST SUCCEEDED **
xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=macOS' build               # ** BUILD SUCCEEDED **
xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build  # ** BUILD SUCCEEDED **
```

End-to-end on the iOS 26 simulator (manual): state a fact in one chat, start a new chat and ask something related — the reply should use the recalled context without the model calling `searchMemory`, with a distinct teal MEMORY section + matching budget line in the Context inspector. Verify `saveMemory` by asking the model to "remember" a fact, then recalling it in a later session.
