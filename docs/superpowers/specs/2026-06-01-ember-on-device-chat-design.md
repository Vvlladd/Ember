# Ember — On-Device AI Chat on Apple Foundation Models

- **Status:** Draft for review
- **Date:** 2026-06-01
- **Author:** Vlad Toma (with Claude)
- **Platforms:** iOS 26, iPadOS 26, macOS 26 (Tahoe) — Apple-Intelligence-capable devices
- **Project tooling:** Tuist · **Architecture:** MVVM + `@Observable` · **Persistence:** SwiftData

---

## 1. Vision & phased roadmap

Ember is a privacy-first, fully on-device AI chat client built on Apple's **Foundation Models** framework. It looks and feels like Claude/Codex (conversation sidebar, streaming bubbles, clean composer) but adds a distinctive **transparency layer**: because the on-device model has a hard **4,096-token context window**, Ember makes the model's working memory and token budget *visible and inspectable* — a "Context" view showing the exact prompt assembled and sent to the model, and a "Tokens" gauge showing how much of the session window remains.

The product is built in phases. **This spec fully scopes Phase 1 and documents Phases 2–3** so the architecture is built to grow into them without rework.

| Phase | Theme | Status in this spec |
|------|-------|---------------------|
| **1** | Streaming chat · availability gating · token gauge · context inspector · persisted multi-conversation history · context-overflow recovery | **Built** (fully specced below) |
| **2** | Tool calling (`Tool` protocol, `@Generable`/`@Guide` arguments) · guided/structured generation | **Documented** (§13) |
| **3** | RAG (chunking + on-device retrieval) · advanced context budgeting (summarization compaction, sliding-window trimming) | **Documented** (§14) |

### Non-goals (Phase 1)
- No cloud/remote models. On-device only.
- No tool calling, no RAG, no attachments/images, no voice. (Designed-for, not built.)
- No multi-window/scene management beyond what SwiftUI gives for free.
- No iCloud sync (local SwiftData store only; CloudKit is a later option).

---

## 2. Foundation Models grounding (reference)

> This section is the load-bearing technical reference. Every number and API here is sourced from Apple's documentation (links in §16). It exists so implementation never guesses.

### 2.1 The model
- Access the base on-device model via `SystemLanguageModel.default`. It is `@Observable`, `Sendable`.
- It powers Apple Intelligence; requires an **Apple-Intelligence-capable device** with **Apple Intelligence enabled in Settings**.
- The model is updated by Apple within OS updates. As of 26.4 there are two model generations (26.0–26.3 and 26.4); prompt behavior can shift across versions, so prompts must be regression-tested.

### 2.2 Availability — gate everything on this
```swift
switch SystemLanguageModel.default.availability {
case .available:                              // show chat
case .unavailable(.deviceNotEligible):        // device can't run Apple Intelligence
case .unavailable(.appleIntelligenceNotEnabled): // deep-link to Settings
case .unavailable(.modelNotReady):            // downloading / not ready — retry later
case .unavailable(let other):                 // forward-compat: UnavailableReason is NOT @frozen
}
```
`Availability` is `@frozen`; `UnavailableReason` is **not** — always handle an unknown `.unavailable(let other)`. There is also a convenience `isAvailable: Bool`.

### 2.3 The context window — the central constraint
- **Hard limit: 4,096 tokens per `LanguageModelSession`** (TN3193, verbatim: *"Apple's on-device foundation model has a context window of 4096 tokens per Language Model Session."*).
- The budget is shared across **everything**: instructions + every prompt + tool definitions/inputs/outputs + `@Generable` schemas + **all model responses**.
- **Token ≈ characters** (fallback estimate): ~3–4 chars/token for Latin-script languages (English/Spanish/German); ~1 char/token for CJK (Chinese/Japanese/Korean).
- **Exact counting:** `SystemLanguageModel.tokenCount(for:)` returns exact token counts for instructions, prompts, tools, `GenerationSchema`, and `Transcript.Entry`. **Introduced in 26.4.**
- **Max from the model:** `SystemLanguageModel.contextSize: Int`. **26.4** symbol (back-deployed before 26.4), can throw if the model is unavailable.
- **Overflow:** throws `LanguageModelSession.GenerationError.exceededContextWindowSize(_:)`. Recovery (TN3193): start a **new** session seeded with a condensed `Transcript`; a new session does **not** inherit prior state.

> **Implication for Ember:** On 26.4+ the token meter is exact (`tokenCount(for:)` / `contextSize`). On 26.0–26.3 it uses constant `4096` + char-based estimation. We `if #available` between the two paths.

### 2.4 Sessions
- `LanguageModelSession` is `@Observable`, `Sendable`. One session = one conversation context (its `Transcript`).
- Create: `LanguageModelSession(model: .default, tools: [], instructions:)` (instructions optional, set once, trusted-only).
- Respond: `respond(to:options:) async throws -> Response<String>` → read `.content`.
- Stream: `streamResponse(to:options:) -> ResponseStream<String>` — **synchronous call returning an `AsyncSequence`**; iterate `for try await snapshot in stream`. **Snapshots are cumulative** (`snapshot.content` is the whole response-so-far) → **replace** the in-flight bubble, never append.
- `isResponding: Bool` (`@Observable`) — a session handles **one request at a time**; calling again mid-flight is a runtime error. Bind to disable Send.
- `prewarm(promptPrefix:)` — preload resources when a request is ~1s away (e.g. first keystroke).
- **Background:** prefer non-streaming `respond(to:)` to reduce `rateLimited(_:)` (which only occurs in the background).

### 2.5 Transcript — the data model for the Context inspector
- `session.transcript` (get-only) is `Codable`, `Sendable`, a `RandomAccessCollection` of `Transcript.Entry`.
- `Transcript.Entry` has exactly five cases: `.instructions`, `.prompt`, `.response`, `.toolCalls` (a collection), `.toolOutput`. Each payload carries `segments: [Transcript.Segment]` where `Segment` is `.text(TextSegment)` or `.structure(StructuredSegment)`. (`ToolCall` exposes `toolName` + `arguments`, no segments.)
- Tool definitions hang off `Instructions.toolDefinitions` (not a separate entry).
- Reconstruct a session from saved history: `Transcript(entries:)` → `LanguageModelSession(transcript:)` → `prewarm()`.

> **Implication:** The "Context" tab renders `session.transcript` directly — it is *literally* what the model sees. Chat bubbles are a filtered projection (`.prompt`/`.response` only).

### 2.6 Generation options & errors
- `GenerationOptions(sampling:temperature:maximumResponseTokens:)`. `maximumResponseTokens` caps **output** only and truncates **silently** (can yield malformed text). Leaving it `nil` risks overflow; setting it reserves headroom.
- `GenerationError` cases we handle: `exceededContextWindowSize`, `guardrailViolation`, `rateLimited` (background-only), `refusal`, `concurrentRequests`, `assetsUnavailable`.
- **Refusals:** for plain-string responses, a refusal arrives as ordinary text beginning `"Sorry, I can't help with…"` (not programmatically distinguishable with certainty). Guided generation throws `refusal(_:_:)` with an async `explanation`.

---

## 3. Architecture overview

**MVVM + `@Observable`**, unidirectional discipline, dependency-injected via protocols.

```
┌──────────────────────────── Ember (app target, SwiftUI) ───────────────────────────┐
│  RootView (availability gate)                                                       │
│   ├─ UnavailableView(reason)                                                        │
│   └─ ChatScene  ── NavigationSplitView ──┬─ ConversationListView (sidebar)          │
│                                          ├─ ChatView (bubbles + ComposerView)       │
│                                          └─ .inspector → InspectorView              │
│                                                 ├─ ContextInspectorView             │
│                                                 └─ TokenMeterView                   │
│  Persistence: SwiftData (Conversation, Message) · ConversationStore                 │
│  ChatCoordinator (@Observable @MainActor) wires Store ↔ ConversationEngine          │
└───────────────────────────────────────────┬─────────────────────────────────────────┘
                                             │ depends on
┌───────────────────────── FoundationChatKit (framework, no UI) ──────────────────────┐
│  ModelAvailability            ChatModelProvider (protocol)                            │
│  ConversationEngine (@Observable @MainActor)   ├─ FoundationModelProvider (real)      │
│  TokenBudget · TokenEstimator                  └─ MockModelProvider (tests)           │
│  TranscriptProjection         OverflowRecovery        GenerationSettings              │
└──────────────────────────────────────────────────────────────────────────────────────┘
                       depends only on: FoundationModels (Apple)
```

**Why this split:** all decision logic (budget math, projection, recovery, turn lifecycle) lives in `FoundationChatKit` behind `ChatModelProvider`, so it is unit-testable with `MockModelProvider` on any machine — no Apple-Intelligence device required. The app target is thin SwiftUI binding.

### 3.1 Tuist module graph (`Project.swift`)
- App target **`Ember`** — destinations `[.iPhone, .iPad, .mac]`, deployment 26.0, built against the 26.4 SDK (Xcode 26.4).
- Framework target **`FoundationChatKit`**.
- Test targets **`FoundationChatKitTests`**, **`EmberTests`** (Swift Testing).
- **Zero external runtime dependencies** in Phase 1.
- Generate with `tuist generate`; build/run via xcodebuild tooling.

---

## 4. Component design (`FoundationChatKit`)

Each unit: **what it does · interface · dependencies.**

### `ChatModelProvider` (protocol) — the seam
Abstracts the framework so the engine is testable.
```swift
@MainActor protocol ChatModelProvider {
    var availability: ModelAvailability { get }
    var maxContextTokens: Int { get }                 // contextSize (26.4+) else 4096
    func makeSession(instructions: String?, restoring transcript: Transcript?) -> any ChatSessionHandle
    func tokenCount(forText text: String) -> Int?     // exact (26.4+) else nil → estimator
}
@MainActor protocol ChatSessionHandle {               // wraps LanguageModelSession
    var isResponding: Bool { get }
    var transcript: Transcript { get }
    func stream(_ prompt: String, options: GenerationSettings) -> AsyncThrowingStream<String, Error> // cumulative
    func respond(_ prompt: String, options: GenerationSettings) async throws -> String
    func prewarm()
}
```
- **Real:** `FoundationModelProvider` / `FoundationModelSession` wrap `SystemLanguageModel`/`LanguageModelSession`, translating `streamResponse` snapshots into the stream.
- **Mock:** deterministic snapshots + scripted errors + a fake `tokenCount` for tests.

### `ModelAvailability`
App-facing enum mirroring `SystemLanguageModel.Availability` with display copy + a `Settings` deep-link affordance for `.appleIntelligenceNotEnabled`. **Depends on:** FoundationModels.

### `ConversationEngine` (`@Observable @MainActor`) — the per-conversation view model
Owns a `ChatSessionHandle`. Exposes `messages: [ChatMessage]`, `isResponding`, `budget: TokenBudgetSnapshot`, `lastError: ChatError?`.
- `send(_:)` → guards `isResponding`; appends a user `ChatMessage`; opens the stream; **replaces** the in-flight assistant message on each snapshot; recomputes budget live; on completion serializes transcript + final exact recount; routes errors.
- `cancel()` cancels the in-flight `Task`.
- On `exceededContextWindowSize` → delegates to `OverflowRecovery`, swaps in the new session, emits a `.contextCompacted` notice message.
**Depends on:** `ChatModelProvider`, `TokenBudget`, `TranscriptProjection`, `OverflowRecovery`, `GenerationSettings`.

### `TokenBudget` + `TokenEstimator`
- `TokenBudget.snapshot(for: Transcript, instructions:, provider:)` → `TokenBudgetSnapshot { max, used, remaining, breakdown: [BudgetLine] }` where `BudgetLine` = (role/entry label, tokens). Uses `provider.tokenCount` when available; else `TokenEstimator`.
- `TokenEstimator.estimate(_ text:)` — script-aware: ~3.5 chars/token Latin, ~1 char/token CJK; documented as approximate.
- **Live streaming update:** `used = committedTranscriptTokens + estimate(inFlightSnapshot)`. Final pass after completion uses exact counts.
**Depends on:** nothing (pure) except the optional `tokenCount` closure.

### `TranscriptProjection`
- `bubbles(from: Transcript) -> [ChatMessage]` (filters `.prompt`/`.response`, joins `.text` segments).
- `inspectorRows(from: Transcript, instructions:) -> [ContextRow]` (all entries incl. instructions + tool defs, with per-row token attribution). **Pure, fully unit-testable.**

### `OverflowRecovery`
- `condense(_ transcript:) -> Transcript` — TN3193 baseline: keep first + last entries (deterministic, no model call). (Phase 2 upgrade: LLM-summarized compaction.)
- `recover(from session:, using provider:) -> any ChatSessionHandle` → new session from condensed transcript + `prewarm()`.

### `GenerationSettings`
`temperature`, optional `maximumResponseTokens` (off by default; UI warns it truncates), and the system `instructions` string. Maps to `GenerationOptions`.

---

## 5. Data model & persistence (SwiftData)

**Dual-truth** for robustness (Apple does not guarantee a stable on-disk `Transcript` format across model versions; `Response.assetIDs` are version-aware):

```swift
@Model final class Conversation {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var transcriptData: Data?     // best-effort fast/faithful resume (encoded Transcript)
    var modelVersionTag: String?  // OS/model generation when transcriptData was written
    var lastTokenCount: Int
    @Relationship(deleteRule: .cascade) var messages: [Message]  // DURABLE display truth
}
@Model final class Message {
    var id: UUID
    var role: Role                // .user / .assistant / .system-notice
    var text: String
    var createdAt: Date
    var conversation: Conversation?
}
```

- **`Message` rows are the durable truth** for display, history, and (later) search.
- **`transcriptData` is a best-effort cache** for faithful model resume.
- **Resume logic (`ConversationStore.load`):**
  1. If `transcriptData` decodes *and* `modelVersionTag` matches current → `LanguageModelSession(transcript:)`. Fast, faithful.
  2. Else → fresh session; re-feed recent `Message`s as context up to a budget ceiling (e.g. ≤ ~60% of 4,096) so there's response headroom; older history stays visible but out-of-window (flagged in the inspector).
- **Titles:** deterministic from the first user prompt (first ~6 words). (Optional later: a tiny model-generated title.)
- **Store:** local SwiftData container, app sandbox. No network entitlement (on-device only).

---

## 6. Token budgeting design (the "Tokens" tab)

- **Max source:** `contextSize` on 26.4+, else `4096`.
- **Gauge:** persistent compact readout in the chat toolbar (`used / max` + a bar), full breakdown in the inspector's Tokens tab.
- **Breakdown lines:** Instructions · each user Prompt · each Response · (Phase 2) Tool schemas · in-flight estimate. Sums to `used`.
- **Zones:** green < 70%, amber 70–90% (proactive "approaching context limit" banner with a **Compact context** action), red ≥ 90%.
- **Headroom:** the gauge can optionally show "reserved for reply" so users see true remaining input room.
- **Honesty:** label values "exact" (26.4+) vs "estimated" (older) so the meter never over-claims precision.

---

## 7. UI & navigation (adaptive sidebar + inspector)

- **macOS / iPadOS:** `NavigationSplitView` — sidebar = `ConversationListView` (+ "New"), detail = `ChatView`; a right-hand `.inspector` toggled from the toolbar holds a `[Context | Tokens]` `Picker`. Compact token gauge always in the toolbar.
- **iPhone:** `ChatView` with a navigable conversation list; the inspector presents as a sheet; token gauge in the nav bar.
- **ChatView:** scrollback of `MessageBubble`s (Markdown-rendered assistant text), auto-scroll, a streaming bubble that updates from cumulative snapshots, `ComposerView` (multiline, Send disabled while `isResponding`, Stop button to `cancel()`).
- **ContextInspectorView:** ordered `ContextRow`s for every transcript entry — role chip (Instructions/User/Assistant/Tool), verbatim text (with `.structure` segments rendered as formatted JSON), per-row token count, and an "out-of-window" marker for re-fed history.
- **UnavailableView:** one tailored screen per `UnavailableReason`, including a Settings deep-link for `.appleIntelligenceNotEnabled` and a retry for `.modelNotReady`.
- **HIG:** native materials, Dynamic Type, light/dark, keyboard (⌘N new chat, ⌘↩ send on macOS), VoiceOver labels on bubbles + gauge.

---

## 8. Turn lifecycle (data flow)

1. User submits → `ConversationEngine.send` guards `isResponding`, appends user `ChatMessage`, persists it.
2. Foreground → `stream(prompt)`; background → `respond(prompt)` (avoids `rateLimited`).
3. Each cumulative snapshot **replaces** the in-flight assistant bubble; `TokenBudget` recomputes `used` live (committed + estimate).
4. On completion → response is in `session.transcript`; persist assistant `Message`, re-serialize `transcriptData` + `modelVersionTag`, exact token recount, update `Conversation.updatedAt`/`lastTokenCount`.
5. Errors → §9.

---

## 9. Error handling matrix

| Condition | Detection | UX |
|---|---|---|
| Device ineligible | `.unavailable(.deviceNotEligible)` | Explain on-device requirement; hide chat |
| AI disabled | `.unavailable(.appleIntelligenceNotEnabled)` | "Enable Apple Intelligence" + Settings deep-link |
| Model downloading | `.unavailable(.modelNotReady)` | "Preparing model…" + retry |
| Context overflow | `exceededContextWindowSize` | Auto-recover via `OverflowRecovery`; insert "Context compacted" notice; keep full history visible |
| Guardrail block | `guardrailViolation` | Friendly "can't help with that" + retry; keep input |
| String refusal | text starts `"Sorry, I can't help with…"` | Render as assistant message (best-effort heuristic) |
| Rate limited (bg) | `rateLimited` | Retry on foreground; no scary error |
| Concurrent send | `isResponding == true` | Send disabled; ignore |
| Decode/assets | `decodingFailure` / `assetsUnavailable` | Retry; log |

---

## 10. Minimum OS & capabilities
- **Deployment target 26.0**; **build with Xcode 26.4 / 26.4 SDK** so `contextSize`/`tokenCount(for:)` symbols resolve.
- Runtime `if #available(iOS 26.4, macOS 26.4, *)` to choose exact vs estimated token counting.
- **No special entitlement** for the default model (only custom adapters need `com.apple.developer.foundation-model-adapter`). macOS sandbox on; no network capability (on-device).

---

## 11. Testing strategy (TDD, `MockModelProvider`)
- `TokenEstimator` — known strings → expected ranges (Latin + CJK).
- `TokenBudget` — breakdown sums to `used`; remaining math; zone thresholds; exact-vs-estimate path selection.
- `TranscriptProjection` — entry→bubble filtering; segment joining; inspector rows incl. tool-def surfacing; out-of-window flagging.
- `OverflowRecovery` — `condense` keeps first+last; recovery builds a new session.
- `ConversationStore` — `Message` round-trip; `transcriptData` encode/decode; version-mismatch → rebuild path.
- `ConversationEngine` — full turn: cumulative snapshots → single growing bubble; `isResponding` transitions; cancel; overflow auto-recovery; error routing — all via `MockModelProvider`.

---

## 12. Risks & open questions
- **Transcript portability across model versions** — mitigated by dual-truth (rebuild from `Message`s). Monitor real decode-failure behavior.
- **Estimator accuracy on < 26.4** — validate against the Foundation Models Instrument; label as estimated.
- **Live token cost of `tokenCount(for:)` per keystroke** — debounce; only exact-count on commit, estimate during typing/streaming.
- **Refusal detection** for string chat is heuristic by design (Apple limitation).

---

## 13. Phase 2 — Tool calling (documented, not built)
- Implement `Tool` (`name`, `description`, `@Generable` `Arguments` with `@Guide`, `call(arguments:) async throws -> Output`); register via `LanguageModelSession(tools:instructions:)`.
- Tool name/description/parameter **schema are injected into the prompt** → add them as explicit lines in the token breakdown; warn past Apple's 3–5 tool guidance.
- Errors surface as `LanguageModelSession.ToolCallError` at the `respond` call site. Tools run concurrently → must be `Sendable`.
- Guided/structured generation: `@Generable`/`@Guide(.range/.count/.maximumCount)` via `respond(to:generating:)`; `.maximumCount` doubles as a token-saving lever. The Context inspector renders `.toolCalls`/`.toolOutput` entries (already in the transcript model).

## 14. Phase 3 — RAG & advanced budgeting (documented, not built)
- **RAG:** chunk a corpus; embed + retrieve top-k on-device; inject only retrieved snippets into the prompt to respect the 4,096-token window. Surface retrieved chunks as their own inspector section + token line.
- **Advanced budgeting:** LLM-summarization compaction (upgrade `OverflowRecovery.condense`), sliding-window trimming, per-turn input ceilings, automatic "reserve N tokens for reply."

---

## 15. Phase 1 deliverable checklist
- [ ] Tuist graph generates; `Ember` runs on macOS + iOS (sim) + iPad.
- [ ] Availability gating with all four screens.
- [ ] Streaming chat (cumulative snapshots, Stop/cancel, `isResponding` guard).
- [ ] Persisted multi-conversation history (SwiftData dual-truth + resume).
- [ ] Context inspector = faithful `session.transcript` with per-row tokens.
- [ ] Token gauge (exact on 26.4+, estimated below) + breakdown + zones + overflow auto-recovery.
- [ ] `FoundationChatKit` unit tests green via `MockModelProvider`.

---

## 16. References
- Foundation Models: https://developer.apple.com/documentation/foundationmodels
- TN3193 — Managing the context window: https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window
- `SystemLanguageModel` · `.availability` · `.contextSize` · `tokenCount(for:)`
- `LanguageModelSession` · `respond(to:options:)` · `streamResponse(to:options:)` · `transcript` · `prewarm(promptPrefix:)`
- `Transcript` (+ `Entry`/`Segment`/`ToolCalls`/`ToolOutput`)
- `GenerationOptions` · `GenerationError` (`exceededContextWindowSize`, `guardrailViolation`, `rateLimited`, `refusal`)
- `Tool` · `Generable` · `@Guide` · `GenerationSchema`
- Prompting & safety: `prompting-an-on-device-foundation-model`, `improving-the-safety-of-generative-model-output`
- WWDC25: "Meet the Foundation Models framework" (286), "Deep dive" (301), "Code-along" (259)
- Tuist: https://docs.tuist.dev
