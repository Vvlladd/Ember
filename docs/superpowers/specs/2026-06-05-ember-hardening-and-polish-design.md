# Ember — Plan 4: Hardening & Polish (design)

- **Status:** Draft for review
- **Date:** 2026-06-05
- **Author:** Vlad Toma (with Claude)
- **Builds on:** Plan 1 (engine), Plan 2 (UI), Plan 3 (tool calling — PR #3). Branches off `plan-3-tools`; rebases onto `main` once Plan 3 merges.
- **Platforms:** iOS 26, iPadOS 26, macOS 26.
- **Tooling:** Tuist · MVVM + `@Observable` · SwiftData · FoundationModels · Swift Testing.

---

## 1. Goal & scope

Close the long-standing **deferred** items from the Plan 2 carry-over and the two minor robustness items the Plan 3 final review surfaced — turning Ember from "feature-complete" into "robust and polished." No new product surface beyond what's listed; **no network capability or entitlement added.**

This is the second sub-plan of the post-Phase-1 roadmap (Plan 3 = Tools ✅, **Plan 4 = Hardening**, Plan 5 = RAG).

### In scope (all six approved items + Plan 3 review follow-ups)
- **A. Exact async token counts** + fix the double-"Instructions" budget line.
- **B. Deep producer cancellation** (Stop truly halts on-device generation).
- **C. Live availability reactivity** (re-evaluate, not only at launch).
- **D. Markdown rendering** in assistant bubbles (native, on-device).
- **E. Conversation rename** (UI).
- **F. Conversation/message search.**
- **G. Titling robustness** — fold the three deferred Plan 3 safety findings: re-entrancy window (#2), availability pre-check before the throwaway titling session (#3), and don't clobber a user-set title (#5).
- Trivial: **calculator float-format** polish.

### Out of scope
- RAG / retrieval (Plan 5). Attachments, voice, multi-window. iCloud sync. Custom adapters.
- No `Project.swift`/entitlement/network changes.

### Constraints carried forward
- 4,096-token window; everything stays on-device and mock-testable behind `ChatModelProvider`.
- The branch must build (framework tests + macOS + iOS app) at every milestone boundary.

---

## 2. Foundation Models grounding (relevant to A–C)
> Verified via Apple docs (sosumi). Re-verify symbols during implementation.
- `SystemLanguageModel` is **`@Observable`** and `Sendable`; exposes `availability`, `isAvailable`, `contextSize`, and **`tokenCount(for:)`** (async; the exact counter introduced in 26.4). → enables **A** (exact counts) and **C** (observe availability).
- `LanguageModelSession.ResponseStream` conforms to **`AsyncSequence`** → cancelling the Task that iterates it propagates cancellation to generation. → basis for **B** (deep cancellation): cancel the producer Task driving our `AsyncThrowingStream`.
- `respond(to:generating:)` (used by `ConversationTitler`) and `Tool`/`@Generable` are unchanged from Plan 3.

---

## 3. Item designs

### A. Exact async token counts + instructions de-dupe
**Seam:** add `func exactTokenCount(for text: String) async -> Int?` to `ChatModelProvider`.
- Real: `if #available(iOS 26.4, macOS 26.4, *) { return try? await model.tokenCount(for: text) } else { return nil }`.
- Mock: returns a scripted/`exactCounts`-driven value (extend the existing `exactCounts` flag to an async path).

**Engine:** add `func refreshExactBudget() async`.
- Gather every accounted string (instructions, each `contextEntry.text`, each tool `schemaDigest`), `await exactTokenCount` for each into a `[String: Int]` cache, then **reuse the existing synchronous** `calculator.snapshot(..., exactCount: { cache[$0] })` — no logic duplication. Sets `isExact = true` when all counts resolved.
- Called once after a turn completes (after `finalizeAssistant`) and after resume. The live typing/streaming path keeps the sync estimator (`recomputeBudget`). On `<26.4` (all `nil`), the budget stays estimated and honestly labeled.

**Instructions de-dupe (fixes the on-device double-count):** in `TokenBudgetCalculator.snapshot`, skip the standalone `"Instructions"` line when `entries` already contains an `.instructions` entry. (Real provider: the transcript carries an instructions entry → counted once. Mock / pre-first-turn: no instructions entry → the `instructions:` param is the single source.)

**Tests:** exact path produces `isExact == true` with cache-backed counts; instructions counted exactly once when an `.instructions` entry is present; estimator path unchanged on the no-exact branch.

### B. Deep producer cancellation
**`FoundationModelSession.stream`:** capture the producer `Task` and wire `continuation.onTermination = { _ in producerTask.cancel() }`. Flow: engine `cancel()` → `turnTask` cancelled → the `for try await` consumer ends → `AsyncThrowingStream` terminates → `onTermination` cancels the producer Task → its `for try await … in session.streamResponse` (an `AsyncSequence`) stops, propagating cancellation to FoundationModels.

**Engine:** `cancel()` already cancels `turnTask`; on `CancellationError` the partial assistant bubble is kept and `isResponding` resets (verify/keep). Stop remains graceful (no `ChatError`).

**Mock:** `MockSessionHandle.stream` checks `Task.isCancelled` between scripted yields and stops, so a deterministic **mid-stream cancel test** asserts: partial bubble retained, `isStreaming == false`, `isResponding == false`, no further snapshots after cancel.

**Honesty:** we do the correct Swift-concurrency thing; whether the on-device runtime aborts compute immediately is SDK-dependent — documented, not over-claimed.

### C. Live availability reactivity
**Coordinator:** add stored `public private(set) var availability: ModelAvailability` (set from `provider.availability` at init) and `func refreshAvailability()` that re-reads it. (`@Observable` → views update.)
**RootView:** switch on `coordinator.availability`; call `refreshAvailability()` on `scenePhase` → `.active` (`@Environment(\.scenePhase)` + `.onChange`).
**UnavailableView:** add a **Retry** button (for `.modelNotReady`) calling `refreshAvailability()`; keep the existing Settings deep-link for `.appleIntelligenceNotEnabled`.
**Tests:** mock provider flips availability; `refreshAvailability()` updates `coordinator.availability`.

### D. Markdown rendering
**Parser (kit, unit-tested):** `MarkdownBlocks.parse(_ text: String) -> [MarkdownBlock]` in `FoundationChatKit/Markdown/`, where `MarkdownBlock` is `.prose(String)` or `.code(language: String?, code: String)`. Splits on fenced ```` ``` ```` regions; an unterminated fence (mid-stream) is treated as an in-progress code block. Pure, `Sendable`, fully testable.
**Renderer (app, build-verified):** `MarkdownText` view renders `.prose` via `AttributedString(markdown:options:)` (inline bold/italic/links/`code`, whitespace preserved) and `.code` in a monospaced, bordered, horizontally-scrollable box. `MessageBubble` uses `MarkdownText` for **assistant** text only; user bubbles and system notices stay plain `Text`.
**Tests:** parser — plain prose; single fenced block; prose+code+prose; unterminated fence → trailing code block; language tag captured.

### E. Conversation rename
**Coordinator:** `func rename(_ id: UUID, to title: String)` → trims; ignores empty; `store.setTitle` + `reload`. Mark the title as user-set (see G/#5).
**UI:** `ConversationListView` row context menu (+ macOS) "Rename" → `.alert` with a `TextField` bound to a draft → `coordinator.rename`.
**Tests:** `rename` updates the title; empty/whitespace ignored.

### F. Search
**Store:** `func search(_ query: String) -> [Conversation]` — case-insensitive; matches `title` OR any `message.text`; empty/whitespace query → `allConversations()` (preserves recency sort).
**Coordinator:** `var searchText: String` (observable) + `var visibleConversations: [Conversation]` computed via `store.search(searchText)`.
**UI:** `.searchable(text:)` on the sidebar bound to `coordinator.searchText`; the list iterates `visibleConversations`.
**Tests:** matches title and message text, case-insensitive; empty query → all; no match → empty.

### G. Titling robustness (Plan 3 final-review follow-ups)
- **#2 re-entrancy:** add `public private(set) var isProcessing: Bool` on the coordinator, `true` for the whole `send(_:)` (including the inline title generation). `ComposerView` disables Send while `engine.isResponding || coordinator.isProcessing`, closing the window where the composer re-enabled during titling.
- **#3 availability pre-check:** `ConversationTitler.generate`/`provider.generateTitle` returns `nil` early if the model isn't available (avoids allocating a throwaway session that will just throw).
- **#5 no clobber:** auto-title only overrides when the title is still the deterministic default (not user-renamed). Track via a `Conversation.titleIsCustom: Bool` flag set by `rename`/`setTitle(custom:)`; auto-title skips when `titleIsCustom == true`. (Auto-title is first-exchange-only, so this is belt-and-suspenders, but it makes the precedence explicit once rename exists.)

> `Conversation.titleIsCustom` is the **only** schema addition in Plan 4 (a defaulted `Bool`, additive/lightweight). All other items are code-only.

### Trivial: calculator float format
`CalculatorTool.format` rounds to a sensible precision (e.g., trim to ≤10 significant digits / drop floating-point noise like `0.1+0.2`) before stringifying; whole numbers still render without a decimal.

---

## 4. Components & file map
```
FoundationChatKit/Sources/
  Provider/ChatModelProvider.swift      # + exactTokenCount(for:) async
  Provider/FoundationModelProvider.swift# exact count (26.4+); deep-cancel via onTermination; titling availability pre-check
  Engine/ConversationEngine.swift       # refreshExactBudget(); call after turn; (cancel already handled)
  Tokens/TokenBudgetCalculator.swift    # instructions de-dupe
  App/ChatCoordinator.swift             # availability + refreshAvailability; isProcessing; rename; searchText/visibleConversations; no-clobber
  Persistence/ConversationStore.swift   # search(_:); setTitle(custom:) / titleIsCustom
  Persistence/Conversation.swift        # + titleIsCustom: Bool = false (schema addition)
  Markdown/MarkdownBlocks.swift         # NEW parser
  Tools/CalculatorTool.swift            # format polish
FoundationChatKit/Tests/                # exact budget, dedupe, mid-stream cancel, availability, rename, search, markdown parser, format
Ember/Sources/
  RootView.swift                        # scenePhase refresh; switch on coordinator.availability
  UnavailableView.swift                 # Retry for modelNotReady
  ConversationListView.swift            # rename alert + .searchable
  MessageBubble.swift                   # assistant uses MarkdownText
  ComposerView.swift                    # disable while isProcessing too
  MarkdownText.swift                    # NEW renderer
```

## 5. Persistence
Only addition: `Conversation.titleIsCustom: Bool = false` (defaulted → lightweight migration). No relationship/shape changes. Resume/transcript logic unchanged.

## 6. Testing strategy
TDD for all kit logic (A, B, C, E, F, markdown parser, format, no-clobber). App views build-verified (macOS + iOS). Final milestone: run on the iOS 26 sim — verify exact token meter (no double Instructions), Stop mid-stream, rename, search, and markdown rendering (incl. a code block).

## 7. Milestones (each ends green + committed; branch builds throughout)
- **H** — A: exact async tokens + instructions de-dupe.
- **I** — B: deep producer cancellation (+ mid-stream cancel test).
- **J** — C: availability reactivity (coordinator + RootView + Retry).
- **K** — E + F + G: rename, search, titling robustness (coordinator/store/Conversation flag + sidebar UI).
- **L** — D: markdown parser (kit, TDD) + `MarkdownText` renderer (app).
- **M** — calculator format polish + run/verify + tag `plan-4-hardening-complete` + PR.

## 8. Self-review
- **Placeholders:** none.
- **Consistency:** `exactTokenCount`/`refreshExactBudget` defined once and consumed by the engine; `isProcessing` set by coordinator `send`, read by `ComposerView`; `titleIsCustom` written by `rename`/`setTitle(custom:)`, read by auto-title; `MarkdownBlock` defined once (kit) and rendered by the app.
- **Scope:** single cohesive hardening plan; RAG explicitly deferred; one tiny additive schema field is the only data change.
- **Ambiguity:** B is honest about SDK-dependent abort; D's renderer is best-effort on partial markdown; both stated explicitly.
- **Reuses existing rails:** A reuses the sync `snapshot(exactCount:)`; E reuses `store.setTitle`; G builds on the Plan 3 titling flow rather than rewriting it.
