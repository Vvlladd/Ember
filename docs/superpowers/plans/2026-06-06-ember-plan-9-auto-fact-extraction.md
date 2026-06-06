# Ember — Plan 9 (proposal): Proactive auto-save of salient user facts

> **Status:** PROPOSAL / not yet implemented. Implement via superpowers subagent-driven TDD (fresh implementer per task, red→green→commit, reviewer gate). One branch (`plan-9-auto-fact-extraction`) + merge to `main`.
> **Relationship:** Follows Plan 7 (`docs/superpowers/plans/2026-06-06-ember-plan-7-auto-rag.md`). Independent of Plan 8 (hybrid retrieval) but **strongest combined with it** — this plan improves *what is stored*, Plan 8 improves *how it's found*. This is the higher-leverage of the two for cross-conversation recall.

## Why (the problem this solves)

Plan 7's auto-RAG embeds raw conversation messages, but `NLEmbedding` retrieves on lexical overlap, so incidental facts buried in chatty messages recall poorly (verified on-device: "I'm planning a trip to Lisbon" was not recalled for "What should I pack?"). The reliable path is the **`saveMemory` note** — concise, fact-shaped text embeds and recalls far better ("favorite color is teal" recalled cleanly).

Today the model only saves a note when it *chooses* to call `saveMemory`, and the small on-device model rarely does so proactively. **This plan makes the app extract durable user facts automatically after each turn** and persist them as `MemoryNote`s — so recall rides the reliable curated-note path instead of weak message embeddings.

**Honest scope:** cleaner stored facts improve retrieval quality, but retrieval still uses `NLEmbedding`, so zero-keyword-overlap queries can still miss (e.g. "pack" ↔ a "trip to Lisbon" note). Pairing with **Plan 8 (hybrid retrieval)** closes much of that gap. This plan also adds a per-turn model call (latency/compute) — gate it behind a setting.

## Current code (ground truth — read these first)

- `Targets/FoundationChatKit/Sources/Provider/ChatModelProvider.swift` — `@MainActor protocol ChatModelProvider` already has the throwaway-generation seams `func generateTitle(forFirstExchange: TitleSeed) async -> String?` and `func summarize(_:String) async -> String?`. **Add the new extraction seam here** and mirror their implementation/mocking exactly.
- `Targets/FoundationChatKit/Sources/Provider/FoundationModelProvider.swift` — real impl of `generateTitle`/`summarize` via a throwaway `LanguageModelSession` + guided generation. **Read `generateTitle` to copy the exact `@Generable` + `respond(to:generating:)` (or equivalent) API** rather than guessing it; confirm against Apple docs.
- `Targets/FoundationChatKit/Tests/MockModelProvider.swift` — `MockModelProvider` has `titleResult`/`summarizeResult` (+ `capturedSummarizeInput`). Add a scripted `extractedMemories` field here the same way.
- `Targets/FoundationChatKit/Sources/Memory/MemoryStore.swift` — `@MainActor`. `func saveNote(_ text:String)` (trims; ignores empty; embeds; ALWAYS persists a non-empty fact; invalidates cache). `func snapshot() -> [MemoryRecord]` (includes `.note` records). `nonisolated static func search(...)`. `Self.archive`/`Self.unarchive` are private static `Data`⇄`[Float]`.
- `Targets/FoundationChatKit/Sources/Persistence/MemoryNote.swift` — `@Model final class MemoryNote { id: UUID; text: String; createdAt: Date; embedding: Data? }`. Registered in `EmberApp`'s `ModelContainer(for: Conversation.self, Message.self, MemoryNote.self)` and in test containers (`MemoryStoreTests.makeStore()`, `ChatCoordinatorTests.makeWithMemory()`).
- `Targets/FoundationChatKit/Sources/App/ChatCoordinator.swift` — `send(_ text:) async`: `await engine.send(text)` then (titling for first exchange) `reload()` then, inside `if let memory { … }`, it `index`es the conversation's messages and drains the `MemoryWriteBuffer` into `memory.saveNote(fact)`. **The post-turn `if let memory` block is where extraction hooks in.** Note the existing pattern of capturing the write buffer BEFORE the long `await` (Plan 7.1 fix) — keep that discipline.
- `Targets/FoundationChatKit/Sources/Model/GenerationSettings.swift` — `Sendable, Equatable`; add the on/off setting here.
- `Targets/FoundationChatKit/Sources/Tools/SaveMemoryTool.swift` + `MemoryWriteBuffer.swift` — existing explicit-save path (the model's `saveMemory` tool). Auto-extraction is the *automatic* complement; both end at `MemoryStore.saveNote`.

## Design

After each completed turn, run a lightweight **guided-generation extraction** to pull durable USER facts and persist them as deduped `MemoryNote`s.

1. **Seam** (`ChatModelProvider`): `func extractMemories(userText: String, assistantText: String) async -> [String]?`. Real impl: a throwaway `LanguageModelSession` + a `@Generable` result type, e.g.
   ```swift
   @Generable struct ExtractedMemories {
       @Guide(description: "Durable facts about the USER worth remembering long-term (preferences, plans, personal details). Empty if none.")
       var facts: [String]
   }
   ```
   Prompt the model to extract ONLY stable user facts from the latest exchange — not transient chit-chat, not the assistant's own statements, not questions. Return `[]` when nothing qualifies. Mirror `generateTitle`'s throwaway-session construction and guided-generation call; return `nil` on failure (graceful — extraction is best-effort). Keep it terse.
2. **De-dupe** before saving (avoid piling near-duplicate notes turn after turn): add `MemoryStore.saveNoteIfNovel(_ text:) -> Bool` (or a `containsSimilarNote(_:) -> Bool` helper) that compares the candidate against existing notes in `snapshot()` — cheap normalized-text equality first, then optional cosine ≥ ~0.9 against existing note vectors (via the embedder + `Vector.cosineSimilarity`). Skip saving if a near-duplicate exists.
3. **Wire into `ChatCoordinator.send`** (post-turn, after existing indexing/buffer-drain, gated by a setting): call `provider.extractMemories(userText: text, assistantText: <final assistant reply>)`; for each returned fact, `saveNoteIfNovel`. Run it **off the hot path** (after the reply is already shown, like titling) so it never blocks streaming. Add `GenerationSettings.autoExtractMemories: Bool` (recommend default `true`, easily disabled). Optionally throttle (only on substantive user messages, e.g. length ≥ N, and cap facts/turn ≤ 3).
4. **(Optional) provenance**: add an additive `MemoryNote.autoExtracted: Bool = false` field so auto-saved facts can be distinguished from explicit `saveMemory` ones (for a future "Ember remembered: …" UI affordance + user deletion). Additive `@Model` field → keep it optional/defaulted so it's migration-safe; if you add it, also surface it (e.g. `MemoryRecord` gains the flag) only if a consumer needs it — otherwise defer.

## Tasks (TDD: write the failing test, watch it fail, implement, commit)

- **Task 1 — extraction seam + mock**: add `extractMemories(userText:assistantText:)` to `ChatModelProvider`; implement in `MockModelProvider` (scripted `extractedMemories: [String]` + capture the inputs); real `FoundationModelProvider` impl via throwaway session + `@Generable` (copy `generateTitle`'s pattern; confirm the API in code + Apple docs). Tests: mock returns scripted facts; engine/provider tests compile. (Real-impl behavior is validated in the sim E2E, not unit tests.)
- **Task 2 — de-dupe helper** (`MemoryStore.saveNoteIfNovel` / `containsSimilarNote`) + tests (`MemoryStoreTests`): saving the same fact twice yields ONE note; a clearly different fact is saved; near-duplicate (normalized-equal or high-cosine) is skipped. Use `MockEmbedder` vocab for vectors.
- **Task 3 — wire into `ChatCoordinator.send` + setting**: add `GenerationSettings.autoExtractMemories` (defaulted; update memberwise init + `SupportingTypesTests` defaults assertion); after the turn, call `extractMemories` and `saveNoteIfNovel` each, gated by the setting; keep it after the existing buffer-drain and capture any needed state before long awaits. Tests (`ChatCoordinatorTests`): with a `MockModelProvider` scripted to return `["User is planning a trip to Lisbon"]`, after `send` a `.note` with that text appears in `memory.snapshot()`; with the setting off, nothing is extracted; a duplicate across two sends is saved once.
- **Task 4 (optional) — provenance field** `MemoryNote.autoExtracted` (+ schema already covers the model; additive field is migration-safe) and any UI/inspector distinction.

## Tests / verification (house rules — CLAUDE.md)
- After adding files: `tuist generate --no-open` BEFORE xcodebuild. SourceKit squiggles unreliable — trust xcodebuild. Sandbox/permission Bash error → retry `dangerouslyDisableSandbox: true`.
- `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -20` → `** TEST SUCCEEDED **`.
- macOS + iOS (`iPhone 17 Pro`) `Ember`-scheme builds → `** BUILD SUCCEEDED **`.
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Invoke `foundation-models-best-practices` (tool/guided-gen design, terse `@Guide`, on-device/privacy); ground `@Generable`/`respond(to:generating:)`/`LanguageModelSession` claims in Apple docs (sosumi).
- **On-device E2E** (erase sim first — `xcrun simctl erase "iPhone 17 Pro"` — for a clean store): in chat 1 say "I'm planning a trip to Lisbon next month."; confirm via the Context inspector that an auto-extracted `.note` (e.g. "Saved memory: …Lisbon…") was created; start a NEW chat and ask a related question; confirm recall now surfaces it (especially if Plan 8 is also in). Verify the `autoExtractMemories` setting toggles the behavior.

## Gotchas
- `MemoryStore` is `@MainActor`; extraction is `async` on the `@MainActor` provider — fine, but keep extraction OFF the streaming hot path (run after the reply renders) so it never delays the user-visible response. Capture any state needed for the drain/extract BEFORE long `await`s (mirror the Plan 7.1 buffer-capture fix in `send`).
- Extraction is an extra model call per turn → real latency/compute. Default-on is reasonable but make it a one-line setting to disable; consider throttling (length heuristic / cap facts per turn).
- Quality: the small (~3B) model will sometimes extract noise or hallucinate. Mitigate with a strict prompt, dedup, and a per-turn cap. These notes are user-visible in the Context inspector as "Saved memory: …" (transparency); auto-extracted notes should ideally be user-deletable (UI follow-up).
- Privacy: extraction stays fully on-device (same `LanguageModelSession`/`NLEmbedding` stack). Do NOT add any network. Persisted facts are personal data — keep them local-only.
- Test containers already include `MemoryNote.self`; if you add `MemoryNote.autoExtracted`, it's an additive optional/defaulted field (migration-safe) — keep it so.
- `MockModelProvider` is the seam for deterministic tests; the real extraction is validated only in the sim E2E (model behavior is nondeterministic — assert on the *plumbing* in unit tests, not on the model's word choices).

## Out of scope
Cross-device/iCloud sync of memories, a memory-management UI (review/edit/delete) beyond the optional provenance flag, multilingual extraction, summarizing/merging notes over time.
