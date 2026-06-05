# Ember — Plan 6: Advanced Budgeting (design)

- **Status:** Draft for review
- **Date:** 2026-06-05
- **Author:** Vlad Toma (with Claude)
- **Builds on:** Plans 1–5. Branches off `plan-5-rag`; rebases onto `main` as the stack merges.
- **Platforms:** iOS 26, iPadOS 26, macOS 26.
- **Tooling:** Tuist · MVVM + `@Observable` · SwiftData · FoundationModels · Swift Testing.

---

## 1. Goal & scope

The second half of roadmap Phase 3 (spec §14) and the **last roadmap item**: replace Ember's crude "keep first + last" overflow recovery with **model-summarized compaction**, and stop *reacting* to the hard `exceededContextWindowSize` error by **proactively reserving headroom for the reply** — compacting *before* a turn would overflow. Stays on-device, mock-testable, and transparent (a system notice records every compaction).

### In scope
- **`GenerationSettings.reservedReplyTokens`** — tokens always kept free for the model's reply.
- **`ChatModelProvider.summarize(_:) async -> String?`** seam (real = throwaway session; mock = scripted).
- **`ContextCompactor`** — model-summarized compaction with **keep-first-last fallback** (`OverflowRecovery.condense`).
- **`ConversationEngine`** — **proactive** pre-turn compaction (when `used + prompt + reserve > max`) and an upgraded **reactive** `recoverFromOverflow`, both reusing `makeSession(seeding:)`.
- A "Reserved for reply" line in the Tokens tab.

### Out of scope
- **Per-turn input ceiling** (rejecting/truncating a single oversized prompt) — YAGNI; proactive compaction + reserve cover the real case.
- No network/entitlement; no schema change.

### Constraints carried forward
- 4,096-token window; everything behind protocols, mock-testable. Compaction must degrade gracefully (model unavailable → keep-first-last; never crash).

---

## 2. FoundationModels grounding
- Overflow throws `LanguageModelSession.GenerationError.exceededContextWindowSize` (already mapped to `ChatError.contextOverflow`). TN3193: recover by seeding a **new** session with condensed context — which Ember already does via `makeSession(settings:tools:seeding:)` (builds a "Summary of earlier conversation" instructions recap). Plan 6 improves *what* gets seeded (a model summary instead of first+last).
- Summaries are produced with an ordinary `respond` on a throwaway `LanguageModelSession` (same pattern as `ConversationTitler`); guarded by availability, `try?`-safe.

---

## 3. Components

### `GenerationSettings.reservedReplyTokens`
Add `public var reservedReplyTokens: Int` (default **512**) + init param. Used by the engine to decide when to compact; surfaced in the Tokens tab.

### `ChatModelProvider.summarize(_ text: String) async -> String?` (seam)
- **Real** (`FoundationModelProvider`): `guard case .available = availability else { return nil }`; a throwaway `LanguageModelSession(instructions: "You compress chat history into a brief factual summary.")` → `respond(to: "Summarize the following conversation in a few sentences, preserving names, facts, and decisions:\n\(text)")`; returns trimmed content, nil on throw/empty.
- **Mock**: returns a scripted `summarizeResult: String?`.

### `ContextCompactor`
```swift
public enum ContextCompactor {
    /// Keep the most recent `keepingRecent` entries verbatim; summarize the older ones into a
    /// single recap entry via the provider. Falls back to OverflowRecovery.condense when the
    /// summary is unavailable (model off / failure) so it never blocks.
    @MainActor
    public static func compact(_ entries: [ContextEntry], keepingRecent: Int = 4,
                               using provider: any ChatModelProvider) async -> [ContextEntry]
}
```
- If `entries.count <= keepingRecent`, return `entries` unchanged.
- Split into `older` + `recent` (last `keepingRecent`). Render `older` as text (`"\(speaker): \(text)"` lines), `await provider.summarize(text)`.
- On success: return `[ContextEntry(kind: .instructions, text: "Summary of earlier conversation: \(summary)")] + recent`. (`.instructions` so `makeSession(seeding:)` folds it into the recap; consistent with the existing seed format.)
- On nil: `return OverflowRecovery.condense(entries)` (deterministic keep-first-last). `OverflowRecovery` is unchanged and remains the fallback.

### `ConversationEngine` integration (reuses `makeSession(seeding:)`)
- **Proactive** — at the top of `performTurn`, before appending the user message: compute `projected = budget.usedTokens + estimate(prompt) + settings.reservedReplyTokens`. If `projected > provider.maxContextTokens` and `session.contextEntries.count > 1`, `await compact()` (rebuild the session from `ContextCompactor.compact(session.contextEntries, using: provider)`), append a `.systemNotice` "Older turns were summarized to make room.", recompute budget. Then continue the turn.
- **Reactive** — `recoverFromOverflow` becomes `async`: `let condensed = await ContextCompactor.compact(session.contextEntries, using: provider)` instead of `OverflowRecovery.condense(...)`; rest unchanged (rebuild, notice, persist). `handle(...)` awaits it (it's already inside the async `performTurn` catch).
- The estimator for `estimate(prompt)` reuses `TokenEstimator` (the engine already holds a `TokenBudgetCalculator`; expose/estimate the prompt the same way the budget does). Compaction is idempotent-safe (only fires when over the reserve threshold).

### UI — `TokenMeterView` (build-verified)
Add one row under the gauge: `"Reserved for reply: \(reservedReplyTokens)"` (the view gains the value via the engine's `budget`/settings — pass `reservedReplyTokens` into the snapshot or the view). Minimal; no other UI change.

---

## 4. Data model & persistence
**No schema change.** Compaction rebuilds the live session and persists resume state via the existing `recordResumeState` hook; durable `Message` rows are untouched (full history stays visible even after the model's working context is compacted — Ember's dual-truth).

## 5. Testing (TDD)
- `GenerationSettingsTests` — `reservedReplyTokens` default 512 + custom.
- `ContextCompactorTests` (mock provider) — scripted summary → `[recap(.instructions)] + last K`; `summarizeResult = nil` → equals `OverflowRecovery.condense`; `count <= K` → unchanged.
- `MockModelProvider` — add `summarizeResult: String?` + `summarize`.
- Engine **proactive** — set mock `maxContextTokens` low (e.g. 60) + scripted summary; a near-full session + a prompt triggers pre-turn compaction (session rebuilt to fewer entries, a "summarized to make room" `.systemNotice` present, the turn still completes). Engine **reactive** — scripted `exceededContextWindowSize` still recovers (now via the compactor).
- App view (`TokenMeterView`) verified by **build** (macOS + iOS). Final milestone: run on the sim.

## 6. Milestones (each ends green + committed)
- **S** — `GenerationSettings.reservedReplyTokens` + `ChatModelProvider.summarize` seam (protocol + real + mock) (TDD).
- **T** — `ContextCompactor` (model summary + keep-first-last fallback) (TDD).
- **U** — `ConversationEngine` proactive + reactive integration (TDD).
- **V** — `TokenMeterView` "Reserved for reply" line (build macOS + iOS).
- **W** — run/verify on the sim + tag `plan-6-budgeting-complete` + PR.

## 7. Self-review
- **Placeholders:** none.
- **Consistency:** `reservedReplyTokens` defined in `GenerationSettings` (S), read by the engine (U) and `TokenMeterView` (V). `summarize(_:) async -> String?` identical across protocol/real/mock (S) and consumed by `ContextCompactor` (T). `ContextCompactor.compact(_:keepingRecent:using:)` defined T, called by the engine proactive + reactive paths (U). `OverflowRecovery.condense` unchanged, used as the compactor's fallback (T).
- **Scope:** compaction + reserve only; per-turn input ceiling omitted; no schema change.
- **Ambiguity:** proactive trigger condition stated explicitly (`used + estimate(prompt) + reserve > max`); fallback path explicit (nil summary → keep-first-last); `keepingRecent` default 4, reserve default 512 (both tunable).
- **Honesty/robustness:** summarization is best-effort (`try?`, availability-guarded) — failure silently falls back to deterministic compaction, never blocks or crashes a turn. Durable history is never lost (only the model's working context is compacted).

## 8. References
- TN3193 — context window: https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window
- `LanguageModelSession.respond(to:)`, `GenerationError.exceededContextWindowSize`
- Phase 1 design §6 (token budgeting) / §14 (advanced budgeting): `docs/superpowers/specs/2026-06-01-ember-on-device-chat-design.md`
