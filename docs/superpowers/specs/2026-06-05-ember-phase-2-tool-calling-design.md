# Ember — Phase 2: Tool Calling & Guided Generation (Plan 3 of N)

- **Status:** Draft for review
- **Date:** 2026-06-05
- **Author:** Vlad Toma (with Claude)
- **Builds on:** Phase 1 design (`2026-06-01-ember-on-device-chat-design.md` §13), Plan 1 (engine) + Plan 2 (UI), both merged to `main`.
- **Platforms:** iOS 26, iPadOS 26, macOS 26 — Apple-Intelligence-capable devices.
- **Tooling:** Tuist · MVVM + `@Observable` · SwiftData · FoundationModels · Swift Testing.

---

## 1. Goal & scope

Give Ember's on-device model the ability to **call tools** and to produce **guided/structured output**, while preserving the project's two pillars: **privacy-first / no-network** and **transparency** (everything the model does is visible in the Context inspector and counted in the token budget).

This is the first sub-plan of the post-Phase-1 roadmap, decomposed as:

| Plan | Theme | This spec |
|------|-------|-----------|
| **3** | **Tool calling + guided generation** (this doc) | ✅ scoped here |
| 4 | Hardening & polish (async exact tokens, deep cancellation, live availability, Markdown, rename, search) | later |
| 5 | RAG & advanced budgeting | later |

### In scope (Plan 3)
1. A `Tool` protocol surface with `@Generable`/`@Guide` arguments, registered via `LanguageModelSession(tools:instructions:)`, threaded through the existing `ChatModelProvider`/`ChatSessionHandle` seam so the engine stays mock-testable.
2. **Three pure, on-device tools:** `DateTimeTool`, `CalculatorTool`, `UnitConverterTool` — no network, no entitlements, no permission prompts, all `Sendable` and unit-testable.
3. **Guided generation:** tool arguments use `@Generable`/`@Guide`, **and** conversation titles become model-generated via `respond(to:generating:)` (replacing the deterministic first-6-words title, which remains the fallback).
4. Tool definitions added as **lines in the token breakdown**; tool calls/outputs surfaced in the **Context inspector** (largely already wired).
5. `ChatError.toolFailed` + friendly `ErrorBanner` copy; map `LanguageModelSession.ToolCallError`.

### Out of scope (deferred)
- **Exact async token counts** for tool schemas (`tokenCount(for: GenerationSchema)` is `async throws`, 26.4+) → **Plan 4**. Plan 3 uses the honest char estimator for tool-definition lines, consistent with how prompts/responses are counted today.
- Device-data tools (EventKit, Contacts), any networked tool (would break the no-network ethos), RAG, attachments.
- **No new entitlement and no network capability are added.**

### Non-negotiable constraints carried from Phase 1
- The on-device context window is **4,096 tokens per session**, shared across instructions + prompts + **tool definitions + tool inputs/outputs** + responses (TN3193). Tool defs cost context — so we count them and follow Apple's **3–5 tools max / short descriptions** guidance.
- All decision logic stays in `FoundationChatKit` behind `ChatModelProvider`, unit-testable via `MockModelProvider` on any machine.

---

## 2. Foundation Models grounding (tool calling + guided generation)

> Sourced from Apple docs (links in §11). Implementation must not guess; sub-agents should re-verify via the sosumi `fetchAppleDocumentation` tool.

### 2.1 The `Tool` protocol
```swift
protocol Tool<Arguments, Output> : Sendable {
    associatedtype Arguments : ConvertibleFromGeneratedContent   // typically @Generable
    associatedtype Output    : PromptRepresentable               // typically String or Generable
    var name: String { get }
    var description: String { get }
    var parameters: GenerationSchema { get }                     // derived from Arguments
    var includesSchemaInInstructions: Bool { get }              // default true
    func call(arguments: Arguments) async throws -> Output
}
```
- The framework puts **name + description + parameter schema into the prompt** so the model decides when/how often to call the tool → this consumes context window.
- Tools must be `Sendable`; the framework may run `call(arguments:)` **concurrently** (and back-to-back when chaining tools).
- Apple's efficiency guidance: short `@Guide` descriptions, **3–5 tools max**, include a tool only when necessary.

### 2.2 Registering tools & the 6-phase flow
```swift
let session = LanguageModelSession(tools: [CalculatorTool(), …], instructions: "…")
let response = try await session.respond(to: "What is 12.5% of 80?")
```
Per Apple, a request with tools runs six phases: (1) present tools, (2) submit prompt, (3) model generates tool arguments, (4) your `call` runs, (5) output returned to model, (6) model produces the final response. **All of this happens inside `respond`/`streamResponse`** — the caller still just consumes the response (cumulative `String` snapshots when streaming).

### 2.3 Transcript surfacing (already modeled)
`session.transcript` gains `.toolCalls` (a collection; each `ToolCall` exposes `toolName` + `arguments`) and `.toolOutput` entries. **Ember already maps both** in `TranscriptMapping.entries(from:)` → `ContextEntry(kind: .toolCall / .toolOutput)`, and `ContextEntryKind` + `TokenBudgetCalculator.label(for:)` already handle them. So the inspector and per-entry token attribution for tool *usage* are essentially in place; Plan 3 adds tool *definition* accounting and polish.

### 2.4 Tool errors
A failure during tool calling throws `LanguageModelSession.ToolCallError` at the `respond`/`stream` site, exposing `.tool` (the failing `Tool`, hence `.tool.name`) and `.underlyingError`. A tool may instead *return* a short string ("Cannot access the database") to let the model recover gracefully — we use throwing for genuine failures (e.g. malformed calculator input the model insisted on) and returned strings for soft failures.

### 2.5 Guided generation (for titles)
```swift
@Generable struct ConversationTitle {
    @Guide(description: "A 3–5 word title for the conversation topic")
    var title: String
}
let response = try await session.respond(to: prompt, generating: ConversationTitle.self)
let title = response.content.title
```
`@Generable` makes a Swift type the model can fill; `@Guide` constrains/annotates fields. `.range`/`.count`/`.maximumCount` guides also act as token-saving levers. We use this only for titles in Plan 3.

---

## 3. Architecture decision

**Chosen: Approach A — tools live in `FoundationChatKit` as real `Tool`s; the seam carries `[any Tool]`; the mock scripts tool interactions.**

`FoundationChatKit` already imports FoundationModels (it owns `FoundationModelProvider`), so the concrete tools belong there. The tool *types* (Sendable structs with `@Generable Arguments` and `call`) need **no running model** to compile or unit-test — `CalculatorTool().call(arguments:)` is a pure async function. This keeps tool logic fully testable on any machine while letting the real provider register the exact same instances with `LanguageModelSession(tools:)`.

**Rejected alternatives:**
- **B — stringly-typed kit `ChatTool` + dynamic schemas in the real provider.** Reinvents guided-generation schemas, fragile, discards the `@Generable`/`@Guide` showcase.
- **C — tools only in the app target; kit holds metadata only.** Tool logic becomes untestable in the kit, metadata is duplicated across modules, and a cohesive feature is split.

**Testability boundary (important):** the mock cannot exercise the model's *tool-selection* decision (there is no model to choose). That is the framework's responsibility, not ours. We therefore test what we own:
- **Tool logic** — call `call(arguments:)` directly (deterministic; clock injected for DateTime).
- **Projection & accounting** — the mock scripts `.toolCall`/`.toolOutput` `ContextEntry`s so we assert the engine surfaces them in order and the budget includes tool-definition lines.

End-to-end tool selection is validated by **running** on a real Apple-Intelligence device/sim in the final milestone (as Plan 2 did for streaming).

---

## 4. Component design (`FoundationChatKit`)

### `CalculatorEngine` (new, pure) — `Tools/CalculatorEngine.swift`
The actual arithmetic, isolated from FoundationModels so it is trivially testable.
- `struct CalculatorEngine: Sendable { func evaluate(_ expression: String) throws -> Double }`
- Supports `+ - * /`, parentheses, decimals, unary minus; precedence-correct (shunting-yard or `NSExpression`-backed — implementer's choice, but must reject malformed input and divide-by-zero with a typed `CalculatorError`).
- **Depends on:** nothing.

### `CalculatorTool` — `Tools/CalculatorTool.swift`
```swift
struct CalculatorTool: Tool {
    let name = "calculator"
    let description = "Evaluate an arithmetic expression."
    @Generable struct Arguments {
        @Guide(description: "An arithmetic expression, e.g. (12.5/100)*80")
        var expression: String
    }
    func call(arguments: Arguments) async throws -> String { /* CalculatorEngine → formatted */ }
}
```
On malformed input, returns a short corrective string ("Couldn't evaluate '…'") so the model can recover, rather than throwing — keeps the chat resilient.

### `DateTimeTool` — `Tools/DateTimeTool.swift`
- `Arguments { @Guide(description:"IANA timezone, e.g. America/New_York; omit for device local") var timeZone: String? }`
- Holds an **injected `now: @Sendable () -> Date`** (default `Date.init`) so tests are deterministic. Formats with `Date.FormatStyle`. Unknown timezone → device local + a note.

### `UnitConverterTool` — `Tools/UnitConverterTool.swift`
- `Arguments { var value: Double; @Guide(.anyOf([...])) var from: Unit; @Guide(.anyOf([...])) var to: Unit }` where `Unit` is a `@Generable` enum covering a small, honest set (length: m/km/mi/ft; mass: kg/lb; temperature: C/F). Cross-dimension conversion (e.g. kg→mi) returns a corrective string.
- Pure conversion math; no `Measurement`-framework requirement (implementer may use `Measurement`/`UnitConverter` if cleaner).

### `Toolbox` — `Tools/Toolbox.swift`
- `enum Toolbox { static func defaultTools(now: @Sendable @escaping () -> Date = Date.init) -> [any Tool] }` → the three tools.
- `static func accountingMetadata(for tools: [any Tool]) -> [ToolAccounting]` where `ToolAccounting = (name: String, schemaDigest: String)` and `schemaDigest = name + description + compact rendering of parameters` — the string the token estimator counts. (Exact 26.4+ counting via `tokenCount(for: parameters)` is Plan 4.)
- **Depends on:** the three tools.

### `ConversationTitler` — `Tools/ConversationTitler.swift` (real-provider-side)
Encapsulates the `@Generable ConversationTitle` and the throwaway-session guided generation so generics never enter the seam. Used by `FoundationModelProvider.generateTitle`.

### Modified: `ConversationEngine`
- New init param `tools: [any Tool] = []`; passes them to `provider.makeSession(...)`; stores accounting metadata for the budget.
- `recomputeBudget` passes `tools` accounting into the calculator.
- `handle(_:)` maps `.toolFailed` (already-mapped at the provider) to `lastError`.
- Streaming loop, cancel, overflow recovery: **unchanged** (tool entries arrive via `contextEntries`).

### Modified: `TokenBudgetCalculator`
- `snapshot(maxTokens:instructions:entries:inFlight:tools:exactCount:)` — new `tools: [ToolAccounting]`. For each, add a `BudgetLine(label: "Tool: \(name)", tokens: count(schemaDigest))` **before** the entry lines. `used` still equals the sum of all lines; honesty flag unchanged.

### Modified: `ChatModelProvider` / `ChatSessionHandle` (the seam)
```swift
func makeSession(settings: GenerationSettings, tools: [any Tool], restoring encodedTranscript: Data?) -> any ChatSessionHandle
func makeSession(settings: GenerationSettings, tools: [any Tool], seeding entries: [ContextEntry]) -> any ChatSessionHandle
func generateTitle(forFirstExchange exchange: TitleSeed) async -> String?   // nil = fall back to deterministic
```
- `tools` defaulted to `[]` so existing call sites/tests compile unchanged where possible (the engine will pass them explicitly).
- `TitleSeed` = `(userText: String, assistantText: String)` (a tiny value type), so the title prompt is built provider-side.
- **Real provider:** registers tools via `LanguageModelSession(tools:instructions:)` on **both** overloads (overflow-recovered sessions keep their tools). `generateTitle` runs a transient `LanguageModelSession()` + `respond(to:generating: ConversationTitle.self)`; returns `nil` on any throw or when unavailable.
- **Mock:** accepts/ignores `tools` for execution; `generateTitle` returns a scripted optional. Adds optional scripted tool interactions (see §7).

### Modified: `TranscriptMapping`
- Render tool-call arguments as compact JSON: `"\(toolName)(\(jsonArgs))"` instead of `String(describing:)`, so the inspector shows readable structured args.

### Modified: `ChatError`
- Add `case toolFailed(tool: String, message: String?)`. (Also wire the previously-declared-but-unused `.modelUnavailable` and `.cancelled` into the banner.)

### Modified: `ChatCoordinator`
- Owns the tool set: `Toolbox.defaultTools()` injected into every `makeEngine`.
- After the **first** completed exchange of a conversation, calls `provider.generateTitle(forFirstExchange:)`; on a non-nil result, persists it via the store; otherwise the deterministic title stands. Subsequent turns don't regenerate the title.

### Modified: `ConversationStore`
- Add `func setTitle(_ title: String, for conversation: Conversation)` (also reused by Plan 4's manual rename). Existing deterministic-title behavior on first `appendMessage` stays as the fallback baseline.

---

## 5. Data model & persistence
**No schema change.** Titles still live on `Conversation.title`; guided generation just produces a better value, persisted through the existing store. `transcriptData`/resume logic is unchanged (a restored session re-registers the same tools, so tool defs remain available after resume).

---

## 6. Token budgeting (the "Tokens" tab)
- New breakdown lines: one **`Tool: <name>`** per registered tool, summed into `used` alongside instructions/prompts/responses/tool-usage entries.
- Honestly **estimated** in Plan 3 (char estimator); the `isExact` flag already reflects this. Plan 4 upgrades tool-schema counting to exact on 26.4+.
- Zones/gauge/approaching-limit banner unchanged — they simply reflect a (slightly higher) baseline now that tools occupy context. This makes the *cost of tools* visible, which is exactly the transparency angle.

---

## 7. Testing strategy (TDD)
Framework tests via `xcodebuild ... -scheme FoundationChatKit -destination 'platform=macOS' test`.

- **`CalculatorEngineTests`** — precedence, parentheses, decimals, unary minus, divide-by-zero → throws, malformed → throws.
- **`CalculatorToolTests`** — valid expression → formatted result; malformed → corrective string (no throw).
- **`DateTimeToolTests`** — injected clock → deterministic formatted output; explicit timezone vs local; bad timezone → local + note.
- **`UnitConverterToolTests`** — km↔mi, C↔F, kg↔lb round-trips within tolerance; cross-dimension → corrective string.
- **`ToolboxTests`** — default set is the three tools; names unique; accounting digests non-empty.
- **`TokenBudgetCalculatorTests`** (extend) — tool lines present and summed; `used` == Σ lines; estimated path flagged.
- **`MockModelProvider`** (extend) — scriptable `toolInteractions: [(call: ContextEntry, output: ContextEntry)]` injected into `contextEntries` on finish; scripted `titleResult: String?`.
- **Engine/projection tests** — scripted tool interaction → `engine.contextEntries` contains `.toolCall` then `.toolOutput` in order; budget reflects tool-def lines.
- **Coordinator title tests** — first exchange triggers exactly one `generateTitle`; non-nil persists; nil → deterministic title retained; second turn doesn't re-title.
- **Regression** — all Plan 1/2 tests stay green (new params defaulted).

SwiftUI views (inspector polish, error banner) verified by **build** (macOS + iOS). Tool selection verified by **running** in Milestone G.

---

## 8. Error handling (additions to the Phase 1 matrix)
| Condition | Detection | UX |
|---|---|---|
| Tool threw | `LanguageModelSession.ToolCallError` → `ChatError.toolFailed(name, msg)` | Banner: "The '\(name)' tool failed. Try rephrasing." Keep input. |
| Tool soft-fail | tool returns corrective string | Model recovers; surfaced normally as tool output in the inspector |
| Title gen failed/unavailable | `generateTitle` returns `nil` | Silent fallback to deterministic first-6-words title |

---

## 9. UI & navigation
- **No new screens.** `ContextInspectorView` already renders `.toolCall`/`.toolOutput` rows; polish = formatted-JSON args + a distinct icon/label for tool rows.
- **Tokens tab** shows the new `Tool: <name>` lines automatically.
- **ErrorBanner** gains `.toolFailed` (and `.modelUnavailable`/`.cancelled`) copy.
- HIG, Dynamic Type, VoiceOver: tool rows get accessible labels ("Tool call: calculator").

---

## 10. File map
```
Targets/FoundationChatKit/Sources/
  Tools/CalculatorEngine.swift        # NEW (pure)
  Tools/CalculatorTool.swift          # NEW
  Tools/DateTimeTool.swift            # NEW
  Tools/UnitConverterTool.swift       # NEW
  Tools/Toolbox.swift                 # NEW (default set + accounting metadata)
  Tools/ConversationTitler.swift      # NEW (@Generable title; real-provider helper)
  Provider/ChatModelProvider.swift    # MODIFY: tools: param on makeSession ×2 + generateTitle + TitleSeed
  Provider/FoundationModelProvider.swift # MODIFY: register tools; implement generateTitle
  Provider/TranscriptMapping.swift    # MODIFY: JSON-rendered tool-call args
  Engine/ConversationEngine.swift     # MODIFY: tools param; budget wiring; toolFailed routing
  Tokens/TokenBudgetCalculator.swift  # MODIFY: tools accounting lines
  Model/ChatError.swift               # MODIFY: + toolFailed
  App/ChatCoordinator.swift           # MODIFY: inject tools; first-exchange titling
  Persistence/ConversationStore.swift # MODIFY: + setTitle(_:for:)
Targets/FoundationChatKit/Tests/
  CalculatorEngineTests.swift  CalculatorToolTests.swift  DateTimeToolTests.swift
  UnitConverterToolTests.swift  ToolboxTests.swift  ToolCallingEngineTests.swift
  ConversationTitlingTests.swift   (+ extend TokenBudgetCalculatorTests, MockModelProvider, ChatCoordinatorTests)
Targets/Ember/Sources/
  ContextInspectorView.swift          # MODIFY: tool-row polish
  ErrorBanner.swift                   # MODIFY: + toolFailed/modelUnavailable/cancelled copy
```

---

## 11. References
- Tool: https://developer.apple.com/documentation/foundationmodels/tool
- Expanding generation with tool calling: https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling
- `Tool.call(arguments:)`, `Tool.parameters`, `Tool.includesSchemaInInstructions`, `LanguageModelSession.ToolCallError`
- Guided generation: `Generable`, `@Guide`, `LanguageModelSession.respond(to:generating:)`, `GenerationSchema`
- TN3193 — context window (tool defs/inputs/outputs count): https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window
- WWDC25 286 (Meet), 301 (Deep dive — tools/guided gen), 259 (Code-along)

---

## 12. Self-review (author check)
- **Placeholders:** none (`TBD`/`TODO`-free).
- **Consistency:** seam `tools:` param appears on both `makeSession` overloads and is consumed by the engine + real provider + mock; `ToolAccounting`/`schemaDigest` defined once and used by both `Toolbox` and `TokenBudgetCalculator`; `generateTitle`/`TitleSeed` signature matches across protocol, real provider, mock, coordinator.
- **Scope:** single cohesive plan; exact async token counts + device tools + RAG explicitly deferred. No network/entitlement added (ethos intact).
- **Ambiguity:** calculator backend left to the implementer but the *contract* (precedence, divide-by-zero throws, malformed → corrective string) is explicit. Title generation is **inline after the first turn** (deterministic for tests); backgrounding it is a noted future option, not Plan 3.
- **Reuses existing rails:** transcript→`ContextEntry` mapping, `ContextEntryKind.toolCall/.toolOutput`, and budget labels already exist — Plan 3 adds definition accounting + polish rather than new plumbing.
