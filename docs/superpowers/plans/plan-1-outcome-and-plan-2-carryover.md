# Plan 1 Outcome & Plan 2 Carry-over

**Date:** 2026-06-01 · **Branch/tag:** `plan-1-foundation` / `plan-1-foundation-complete`

## Shipped (Plan 1)
`FoundationChatKit` framework, fully TDD (35 tests, 10 suites, green on macOS) + the `Ember` app shell (placeholder UI). Framework **and** app build on **macOS 26** and **iOS 26 simulator** (iPhone 17 Pro). Tuist 4.154.3, Xcode 26.5, Swift 6.3.

Components: value types (`ChatMessage`, `ContextEntry`, `GenerationSettings`, `ModelAvailability`, `ChatError`, token-budget types) · `TokenEstimator` + `TokenBudgetCalculator` · `ContextProjection` · `OverflowRecovery.condense` · `ChatModelProvider`/`ChatSessionHandle` seam · `MockModelProvider` · `ConversationEngine` · real `FoundationModelProvider` · SwiftData `Conversation`/`Message`/`ConversationStore`.

On the dev machine, `SystemLanguageModel.default.availability == .available` and `contextSize == 4096`.

## Known limitations (by design / SDK constraints)
- **(a) Exact token counts are async-only.** `SystemLanguageModel.tokenCount(for:)` is `async throws`, so our synchronous `ChatModelProvider.tokenCount(for:) -> Int?` returns `nil` and the real provider's budget uses the **char estimator** (`isExact == false`). `contextSize` is non-throwing and used directly.
- **(b) Producer cancellation depth.** `cancel()` cancels the consuming `turnTask` (stops UI updates, clears `isResponding`), but the real provider's stream wrapper spawns an inner `Task` that is not linked, so on-device *generation* isn't truly stopped yet.
- **(c) SwiftData `mainContext` crash.** On macOS 26.5, `container.mainContext` with cross-module `@Model` types traps (`swift_weakLoadStrong`). Tests use `ModelContext(container)` as a workaround. **Plan 2 MUST verify the real app path** (the app currently has no `ModelContainer`).
- **(d) Overflow recovery realization.** Real provider carries condensed context as an **instructions recap** (no fragile `Transcript` reconstruction); robust, cannot re-overflow. The engine contract is `makeSession(seeding: condensed)`; the mock realizes it via `contextEntries`.

## Plan 2 must-do wiring (from final holistic review)
1. **Connect engine ⇄ store.** The engine persists nothing today. On turn completion, call `ConversationStore.appendMessage` (user + assistant) and `updateResumeState(transcriptData: session.encodedTranscript(), modelVersionTag:, tokenCount:)`. Expose a public hook on `ConversationEngine` (it keeps `session` private).
2. **Add a `[ContextEntry]`-seeded resume path on the engine** so the dual-truth fallback (`ConversationStore.contextEntries(for:)` when `transcriptData` is stale/absent) can rehydrate a session. Today `init(restoring:)` only takes `Data?`.
3. **Verify SwiftData in the app** (limitation c). Stand up the real `ModelContainer` in `EmberApp`; if `mainContext` traps, standardize on `ModelContext(container)`.
4. **Wire async exact `tokenCount`** (limitation a): add an `async` exact-count provider method and refresh the budget to exact after a turn completes (estimator stays the live-typing path).
5. **Mid-stream cancel test + real Stop button** (limitation b): extend the mock to interleave, test that cancelling mid-stream keeps the partial bubble, clears `isStreaming`, resets `isResponding`.
6. **Decide on `ChatError.cancelled` / `.modelUnavailable`** — declared but never produced in Plan 1.

## Minor (non-blocking, optional in Plan 2)
- `ContextProjection.bubbles` stamps all restored bubbles with one `now()` — if the UI sorts by `createdAt`, restored bubbles tie (use array order).
- Transient mid-stream budget under-count with the mock (user prompt not yet committed); self-corrects on completion; real provider's transcript timing differs.

## Plan 2 scope (UI) — already specced in the design doc §7
Availability-gated root + 4 unavailable screens · `NavigationSplitView` sidebar (conversation list) + chat · streaming `MessageBubble` + `ComposerView` (Send/Stop, `isResponding`) · right-side `.inspector` with `[Context | Tokens]` · `ContextInspectorView` (rows from `contextEntries`, per-row tokens, out-of-window marker) · `TokenMeterView` (breakdown, zones, approaching-limit banner + Compact action) · toolbar token gauge · `ChatCoordinator` wiring store ⇄ engine.
