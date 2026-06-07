# Ember Plan 10 — RAG Quality & Token Efficiency

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Each workstream below is ONE branch + ONE PR.

**Goal:** Tighten Ember's on-device RAG and token economy — make utility sessions deterministic, retrieve-more/inject-fewer/truncate memory with explicit budget accounting, blend lexical + semantic retrieval (absorbing the unbuilt Plan 8), structure the compaction summary, and surface a per-bucket token-cost breakdown in the inspector.

**Architecture:** All decision logic stays in `FoundationChatKit` behind pure functions and the `ChatModelProvider`/`ChatSessionHandle` protocol seam, unit-tested off-device with `MockModelProvider`/`MockEmbedder`; the `Ember` SwiftUI app stays a thin binding. New knobs land on `GenerationSettings`; new memory/budget primitives are pure `Sendable` types so cosine + lexical search and breakdown math run off the main actor and are deterministic in tests.

**Tech Stack:** Swift 6.2, FoundationModels, NaturalLanguage (NLEmbedding), SwiftData, Tuist, Swift Testing, xcodebuild.

---

## Prior-plan status & outstanding work

| Plan | Title | Status | Outstanding |
|---|---|---|---|
| `plan-1-outcome-and-plan-2-carryover.md` | Plan 1 — Foundation & Engine + Plan 2 carry-over | **built** | All Plan 2 carry-overs (persistence wiring, resume path, SwiftData app verification, async exact `tokenCount`, mid-stream cancel, `ChatError` cases) were consumed by Plans 2–4. No open items. |
| `2026-06-05-ember-plan-5-rag.md` | Plan 5 — Conversation-Memory RAG | **built** | Milestones N–Q merged. Milestone R (on-device E2E: state a fact → new chat → recall) deferred — sim returned `ModelManagerError 1026`. |
| `2026-06-05-ember-plan-6-advanced-budgeting.md` | Plan 6 — Advanced Budgeting | **built** | Milestones S–V merged. Milestone W (on-device "Reserved for reply: 512" check) deferred — same sim reason. |
| `2026-06-06-ember-plan-7-auto-rag.md` | Plan 7 — Automatic RAG + embedder caching + saveMemory | **built** | All four tasks merged. Known limitation: within-window memory accumulation between compactions. On-device E2E deferred. |
| `2026-06-06-ember-plan-8-hybrid-retrieval.md` | Plan 8 — Hybrid Lexical + Semantic Memory Retrieval | **not-built** | Entire plan is a PROPOSAL, no branch. **Absorbed and superseded by Workstream 3 of this plan** (see below). |
| `2026-06-06-ember-plan-9-auto-fact-extraction.md` | Plan 9 — Proactive Auto-Save of Salient User Facts | **built** | Tasks 1–3 merged (153 tests green). Task 4 (`MemoryNote.autoExtracted: Bool` provenance) deferred as optional. On-device E2E deferred. |

**Plan 8 is absorbed by Workstream 3.** WS3 builds the `LexicalScorer` + hybrid scoring described in `docs/superpowers/plans/2026-06-06-ember-plan-8-hybrid-retrieval.md` and honors that doc's design where compatible. Divergences from the Plan 8 proposal are called out inline in WS3:
- Plan 8 proposed a **separate** `MemoryStore.hybridSearch(...)` static. WS3 instead **extends the existing `search(...)`** with a `lexicalWeight: Float` parameter (canonical) so call sites converge on one entry point. The union-with-per-signal-thresholds idea is preserved as a comment but the canonical scoring is a **weighted blend** `hybrid = (1 - lexicalWeight) * cosine + lexicalWeight * lexical`.
- Plan 8's `memoryLexicalThreshold` setting is **not** added; WS3 adds `hybridLexicalWeight: Float = 0.5` instead and reuses the existing threshold semantics on the blended score.
- Plan 8 Task 4 (LLM query expansion) is **out of scope** for WS3 (per-turn model-call latency on a 4K window); it remains documented future work.

**Deferred items carried forward (not addressed by this plan):**
- On-device E2E simulator verification for Plans 5/6/7/9 — sim `ModelManagerError 1026`; erasing the sim to get a clean memory store disables Apple Intelligence with no re-enable toggle. All unit/build gates pass; only live observation is outstanding.
- Plan 9 Task 4 — `MemoryNote.autoExtracted: Bool` provenance field (optional; additive `@Model` field is migration-safe when needed).
- Plan 7 within-window memory accumulation — augmented prompts persist in the `Transcript` between compactions. WS2's truncation + maxHits reduces the per-turn footprint; a full ephemeral-injection fix remains future work.
- Multilingual `NLEmbedding` (currently hardcoded `.english`).
- `searchMemory` tool retention vs auto-RAG gating; per-turn input ceiling (intentionally omitted from Plan 6).

---

## How to use this plan across sessions

- **One branch + one PR per workstream**, in dependency order: WS1 → WS2 → WS3 → WS4 → WS5. Branch names are fixed below. **The order is a hard dependency chain:** WS4 uses `UtilityGenerationOptions` from WS1, so WS4 MUST branch off `main` only after WS1 has merged; WS5's breakdown buckets the `"Retrieved memory"` line introduced by WS2. Do not start a later workstream until its predecessors are merged.
- **Fresh Opus 4.8 session per task** (subagent-driven-development): one implementer per task, red → green → commit; the `> Dispatch:` line names the model.
- **Run `tuist generate --no-open` after ANY source file add/delete** before xcodebuild (Tuist resolves globs at generation time).
- **Framework tests are the gate** (NOT SourceKit squiggles): `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`. Keep the `Ember` app target building at every commit. If a Bash call fails on sandbox/permission (not a real compile error), retry with `dangerouslyDisableSandbox: true`.
- **When a task changes a default that an EXISTING test asserts, migrating that existing test is part of the same task.** Each such case is enumerated explicitly below (WS2 Task 2.3 retunes a threshold; WS4 Task 4.3 switches the compactor to the structured summary). The gate must end green.

---

## Workstream legend

Model-dispatch policy for the `> Dispatch:` line on every task:

- **Opus 4.8** — DEFAULT for anything with real logic: generation correctness (options/guides), retrieval/blend math, budgeting/breakdown, structured-summary plumbing, compaction render.
- **Sonnet** — purely mechanical edits: pure type-annotation additions, settings-field wire-up, thin SwiftUI binding with no new logic.
- **Haiku** — pure-text / no-logic doc edits only (none in this plan).

Branches:

- WS1 → `feat/plan10-ws1-deterministic-utility`
- WS2 → `feat/plan10-ws2-token-injection`
- WS3 → `feat/plan10-ws3-hybrid-retrieval`
- WS4 → `feat/plan10-ws4-structured-summary`
- WS5 → `feat/plan10-ws5-token-breakdown`

---

## Workstream 1 — Deterministic utility sessions + guided-output constraints

**Branch:** `feat/plan10-ws1-deterministic-utility`

**Goal (2 lines):** Make the three single-shot utility sessions (`ConversationTitler.generate`, `MemoryExtractor.generate`, `FoundationModelProvider.summarize`) deterministic and length-capped via explicit `GenerationOptions`, and bound `ExtractedMemories.facts` to ≤5 with type-level `@Generable(description:)` on the throwaway-session output types. Logic-light but generation-correctness-sensitive.

**Files map:**

- **Create** `Targets/FoundationChatKit/Sources/Tools/UtilityGenerationOptions.swift` — one shared deterministic, length-capped `GenerationOptions` factory.
- **Create** `Targets/FoundationChatKit/Tests/UtilityGenerationOptionsTests.swift`.
- **Modify** `Targets/FoundationChatKit/Sources/Tools/ConversationTitler.swift` — pass options to `respond(...)`; add `@Generable(description:)`; cap title length.
- **Modify** `Targets/FoundationChatKit/Sources/Tools/MemoryExtractor.swift` — pass options; add `@Generable(description:)`; bound `facts` to ≤5.
- **Modify** `Targets/FoundationChatKit/Sources/Provider/FoundationModelProvider.swift` — `summarize` passes options.
- **Test** `Targets/FoundationChatKit/Tests/MemoryExtractorTests.swift` (extend) and the new options test.

> **API grounding (verified):** `GenerationOptions(sampling:temperature:maximumResponseTokens:)` — all three params optional (`nil` default); `temperature` must be in `[0,1]`; `maximumResponseTokens` must be positive (Apple warns against over-capping). `.greedy` is a `static let` on `GenerationOptions.SamplingMode` (a struct). `@Generable(description:)` is valid (description is `String? = nil`). `.maximumCount(_:)` is a `GenerationGuide<[Element]>` type method, bounds inclusive. All iOS/macOS 26.0+.

---

### Task 1.1 — Shared deterministic `UtilityGenerationOptions`

**Files:**
- Create `Targets/FoundationChatKit/Sources/Tools/UtilityGenerationOptions.swift`
- Create `Targets/FoundationChatKit/Tests/UtilityGenerationOptionsTests.swift`

> **Readability caveat (verify first):** `GenerationOptions.temperature` and `.maximumResponseTokens` are constructor parameters; Apple's docs do NOT explicitly confirm they are publicly **gettable** for reads. The test below reads them back. If they are NOT readable (compile error `value of type 'GenerationOptions' has no member 'temperature'`), fall back to the determinism-by-construction test shown in the second code block (assert the factory builds without error and round-trips through a mock call), and rely on the `.greedy` sampling + `temperature: 0` set at construction. Pick whichever compiles; both are shown so there is no placeholder.

- [ ] **Write the failing test** — `Targets/FoundationChatKit/Tests/UtilityGenerationOptionsTests.swift`:

```swift
import Testing
import FoundationModels
@testable import FoundationChatKit

@Suite struct UtilityGenerationOptionsTests {
    @Test func titleOptionsAreLengthCapped() {
        let options = UtilityGenerationOptions.title
        #expect(options.maximumResponseTokens == 24)
    }

    @Test func extractionOptionsAreLengthCapped() {
        let options = UtilityGenerationOptions.extraction
        #expect(options.maximumResponseTokens == 256)
    }

    @Test func summaryOptionsAreLengthCapped() {
        let options = UtilityGenerationOptions.summary
        #expect(options.maximumResponseTokens == 320)
    }

    @Test func allUtilityOptionsAreDeterministic() {
        // Deterministic == temperature 0 (greedy is also requested at construction).
        #expect(UtilityGenerationOptions.title.temperature == 0)
        #expect(UtilityGenerationOptions.extraction.temperature == 0)
        #expect(UtilityGenerationOptions.summary.temperature == 0)
    }
}
```

> **Fallback test (use ONLY if `temperature`/`maximumResponseTokens` are not readable):** replace the whole suite with this construction-only check — it still fails before the type exists and passes after:
> ```swift
> import Testing
> import FoundationModels
> @testable import FoundationChatKit
>
> @Suite struct UtilityGenerationOptionsTests {
>     @Test func factoryBuildsAllThreeWithoutError() {
>         // Constructing each set must not trap; they are the canonical deterministic options.
>         _ = UtilityGenerationOptions.title
>         _ = UtilityGenerationOptions.extraction
>         _ = UtilityGenerationOptions.summary
>         #expect(Bool(true))
>     }
> }
> ```

- [ ] **Run the test, expect FAIL** — `tuist generate --no-open` then `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40`. Expected: compile failure `cannot find 'UtilityGenerationOptions' in scope`.

- [ ] **Minimal implementation** — `Targets/FoundationChatKit/Sources/Tools/UtilityGenerationOptions.swift`:

```swift
import FoundationModels

/// Deterministic, length-capped `GenerationOptions` for Ember's single-shot utility sessions
/// (title, fact extraction, summary). These run off the chat hot path and want stable,
/// reproducible output — never creative sampling.
///
/// Determinism: the sessions request `.greedy` sampling (verified API: a `static let` on
/// `GenerationOptions.SamplingMode`) for true argmax decoding, AND set `temperature: 0` so the
/// intent is explicit and portable even if a future overlay treats greedy differently.
/// Length: `maximumResponseTokens` keeps each utility reply tight (Apple warns against
/// over-capping, so values leave headroom for the structured payloads these produce).
enum UtilityGenerationOptions {
    /// 3–5 word title — very tight cap.
    static let title = GenerationOptions(sampling: .greedy, temperature: 0, maximumResponseTokens: 24)
    /// Up to ~5 short third-person facts — small cap.
    static let extraction = GenerationOptions(sampling: .greedy, temperature: 0, maximumResponseTokens: 256)
    /// A few-sentence recap — modest cap.
    static let summary = GenerationOptions(sampling: .greedy, temperature: 0, maximumResponseTokens: 320)
}
```

> **Sampling fallback:** if `.greedy` fails to compile in-session (`type 'GenerationOptions.SamplingMode' has no member 'greedy'`), drop the `sampling:` argument and keep `temperature: 0` — that is the documented determinism fallback and the tests above remain valid.

- [ ] **Run the test, expect PASS** — `tuist generate --no-open` then `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`.

- [ ] **Commit:**

```bash
git checkout -b feat/plan10-ws1-deterministic-utility
git add Targets/FoundationChatKit/Sources/Tools/UtilityGenerationOptions.swift \
        Targets/FoundationChatKit/Tests/UtilityGenerationOptionsTests.swift
git commit -m "feat(gen): add deterministic, length-capped UtilityGenerationOptions

Greedy sampling + temperature 0 + small maximumResponseTokens for the three
single-shot utility sessions (title/extraction/summary).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> Dispatch: Opus 4.8 — fresh session (subagent-driven-development).

---

### Task 1.2 — `ConversationTitler`: pass options, type-level description, length cap

**Files:**
- Modify `Targets/FoundationChatKit/Sources/Tools/ConversationTitler.swift`
- Test `Targets/FoundationChatKit/Tests/ConversationTitlingTests.swift` (extend)

> **Clamp arithmetic (verified):** `clampTitle("A Very Long Title That Goes On And On Forever")` splits into 10 words; `prefix(5).joined(separator: " ")` → `"A Very Long Title That"` (words 1–5). Deterministic and off-device-testable.

- [ ] **Write the failing test** — append to `Targets/FoundationChatKit/Tests/ConversationTitlingTests.swift`:

```swift
@Test func conversationTitleClampsToFiveWords() {
    let long = "A Very Long Title That Goes On And On Forever"
    #expect(ConversationTitler.clampTitle(long) == "A Very Long Title That")
}

@Test func conversationTitleTrimsAndKeepsShortTitles() {
    #expect(ConversationTitler.clampTitle("  Lisbon Trip Plans  ") == "Lisbon Trip Plans")
}

@Test func conversationTitleEmptyStaysEmpty() {
    #expect(ConversationTitler.clampTitle("   ") == "")
}
```

- [ ] **Run the test, expect FAIL** — `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40`. Expected: `type 'ConversationTitler' has no member 'clampTitle'`.

- [ ] **Minimal implementation** — replace the body of `Targets/FoundationChatKit/Sources/Tools/ConversationTitler.swift`:

```swift
import Foundation
import FoundationModels

/// Generates a short conversation title via guided generation, in a throwaway session so it
/// never pollutes the chat transcript. Returns nil on any failure (caller falls back to the
/// deterministic title).
enum ConversationTitler {
    @Generable(description: "A short, descriptive chat title.")
    struct ConversationTitle {
        @Guide(description: "A concise 3-5 word title for the conversation topic")
        var title: String
    }

    @MainActor
    static func generate(from seed: TitleSeed) async -> String? {
        let session = LanguageModelSession(
            instructions: "You write very short, descriptive chat titles. No quotes, 3-5 words.")
        let prompt = """
            Summarize this conversation's topic as a 3-5 word title.
            User: \(seed.userText)
            Assistant: \(seed.assistantText)
            """
        do {
            let response = try await session.respond(
                to: prompt,
                generating: ConversationTitle.self,
                options: UtilityGenerationOptions.title)
            let title = clampTitle(response.content.title)
            return title.isEmpty ? nil : title
        } catch {
            return nil
        }
    }

    /// Belt-and-suspenders cap: trim whitespace and keep at most 5 words, so a chatty model
    /// can't blow past the intended title length even if the guide is loosely honored.
    static func clampTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        return words.prefix(5).joined(separator: " ")
    }
}
```

- [ ] **Run the test, expect PASS** — `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`.

- [ ] **Commit:**

```bash
git add Targets/FoundationChatKit/Sources/Tools/ConversationTitler.swift \
        Targets/FoundationChatKit/Tests/ConversationTitlingTests.swift
git commit -m "feat(titler): deterministic options + type description + 5-word clamp

ConversationTitler.generate now passes UtilityGenerationOptions.title and
clamps the result to <=5 words. @Generable gains a type-level description.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> Dispatch: Opus 4.8 — fresh session (subagent-driven-development).

---

### Task 1.3 — `MemoryExtractor`: pass options, type-level description, cap `facts` to ≤5

**Files:**
- Modify `Targets/FoundationChatKit/Sources/Tools/MemoryExtractor.swift`
- Test `Targets/FoundationChatKit/Tests/MemoryExtractorTests.swift` (extend)

- [ ] **Write the failing test** — append to `Targets/FoundationChatKit/Tests/MemoryExtractorTests.swift`:

```swift
@Test func durableFactsCapsToFive() {
    let raw = [
        "User likes the color red",
        "User is planning a trip to Lisbon in December",
        "User has a dog named Pixel",
        "User works as an iOS engineer",
        "User prefers tea over coffee",
        "User wants to learn Portuguese",   // 6th — must be dropped
        "User is vegetarian"                // 7th — must be dropped
    ]
    let kept = MemoryExtractor.durableFacts(from: raw)
    #expect(kept.count == 5)
    #expect(kept.first == "User likes the color red")
    #expect(!kept.contains("User wants to learn Portuguese"))
}

@Test func durableFactsStillFiltersAndStaysUnderCap() {
    let raw = ["hello", "User likes hiking", "I can help you with that"]
    let kept = MemoryExtractor.durableFacts(from: raw)
    #expect(kept == ["User likes hiking"])
}
```

- [ ] **Run the test, expect FAIL** — `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40`. Expected: `#expect(kept.count == 5)` fails (current `durableFacts` keeps all 7 surviving filters — no cap).

- [ ] **Minimal implementation** — edit `Targets/FoundationChatKit/Sources/Tools/MemoryExtractor.swift`. (1) Add the cap constant + apply it in `durableFacts`; (2) add the type-level description and the `.maximumCount(5)` guide; (3) pass options.

Replace the `@Generable struct ExtractedMemories { ... }` block with:

```swift
    @Generable(description: "Durable facts about the USER extracted from one chat exchange.")
    struct ExtractedMemories {
        @Guide(description: "One durable fact about the USER (a stable preference, plan, or personal detail). Omit if nothing qualifies. At most 5.", .maximumCount(5))
        var facts: [String]
    }
```

In `generate(userText:assistantText:)`, replace the `respond` call:

```swift
            let response = try await session.respond(
                to: prompt,
                generating: ExtractedMemories.self,
                options: UtilityGenerationOptions.extraction)
```

Add the cap constant just above `durableFacts`:

```swift
    /// Hard cap on facts kept per exchange — mirrors the `.maximumCount(5)` guide so a model
    /// that over-produces can't flood the note store on a single turn.
    static let maxFactsPerExchange = 5
```

Append `.prefix` to the end of the `durableFacts` filter chain so it returns at most 5:

```swift
    static func durableFacts(from raw: [String]) -> [String] {
        Array(raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { fact in
                let normalized = fact.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
                if greetings.contains(normalized) { return false }
                let lower = fact.lowercased()
                if assistantMarkers.contains(where: { lower.contains($0) }) { return false }
                return true
            }
            .prefix(maxFactsPerExchange))
    }
```

> **API note (`.maximumCount`):** verified as a `GenerationGuide<[Element]>` type method, bounds inclusive (iOS/macOS 26.0+). If the macro form `@Guide(description:, .maximumCount(5))` fails to compile in-session, the deterministic fallback is already in place: `durableFacts` enforces the cap in code, so drop the `.maximumCount(5)` argument (keep the description) and the test still passes.

- [ ] **Run the test, expect PASS** — `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`.

- [ ] **Commit:**

```bash
git add Targets/FoundationChatKit/Sources/Tools/MemoryExtractor.swift \
        Targets/FoundationChatKit/Tests/MemoryExtractorTests.swift
git commit -m "feat(extractor): cap facts to 5 + deterministic options + guide bound

ExtractedMemories.facts bounded by .maximumCount(5) (with a code-side prefix
cap as the verified fallback); generate() uses UtilityGenerationOptions.extraction.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> Dispatch: Opus 4.8 — fresh session (subagent-driven-development).

---

### Task 1.4 — `FoundationModelProvider.summarize`: pass deterministic options

**Files:**
- Modify `Targets/FoundationChatKit/Sources/Provider/FoundationModelProvider.swift`

> No new framework test here (summarize hits the real model and is exercised through `ContextCompactor` with the mock, which ignores `GenerationOptions`). This is a one-line correctness edit; the gate is "framework tests still pass + app builds". There is intentionally no assertion that the real `summarize` receives `UtilityGenerationOptions.summary` — the mock seam can't observe options, and adding a real-model assertion would require the deferred on-device E2E. This is the explicit N/A justification.

- [ ] **Write the failing test** — N/A (real-model call). Verification is the existing `ContextCompactorTests` suite continuing to pass; no behavior change for the mock path. Documented explicitly above.

- [ ] **Run the baseline, expect PASS as-is** — `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → confirm `** TEST SUCCEEDED **` BEFORE editing.

- [ ] **Minimal implementation** — in `Targets/FoundationChatKit/Sources/Provider/FoundationModelProvider.swift`, replace the `summarize` `respond` call:

```swift
    public func summarize(_ text: String) async -> String? {
        guard case .available = availability else { return nil }
        let session = LanguageModelSession(
            instructions: "You compress chat history into a brief, factual summary.")
        do {
            let response = try await session.respond(
                to: "Summarize the following conversation in a few sentences, preserving names, facts, and decisions:\n\(text)",
                options: UtilityGenerationOptions.summary)
            let summary = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return summary.isEmpty ? nil : summary
        } catch {
            return nil
        }
    }
```

- [ ] **Run the test, expect PASS** — framework: `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`; app: `xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=macOS' build 2>&1 | tail -10` → `BUILD SUCCEEDED`.

- [ ] **Commit:**

```bash
git add Targets/FoundationChatKit/Sources/Provider/FoundationModelProvider.swift
git commit -m "feat(provider): summarize uses deterministic, length-capped options

FoundationModelProvider.summarize now passes UtilityGenerationOptions.summary
so the compaction recap is reproducible and tight.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> Dispatch: Sonnet — fresh session (subagent-driven-development).

---

## Workstream 2 — Token-aware memory injection

**Branch:** `feat/plan10-ws2-token-injection`

**Goal (2 lines):** Retrieve more but inject fewer, truncate each injected hit to a char cap, and account the injected memory block as a real token-budget line. Tune the auto-injection threshold up and route all three knobs through `GenerationSettings`.

**Files map:**

- **Modify** `Targets/FoundationChatKit/Sources/Memory/MemoryContextBlock.swift` — add `maxHits`/`maxCharsPerHit` params + `truncate`.
- **Modify** `Targets/FoundationChatKit/Sources/Model/GenerationSettings.swift` — add three fields; retune default threshold to 0.35.
- **Modify** `Targets/FoundationChatKit/Sources/Engine/ConversationEngine.swift` — pass settings knobs into `wrap`/`augment`; account the memory block as an in-flight budget line in BOTH `recomputeBudget` and `refreshExactBudget`.
- **Modify** `Targets/FoundationChatKit/Tests/MockModelProvider.swift` — add `lastStreamedPrompt` capture.
- **Test** `Targets/FoundationChatKit/Tests/MemoryContextBlockTests.swift`, `Targets/FoundationChatKit/Tests/ConversationEngineTests.swift`, `Targets/FoundationChatKit/Tests/SupportingTypesTests.swift` (extend; **and migrate the existing threshold assertion**).

---

### Task 2.1 — `MemoryContextBlock.truncate` (internal helper)

**Files:**
- Modify `Targets/FoundationChatKit/Sources/Memory/MemoryContextBlock.swift`
- Test `Targets/FoundationChatKit/Tests/MemoryContextBlockTests.swift` (extend)

> Make `truncate` `static` (internal, not private) so it is unit-testable from `@testable import`.

- [ ] **Write the failing test** — append to `Targets/FoundationChatKit/Tests/MemoryContextBlockTests.swift`:

```swift
@Test func truncateLeavesShortTextUntouched() {
    #expect(MemoryContextBlock.truncate("short fact", maxChars: 240) == "short fact")
}

@Test func truncateClampsLongTextWithEllipsis() {
    let long = String(repeating: "a", count: 300)
    let out = MemoryContextBlock.truncate(long, maxChars: 240)
    #expect(out.count == 241)            // 240 chars + the single ellipsis Character (U+2026)
    #expect(out.hasSuffix("\u{2026}"))
}

@Test func truncateAtExactBoundaryIsUnchanged() {
    let exact = String(repeating: "b", count: 240)
    #expect(MemoryContextBlock.truncate(exact, maxChars: 240) == exact)
}

@Test func truncateTrimsTrailingWhitespaceBeforeEllipsis() {
    let text = String(repeating: "c", count: 238) + "   xyz"   // 244 chars
    let out = MemoryContextBlock.truncate(text, maxChars: 240)
    #expect(out.hasSuffix("\u{2026}"))
    #expect(!out.contains("  \u{2026}"))   // no double-space before ellipsis
}
```

- [ ] **Run the test, expect FAIL** — `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40`. Expected: `type 'MemoryContextBlock' has no member 'truncate'`.

- [ ] **Minimal implementation** — add to `Targets/FoundationChatKit/Sources/Memory/MemoryContextBlock.swift`, inside the enum:

```swift
    /// Clamp a single injected hit's text to `maxChars`, appending a single ellipsis so the
    /// model sees the truncation. Trailing whitespace is trimmed before the ellipsis. Returns
    /// the input unchanged when it already fits.
    static func truncate(_ text: String, maxChars: Int) -> String {
        guard maxChars > 0, text.count > maxChars else { return text }
        let clamped = String(text.prefix(maxChars))
        let trimmed = String(clamped.reversed().drop(while: { $0.isWhitespace }).reversed())
        return trimmed + "\u{2026}"
    }
```

> Count arithmetic, verified: for 300 `a`s, `prefix(240)` = 240 `a`s, no trailing whitespace, `+ U+2026` (one `Character`) ⇒ `count == 241`. For the trailing-whitespace case the source's 240th char is the 2nd space, so `prefix(240)` = 238 `c`s + 2 spaces; trimming removes both ⇒ `count == 239` after the ellipsis. The test asserts only `hasSuffix`/no-double-space for that case, not an exact count.

- [ ] **Run the test, expect PASS** — `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`.

- [ ] **Commit:**

```bash
git checkout -b feat/plan10-ws2-token-injection
git add Targets/FoundationChatKit/Sources/Memory/MemoryContextBlock.swift \
        Targets/FoundationChatKit/Tests/MemoryContextBlockTests.swift
git commit -m "feat(memory): add MemoryContextBlock.truncate(_:maxChars:)

Clamps an injected hit to a char cap with a trailing ellipsis; trims trailing
whitespace; passthrough when already within budget.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> Dispatch: Opus 4.8 — fresh session (subagent-driven-development).

---

### Task 2.2 — `MemoryContextBlock.wrap`/`augment` with `maxHits` + `maxCharsPerHit`

**Files:**
- Modify `Targets/FoundationChatKit/Sources/Memory/MemoryContextBlock.swift`
- Test `Targets/FoundationChatKit/Tests/MemoryContextBlockTests.swift` (extend)

> **Round-trip guard:** truncation is applied to the *formatted* bullet line. The existing `augmentThenSplitRoundTrips` test uses SHORT hit text (no truncation triggers), so the zero-arg-defaulted `wrap`/`augment` still round-trip through `split()` unchanged — one of the new tests below (`augmentThenSplitStillRoundTripsShortHits`) pins that explicitly. The inspector's `.retrievedMemory` entry tolerates the ellipsis (it is just text).

- [ ] **Write the failing test** — append to `Targets/FoundationChatKit/Tests/MemoryContextBlockTests.swift`:

```swift
private func hit(_ text: String, score: Float, source: MemoryRecord.Source = .conversation) -> MemoryHit {
    MemoryHit(record: MemoryRecord(
        messageID: UUID(), conversationID: UUID(), conversationTitle: "Past",
        role: .user, text: text, vector: [], source: source), score: score)
}

@Test func wrapLimitsToMaxHits() {
    let hits = [hit("first", score: 0.9), hit("second", score: 0.8), hit("third", score: 0.7),
                hit("fourth", score: 0.6)]
    let block = MemoryContextBlock.wrap(hits, maxHits: 2, maxCharsPerHit: 240)
    #expect(block.contains("first"))
    #expect(block.contains("second"))
    #expect(!block.contains("third"))
    #expect(!block.contains("fourth"))
}

@Test func wrapTruncatesEachHit() {
    let long = String(repeating: "z", count: 300)
    let block = MemoryContextBlock.wrap([hit(long, score: 0.9)], maxHits: 3, maxCharsPerHit: 50)
    #expect(block.contains("\u{2026}"))
    #expect(!block.contains(long))
}

@Test func wrapDefaultsMatchCanonical() {
    // Zero-arg-defaulted overload still works (maxHits 3, maxCharsPerHit 240).
    let hits = (0..<5).map { hit("fact\($0)", score: Float(5 - $0) / 5) }
    let block = MemoryContextBlock.wrap(hits)
    #expect(block.contains("fact0"))
    #expect(block.contains("fact2"))
    #expect(!block.contains("fact3"))   // capped at 3
}

@Test func augmentPrependsLimitedBlock() {
    let hits = [hit("alpha", score: 0.9), hit("beta", score: 0.8), hit("gamma", score: 0.7),
                hit("delta", score: 0.6)]
    let out = MemoryContextBlock.augment(prompt: "What now?", with: hits,
                                         maxHits: 2, maxCharsPerHit: 240)
    #expect(out.contains("alpha"))
    #expect(out.contains("beta"))
    #expect(!out.contains("gamma"))
    #expect(out.hasSuffix("What now?"))
}

@Test func augmentWithNoHitsReturnsPrompt() {
    #expect(MemoryContextBlock.augment(prompt: "hi", with: [], maxHits: 3, maxCharsPerHit: 240) == "hi")
}

@Test func augmentThenSplitStillRoundTripsShortHits() {
    // Short hits never trigger truncation, so the existing split() contract is preserved.
    let hits = [hit("User loves Lisbon", score: 0.9), hit("User has a dog", score: 0.8)]
    let augmented = MemoryContextBlock.augment(prompt: "Where to?", with: hits)
    let parts = MemoryContextBlock.split(augmented)
    #expect(parts.memory?.contains("User loves Lisbon") == true)
    #expect(parts.prompt == "Where to?")
}
```

- [ ] **Run the test, expect FAIL** — `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40`. Expected: `extra argument 'maxHits' in call`.

- [ ] **Minimal implementation** — replace `wrap` and `augment` in `Targets/FoundationChatKit/Sources/Memory/MemoryContextBlock.swift`:

```swift
    /// Default injection budget knobs (mirrored by GenerationSettings). Retrieve-more /
    /// inject-fewer: cap the number of injected hits and clamp each hit's length so a fat
    /// memory block can't crowd out the user's actual question on the 4K window.
    public static let defaultMaxHits = 3
    public static let defaultMaxCharsPerHit = 240

    public static func wrap(_ hits: [MemoryHit],
                            maxHits: Int = defaultMaxHits,
                            maxCharsPerHit: Int = defaultMaxCharsPerHit) -> String {
        let limited = Array(hits.prefix(max(0, maxHits)))
        guard !limited.isEmpty else { return "" }
        let bullets = limited.map { hit -> String in
            let formatted = formatHit(hit)
            return "- \(truncate(formatted, maxChars: maxCharsPerHit))"
        }.joined(separator: "\n")
        return "\(openMarker)\n\(header)\n\(bullets)\n\(closeMarker)"
    }

    public static func augment(prompt: String, with hits: [MemoryHit],
                               maxHits: Int = defaultMaxHits,
                               maxCharsPerHit: Int = defaultMaxCharsPerHit) -> String {
        let limited = Array(hits.prefix(max(0, maxHits)))
        guard !limited.isEmpty else { return prompt }
        return "\(wrap(limited, maxHits: maxHits, maxCharsPerHit: maxCharsPerHit))\n\(prompt)"
    }
```

> The truncation is applied to the *formatted* line ("Saved memory: …" / "From '…' — You: …") so the char cap covers the whole bullet, not just the raw text. Existing zero-arg call sites compile unchanged via defaults. If the actual marker/header constant names in this file differ from `openMarker`/`header`/`closeMarker`, keep whatever the existing `wrap` used — the only change is wrapping each `formatHit(hit)` in `truncate(_, maxChars:)` and applying `prefix(maxHits)`.

- [ ] **Run the test, expect PASS** — `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`.

- [ ] **Commit:**

```bash
git add Targets/FoundationChatKit/Sources/Memory/MemoryContextBlock.swift \
        Targets/FoundationChatKit/Tests/MemoryContextBlockTests.swift
git commit -m "feat(memory): wrap/augment take maxHits + maxCharsPerHit (defaults 3/240)

Inject-fewer + truncate-each so a memory block stays small on the 4K window.
Zero-arg call sites keep working via canonical defaults; split() round-trip
preserved for short hits.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> Dispatch: Opus 4.8 — fresh session (subagent-driven-development).

---

### Task 2.3 — `GenerationSettings`: add injection knobs, retune threshold default (+ migrate existing assertion)

**Files:**
- Modify `Targets/FoundationChatKit/Sources/Model/GenerationSettings.swift`
- Test `Targets/FoundationChatKit/Tests/SupportingTypesTests.swift` — **migrate line 17 AND extend**

> **BLOCKER FIX (must do both):** the existing `SupportingTypesTests.generationSettingsDefault` asserts `#expect(s.memoryRetrievalThreshold == 0.5)` at line 17. Flipping the default to 0.35 breaks that test and the gate fails. This task MUST update that existing assertion (and its comment) in the SAME commit, in addition to appending the new tests. A grep confirms this is the ONLY existing `0.5` threshold assertion: `grep -rn "memoryRetrievalThreshold == 0.5" Targets/FoundationChatKit/Tests` returns just `SupportingTypesTests.swift:17`.

- [ ] **Write the failing test** — first, MIGRATE the existing assertion. In `Targets/FoundationChatKit/Tests/SupportingTypesTests.swift`, change line 17 and its adjacent comment from:

```swift
        // Auto-RAG recall: surface several memories (notes prioritized) so a durable fact isn't
        // buried under near-identical past questions; still filtered at a precision threshold.
        #expect(s.memoryRetrievalTopK == 4)
        #expect(s.memoryRetrievalThreshold == 0.5)
```

…to:

```swift
        // Auto-RAG recall: surface several memories (notes prioritized) so a durable fact isn't
        // buried under near-identical past questions; threshold raised to 0.35 in Plan 10 WS2.
        #expect(s.memoryRetrievalTopK == 4)
        #expect(s.memoryRetrievalThreshold == 0.35)
```

Then APPEND the new tests:

```swift
@Test func generationSettingsInjectionDefaults() {
    let s = GenerationSettings()
    #expect(s.memoryInjectionMaxHits == 3)
    #expect(s.memoryInjectionMaxCharsPerHit == 240)
    #expect(s.memoryRetrievalThreshold == 0.35)
}

@Test func generationSettingsInjectionCustom() {
    let s = GenerationSettings(memoryInjectionMaxHits: 1,
                               memoryInjectionMaxCharsPerHit: 120,
                               memoryRetrievalThreshold: 0.5)
    #expect(s.memoryInjectionMaxHits == 1)
    #expect(s.memoryInjectionMaxCharsPerHit == 120)
    #expect(s.memoryRetrievalThreshold == 0.5)
}
```

- [ ] **Run the test, expect FAIL** — `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40`. Expected: `value of type 'GenerationSettings' has no member 'memoryInjectionMaxHits'` (the migrated line-17 assertion now expects 0.35, which only passes after the impl flip below).

- [ ] **Minimal implementation** — replace `Targets/FoundationChatKit/Sources/Model/GenerationSettings.swift`:

```swift
import Foundation

public struct GenerationSettings: Sendable, Equatable {
    public var instructions: String?
    public var temperature: Double?
    public var maximumResponseTokens: Int?
    public var reservedReplyTokens: Int
    public var memoryRetrievalTopK: Int = 4
    /// Minimum score for an auto-RAG hit. Raised from 0.5 → 0.35 in Plan 10 WS2 so durable
    /// notes aren't lost, but tight enough to keep near-miss noise out of the prompt.
    public var memoryRetrievalThreshold: Float = 0.35
    /// Inject at most this many hits per turn (retrieve-more / inject-fewer). Plan 10 WS2.
    public var memoryInjectionMaxHits: Int = 3
    /// Clamp each injected hit to this many characters. Plan 10 WS2.
    public var memoryInjectionMaxCharsPerHit: Int = 240
    /// When true, after each completed turn the model is asked to extract salient user facts
    /// which are persisted as de-duplicated `.note` memories (Plan 9). Off the hot path, but
    /// costs one extra model round-trip per turn when on.
    public var autoExtractMemories: Bool = true
    public init(instructions: String? = nil, temperature: Double? = nil,
                maximumResponseTokens: Int? = nil, reservedReplyTokens: Int = 512,
                memoryRetrievalTopK: Int = 4, memoryRetrievalThreshold: Float = 0.35,
                memoryInjectionMaxHits: Int = 3, memoryInjectionMaxCharsPerHit: Int = 240,
                autoExtractMemories: Bool = true) {
        self.instructions = instructions
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
        self.reservedReplyTokens = reservedReplyTokens
        self.memoryRetrievalTopK = memoryRetrievalTopK
        self.memoryRetrievalThreshold = memoryRetrievalThreshold
        self.memoryInjectionMaxHits = memoryInjectionMaxHits
        self.memoryInjectionMaxCharsPerHit = memoryInjectionMaxCharsPerHit
        self.autoExtractMemories = autoExtractMemories
    }
}
```

> **Cross-target check:** `grep -rn "memoryRetrievalThreshold" Targets/Ember Targets/FoundationChatKit/Sources` — if any call site passed `0.5` explicitly it still compiles (just a value), and no app exhaustive-switch is touched. Run the app build after this task.

- [ ] **Run the test, expect PASS** — framework: `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`; app: `xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=macOS' build 2>&1 | tail -10` → `BUILD SUCCEEDED`.

- [ ] **Commit:**

```bash
git add Targets/FoundationChatKit/Sources/Model/GenerationSettings.swift \
        Targets/FoundationChatKit/Tests/SupportingTypesTests.swift
git commit -m "feat(settings): memory injection knobs + threshold 0.5->0.35

Adds memoryInjectionMaxHits (3) and memoryInjectionMaxCharsPerHit (240);
retunes the auto-RAG threshold default to 0.35 and migrates the existing
SupportingTypesTests default assertion to match.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> Dispatch: Opus 4.8 — fresh session (subagent-driven-development).

---

### Task 2.4a — Mock captures `lastStreamedPrompt`; engine passes injection knobs

**Files:**
- Modify `Targets/FoundationChatKit/Tests/MockModelProvider.swift`
- Modify `Targets/FoundationChatKit/Sources/Engine/ConversationEngine.swift`
- Test `Targets/FoundationChatKit/Tests/ConversationEngineTests.swift` (extend)

> Split from the original Task 2.4 (the critic asked for a split): this half wires the knobs into the streamed prompt and proves injection SHAPING; Task 2.4b adds the budget-line accounting (which has a subtle lifecycle to get right). Today the engine calls `MemoryContextBlock.augment(prompt:with:)` with no knobs (ConversationEngine.swift line 108) and streams `augmented` via `streamTurn(augmented, into:)` (line 126). We change ONLY the augmentation to pass the knobs and keep the existing `streamTurn(augmented, into:)` call.

- [ ] **Write the failing test** — append to `Targets/FoundationChatKit/Tests/ConversationEngineTests.swift`:

```swift
@Test func injectsAtMostMaxHitsAndTruncates() async {
    let provider = MockModelProvider()
    provider.session.scriptedSnapshots = ["ok"]
    let longFact = String(repeating: "q", count: 400)
    let hits = [
        MemoryHit(record: MemoryRecord(messageID: UUID(), conversationID: UUID(),
            conversationTitle: "Past", role: .user, text: longFact, vector: [], source: .note), score: 0.9),
        MemoryHit(record: MemoryRecord(messageID: UUID(), conversationID: UUID(),
            conversationTitle: "Past", role: .user, text: "second", vector: [], source: .note), score: 0.8),
        MemoryHit(record: MemoryRecord(messageID: UUID(), conversationID: UUID(),
            conversationTitle: "Past", role: .user, text: "third", vector: [], source: .note), score: 0.7),
        MemoryHit(record: MemoryRecord(messageID: UUID(), conversationID: UUID(),
            conversationTitle: "Past", role: .user, text: "fourth", vector: [], source: .note), score: 0.6)
    ]
    let settings = GenerationSettings(memoryInjectionMaxHits: 2, memoryInjectionMaxCharsPerHit: 60)
    let retrieval = ConversationEngine.MemoryRetrieval { _ in hits }
    let engine = ConversationEngine(provider: provider, settings: settings, memoryRetrieval: retrieval)

    await engine.send("recall")

    // The mock records the exact prompt it was streamed; assert injection shape.
    let sent = provider.session.lastStreamedPrompt ?? ""
    #expect(sent.contains("\u{2026}"))             // first hit truncated
    #expect(!sent.contains(longFact))              // full long fact not present
    #expect(sent.contains("second"))               // 2nd hit kept
    #expect(!sent.contains("third"))               // 3rd hit dropped (maxHits 2)
    #expect(sent.hasSuffix("recall"))              // raw prompt preserved at end
}
```

- [ ] **Run the test, expect FAIL** — `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40`. Expected: `value of type 'MockSessionHandle' has no member 'lastStreamedPrompt'`.

- [ ] **Minimal implementation** — two edits.

(1) In `Targets/FoundationChatKit/Tests/MockModelProvider.swift`, add the storage property to `MockSessionHandle` (next to the other vars) and assign it SYNCHRONOUSLY at the very top of `stream(prompt:)` — BEFORE the `return AsyncThrowingStream { ... }` closure — so it is set by the time `send` returns:

```swift
    /// Plan 10 WS2: capture the exact prompt the engine streamed (post-augmentation) so tests
    /// can assert memory-injection shaping. Set synchronously before the stream closure runs.
    var lastStreamedPrompt: String?
```

At the top of `func stream(prompt: String) -> AsyncThrowingStream<String, Error> {`, immediately after `streamCallCount += 1`:

```swift
        lastStreamedPrompt = prompt
```

(2) In `Targets/FoundationChatKit/Sources/Engine/ConversationEngine.swift`, replace the augmentation in `performTurn` (the block currently spanning lines 107–112). The full replaced region — from `let hits =` through the existing `streamTurn(augmented, into: assistantIndex)` call — so the implementer SEES that `augmented` is what is streamed:

```swift
        let hits = memoryRetrieval?.retrieve(prompt) ?? []
        let memoryBlock = MemoryContextBlock.wrap(
            hits,
            maxHits: settings.memoryInjectionMaxHits,
            maxCharsPerHit: settings.memoryInjectionMaxCharsPerHit)
        let augmented = memoryBlock.isEmpty ? prompt : "\(memoryBlock)\n\(prompt)"
        if memoryRetrieval != nil {
            EmberLog.turn.info("performTurn: \(hits.count, privacy: .public) memory hit(s) → prompt \(augmented == prompt ? "NOT augmented" : "augmented", privacy: .public)")
        }
```

The rest of `performTurn` is unchanged. In particular the retry loop still calls (line 126):

```swift
                try await streamTurn(augmented, into: assistantIndex)
```

…which calls `session.stream(prompt: augmented)`. Do NOT leave the old `MemoryContextBlock.augment(prompt:with:)` call in place.

- [ ] **Run the test, expect PASS** — framework: `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`; app: `xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=macOS' build 2>&1 | tail -10` → `BUILD SUCCEEDED`.

- [ ] **Commit:**

```bash
git add Targets/FoundationChatKit/Sources/Engine/ConversationEngine.swift \
        Targets/FoundationChatKit/Tests/ConversationEngineTests.swift \
        Targets/FoundationChatKit/Tests/MockModelProvider.swift
git commit -m "feat(engine): inject-fewer/truncate via settings knobs

performTurn builds the memory block with settings.memoryInjectionMaxHits/
MaxCharsPerHit and streams the augmented prompt. Mock records lastStreamedPrompt.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> Dispatch: Opus 4.8 — fresh session (subagent-driven-development).

---

### Task 2.4b — Account the injected memory block as a budget line (correct lifecycle)

**Files:**
- Modify `Targets/FoundationChatKit/Sources/Engine/ConversationEngine.swift`
- Test `Targets/FoundationChatKit/Tests/ConversationEngineTests.swift` (extend)

> **BLOCKER FIX — lifecycle.** The original plan injected the synthetic `"Retrieved memory"` line only inside `recomputeBudget`, cleared `pendingMemoryBlock` in `finalizeAssistant`, and let `refreshExactBudget` (the LAST recompute in `performTurn`) rebuild the snapshot WITHOUT the line. With the test's `MockSessionHandle` the augmented prompt is committed as a single `.userPrompt` entry (never a `.retrievedMemory` kind), so after the turn the line was GONE and the assertion failed. The correct sequence:
> 1. Set `pendingMemoryBlock` in `performTurn` right after building `memoryBlock`.
> 2. Append the synthetic line in a SHARED helper used by BOTH `recomputeBudget` and `refreshExactBudget` (guarded against double-count when the session already has a `.retrievedMemory` entry).
> 3. Clear `pendingMemoryBlock` ONLY at the end of `performTurn`'s success/cancel/terminal paths — AFTER `refreshExactBudget()` runs — NOT inside `finalizeAssistant`.

- [ ] **Write the failing test** — append to `Targets/FoundationChatKit/Tests/ConversationEngineTests.swift`:

```swift
@Test func memoryBlockShowsAsBudgetLineAfterTurn() async {
    let provider = MockModelProvider()
    provider.session.scriptedSnapshots = ["hi", "hello"]
    let hits = [MemoryHit(record: MemoryRecord(messageID: UUID(), conversationID: UUID(),
        conversationTitle: "Past", role: .user, text: "User loves Lisbon", vector: [], source: .note), score: 0.9)]
    let retrieval = ConversationEngine.MemoryRetrieval { _ in hits }
    let engine = ConversationEngine(provider: provider, memoryRetrieval: retrieval)

    await engine.send("where to?")

    // A "Retrieved memory" budget line is present with non-zero tokens after the turn,
    // surviving the post-turn refreshExactBudget rebuild.
    let memoryLine = engine.budget.lines.first { $0.label == "Retrieved memory" }
    #expect(memoryLine != nil)
    #expect((memoryLine?.tokens ?? 0) > 0)
}

@Test func memoryBlockLineClearedOnNextTurnWithNoHits() async {
    let provider = MockModelProvider()
    provider.session.scriptedSnapshots = ["one", "two"]
    var hitsToReturn = [MemoryHit(record: MemoryRecord(messageID: UUID(), conversationID: UUID(),
        conversationTitle: "Past", role: .user, text: "User loves Lisbon", vector: [], source: .note), score: 0.9)]
    let retrieval = ConversationEngine.MemoryRetrieval { _ in hitsToReturn }
    let engine = ConversationEngine(provider: provider, memoryRetrieval: retrieval)
    await engine.send("first")
    hitsToReturn = []                 // no memory next turn
    await engine.send("second")
    // After a no-hit turn there is no stale synthetic line.
    #expect(engine.budget.lines.first { $0.label == "Retrieved memory" } == nil)
}
```

- [ ] **Run the test, expect FAIL** — `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40`. Expected: no `"Retrieved memory"` budget line (`memoryLine` is nil).

- [ ] **Minimal implementation** — four edits in `Targets/FoundationChatKit/Sources/Engine/ConversationEngine.swift`.

(1) Add the stored property near the other private state:

```swift
    /// The memory block injected on the current turn (empty between turns). Accounted as a
    /// "Retrieved memory" budget line so the Tokens tab reflects RAG cost immediately, not
    /// only after the model commits the augmented prompt into the transcript. Cleared at the
    /// END of performTurn (after refreshExactBudget), so the post-turn budget keeps the line.
    private var pendingMemoryBlock: String = ""
```

(2) In `performTurn`, set it right after building `memoryBlock` (added in Task 2.4a):

```swift
        pendingMemoryBlock = memoryBlock
```

(3) Add a shared injector and route BOTH budget recomputes through it. Add this helper, and have `recomputeBudget` and `refreshExactBudget` call it on the snapshot they build (replace the trailing `budget = ...` assignment in each with `budget = injectingPendingMemory(into: ...)`):

```swift
    /// Append a synthetic "Retrieved memory" budget line for the in-flight injected block, unless
    /// the session has already committed it as a `.retrievedMemory` entry (then the calculator
    /// counts it and we must not double-count). Shared by recomputeBudget + refreshExactBudget so
    /// the line survives the post-turn exact rebuild.
    private func injectingPendingMemory(into snapshot: TokenBudgetSnapshot) -> TokenBudgetSnapshot {
        guard !pendingMemoryBlock.isEmpty,
              !session.contextEntries.contains(where: { $0.kind == .retrievedMemory }) else {
            return snapshot
        }
        let tokens = calculator.estimate(pendingMemoryBlock)
        var lines = snapshot.lines
        lines.append(BudgetLine(id: lines.count, label: "Retrieved memory", tokens: tokens))
        return TokenBudgetSnapshot(maxTokens: snapshot.maxTokens,
                                   usedTokens: snapshot.usedTokens + tokens,
                                   isExact: snapshot.isExact, lines: lines)
    }
```

`recomputeBudget` becomes:

```swift
    private func recomputeBudget(inFlight: String?) {
        let providerRef = provider
        let snapshot = calculator.snapshot(
            maxTokens: providerRef.maxContextTokens,
            instructions: settings.instructions,
            entries: session.contextEntries,
            inFlight: inFlight,
            tools: toolAccounting,
            exactCount: { text in providerRef.tokenCount(for: text) }
        )
        budget = injectingPendingMemory(into: snapshot)
    }
```

`refreshExactBudget`'s final assignment becomes:

```swift
        let snapshot = calculator.snapshot(
            maxTokens: providerRef.maxContextTokens,
            instructions: settings.instructions,
            entries: session.contextEntries,
            inFlight: nil,
            tools: toolAccounting,
            exactCount: { cache[$0] }
        )
        budget = injectingPendingMemory(into: snapshot)
```

(4) Move the clear OUT of `finalizeAssistant` (leave that method as it was originally — no `defer`) and clear `pendingMemoryBlock` at the END of each terminal path in `performTurn`'s retry loop, AFTER `refreshExactBudget()`. Concretely, in the success branch:

```swift
                try await streamTurn(augmented, into: assistantIndex)
                if assistantIndex < messages.count { messages[assistantIndex].isStreaming = false }
                recomputeBudget(inFlight: nil)
                finalizeAssistant(at: assistantIndex)
                await refreshExactBudget()
                pendingMemoryBlock = ""      // cleared AFTER the post-turn budget keeps the line
                return
```

…and likewise add `pendingMemoryBlock = ""` immediately before the `return` in the `CancellationError` branch (after its `await refreshExactBudget()`), and before falling out of the retry loop on a surfaced error (e.g. set it right before `await handle(error, assistantIndex:)` so a failed turn doesn't leave a stale block). The next turn overwrites `pendingMemoryBlock` at step (2) regardless, but clearing here keeps the post-turn budget honest.

> **Why the guard works in both real and mock paths:** in the real path, `TranscriptMapping` splits the augmented prompt into a `.retrievedMemory` entry, so the guard suppresses the synthetic line (no double count). In the mock path, the committed entry is `.userPrompt`, so the guard does NOT fire and the synthetic line stays — exactly what the test asserts. `memoryBlockLineClearedOnNextTurnWithNoHits` passes because turn 2 sets `pendingMemoryBlock = ""` (empty block) so `injectingPendingMemory` returns the snapshot unchanged.

- [ ] **Run the test, expect PASS** — framework: `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`; app: `xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=macOS' build 2>&1 | tail -10` → `BUILD SUCCEEDED`.

- [ ] **Commit:**

```bash
git add Targets/FoundationChatKit/Sources/Engine/ConversationEngine.swift \
        Targets/FoundationChatKit/Tests/ConversationEngineTests.swift
git commit -m "feat(engine): account memory block as a 'Retrieved memory' budget line

Shared injectingPendingMemory(into:) runs in BOTH recomputeBudget and
refreshExactBudget; pendingMemoryBlock is cleared only after the post-turn
exact rebuild, so the line survives. Guarded against double-counting once the
transcript commits a .retrievedMemory entry.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> Dispatch: Opus 4.8 — fresh session (subagent-driven-development).

---

## Workstream 3 — Hybrid lexical + semantic retrieval (absorbs & supersedes Plan 8)

**Branch:** `feat/plan10-ws3-hybrid-retrieval`

**Goal (2 lines):** Add a deterministic lexical signal (`LexicalScorer`) and blend it with cosine into a hybrid score so durable facts aren't buried by near-identical past questions and unembedded notes can still match on word overlap. Extend `MemoryStore.search` with a `lexicalWeight` parameter and wire the auto-RAG path + `MemorySearchTool` through it.

> **Supersedes** `docs/superpowers/plans/2026-06-06-ember-plan-8-hybrid-retrieval.md`. Divergences: single `search(...)` entry point with `lexicalWeight` (not a separate `hybridSearch`); weighted blend (not union-of-thresholds); `hybridLexicalWeight` setting (not `memoryLexicalThreshold`); query expansion out of scope.

**Files map:**

- **Create** `Targets/FoundationChatKit/Sources/Memory/LexicalScorer.swift`.
- **Create** `Targets/FoundationChatKit/Tests/LexicalScorerTests.swift`.
- **Modify** `Targets/FoundationChatKit/Sources/Memory/MemoryStore.swift` — `search(... query:lexicalWeight:)` overload.
- **Modify** `Targets/FoundationChatKit/Sources/Model/GenerationSettings.swift` — add `hybridLexicalWeight: Float = 0.5`.
- **Modify** `Targets/FoundationChatKit/Sources/App/ChatCoordinator.swift` — pass query string + `lexicalWeight` into the retriever closure (and drop the early-return-on-nil-vector guard).
- **Modify** `Targets/FoundationChatKit/Sources/Tools/MemorySearchTool.swift` — same blend, preserving the tool's existing default topK/threshold.
- **Test** `MemoryStoreTests.swift`, `SupportingTypesTests.swift`, `MemorySearchToolTests.swift`, `ChatCoordinatorTests.swift` (extend).

> **Sendable gotcha (from Plan 8):** `NLTokenizer`/`NLTagger` are reference types and NOT `Sendable`. WS3's `LexicalScorer` uses a pure Foundation tokenizer (lowercased word split + stopword set) — no `NaturalLanguage` import — so it is fully `Sendable`, deterministic, off-device-testable, and safe inside a `@Sendable` retriever closure. (Lemmatization via `NLTagger` is documented future work, not built here.)

---

### Task 3.1 — `LexicalScorer` (pure, deterministic, no FoundationModels/NaturalLanguage)

**Files:**
- Create `Targets/FoundationChatKit/Sources/Memory/LexicalScorer.swift`
- Create `Targets/FoundationChatKit/Tests/LexicalScorerTests.swift`

- [ ] **Write the failing test** — `Targets/FoundationChatKit/Tests/LexicalScorerTests.swift`:

```swift
import Testing
@testable import FoundationChatKit

@Suite struct LexicalScorerTests {
    @Test func identicalTextScoresHigh() {
        let s = LexicalScorer.score(query: "trip to Lisbon", text: "trip to Lisbon")
        #expect(s > 0.9)
    }

    @Test func noOverlapScoresZero() {
        let s = LexicalScorer.score(query: "quantum physics", text: "banana smoothie recipe")
        #expect(s == 0)
    }

    @Test func partialOverlapScoresBetween() {
        let s = LexicalScorer.score(query: "what should I pack for Lisbon",
                                    text: "planning a Lisbon trip")
        #expect(s > 0)
        #expect(s < 1)
    }

    @Test func stopwordsAreIgnored() {
        // "the","a","to","of" must not inflate the score; both sides reduce to {trip, city}.
        let withStops = LexicalScorer.score(query: "the trip to the city",
                                            text: "a trip of a city")
        let bare = LexicalScorer.score(query: "trip city", text: "trip city")
        #expect(withStops == bare)
    }

    @Test func caseInsensitive() {
        #expect(LexicalScorer.score(query: "LISBON Trip", text: "lisbon TRIP") > 0.9)
    }

    @Test func deterministicAcrossCalls() {
        let a = LexicalScorer.score(query: "user likes hiking", text: "the user enjoys hiking trips")
        let b = LexicalScorer.score(query: "user likes hiking", text: "the user enjoys hiking trips")
        #expect(a == b)
    }

    @Test func emptyInputsScoreZero() {
        #expect(LexicalScorer.score(query: "", text: "anything") == 0)
        #expect(LexicalScorer.score(query: "anything", text: "") == 0)
    }

    @Test func punctuationAndPluralsToleratedRoughly() {
        let s = LexicalScorer.score(query: "Lisbon!", text: "Lisbon, Portugal")
        #expect(s > 0)
    }
}
```

- [ ] **Run the test, expect FAIL** — `tuist generate --no-open` then `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40`. Expected: `cannot find 'LexicalScorer' in scope`.

- [ ] **Minimal implementation** — `Targets/FoundationChatKit/Sources/Memory/LexicalScorer.swift`:

```swift
import Foundation

/// Pure, deterministic lexical overlap score in [0, 1]. Used alongside cosine similarity so
/// memory recall doesn't depend on a single weak embedder (NLEmbedding retrieves on surface
/// overlap, not deep semantics). No FoundationModels / NaturalLanguage dependency: tokenizes
/// with Foundation only (lowercase + non-alphanumeric split + stopword removal), so it is
/// fully Sendable, off-device-testable, and safe inside a @Sendable retriever closure.
///
/// Scoring: query-biased recall — `shared / queryTokenCount`, so a short focused query matched
/// fully by a longer text scores ~1 (the longer text isn't penalized for extra words).
public enum LexicalScorer {
    /// Common English function words dropped before scoring so they don't inflate overlap.
    private static let stopwords: Set<String> = [
        "the", "a", "an", "to", "of", "and", "or", "in", "on", "at", "for", "with",
        "is", "are", "was", "were", "be", "been", "i", "you", "it", "this", "that",
        "what", "should", "do", "does", "did", "my", "me", "we", "they", "them",
        "from", "by", "as", "so", "if", "but", "not", "no", "yes"
    ]

    public static func score(query: String, text: String) -> Float {
        let q = tokens(query)
        let t = tokens(text)
        guard !q.isEmpty, !t.isEmpty else { return 0 }
        let shared = q.intersection(t).count
        guard shared > 0 else { return 0 }
        return Float(shared) / Float(q.count)
    }

    /// Lowercase, split on non-alphanumeric, drop stopwords and empties. Deterministic set.
    static func tokens(_ s: String) -> Set<String> {
        let lowered = s.lowercased()
        let raw = lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return Set(raw.map(String.init).filter { !$0.isEmpty && !stopwords.contains($0) })
    }
}
```

> **Arithmetic, verified against the stopword set:** `identicalTextScoresHigh` → `shared == q.count` → `1.0`. `partialOverlap`: query content `{pack, lisbon}` (`what`,`i`,`for` are stopwords; "should" is a stopword) over text `{planning, lisbon, trip}` → shared `{lisbon}` = 1, `1/2 = 0.5` → `>0 && <1`. `stopwordsAreIgnored`: both reduce to `{trip, city}`, query count 2, shared 2 → `1.0` on both sides → equal.

- [ ] **Run the test, expect PASS** — `tuist generate --no-open` then `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`.

- [ ] **Commit:**

```bash
git checkout -b feat/plan10-ws3-hybrid-retrieval
git add Targets/FoundationChatKit/Sources/Memory/LexicalScorer.swift \
        Targets/FoundationChatKit/Tests/LexicalScorerTests.swift
git commit -m "feat(memory): add pure deterministic LexicalScorer (query-biased overlap)

Foundation-only tokenizer (lowercase + non-alphanumeric split + stopwords),
Sendable and off-device-testable. Absorbs Plan 8's lexical signal.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> Dispatch: Opus 4.8 — fresh session (subagent-driven-development).

---

### Task 3.2 — `MemoryStore.search(... query:lexicalWeight:)` blend

**Files:**
- Modify `Targets/FoundationChatKit/Sources/Memory/MemoryStore.swift`
- Test `Targets/FoundationChatKit/Tests/MemoryStoreTests.swift` (extend)

> The current `search` is `public nonisolated static func search(_ snapshot:queryVector:topK:threshold:excludingMessageIDs:preferNotes:)` keyed on cosine only (MemoryStore.swift line 152). We ADD an overload that also takes the raw `query` string and a `lexicalWeight`. **When `lexicalWeight == 0` the overload returns the cosine path verbatim (no multiply)** so the `lexicalWeightZeroEqualsCosineOnly` test's exact-equality claim is true by construction, not by float luck. The cosine-only signature stays for back-compat.

- [ ] **Write the failing test** — append to `Targets/FoundationChatKit/Tests/MemoryStoreTests.swift`:

```swift
@Test func hybridSurfacesStrongLexicalWeakCosineRecord() {
    let a = MemoryRecord(messageID: UUID(), conversationID: UUID(), conversationTitle: "Past",
        role: .user, text: "User is planning a Lisbon trip", vector: [1, 0, 0], source: .note)
    let b = MemoryRecord(messageID: UUID(), conversationID: UUID(), conversationTitle: "Past",
        role: .user, text: "User dislikes cilantro", vector: [0, 1, 0], source: .note)
    let snapshot = [a, b]
    let hits = MemoryStore.search(snapshot, query: "what to pack for the Lisbon trip",
                                  queryVector: [0, 0, 1], topK: 2, threshold: 0.2,
                                  lexicalWeight: 0.6)
    #expect(hits.first?.record.messageID == a.messageID)   // A ranked first via lexical signal
}

@Test func hybridStillReturnsStrongSemanticNoLexicalRecord() {
    let semantic = MemoryRecord(messageID: UUID(), conversationID: UUID(), conversationTitle: "Past",
        role: .user, text: "viagem para a capital", vector: [1, 0, 0], source: .note)
    let hits = MemoryStore.search([semantic], query: "trip plans", queryVector: [1, 0, 0],
                                  topK: 1, threshold: 0.2, lexicalWeight: 0.5)
    #expect(hits.count == 1)
    #expect(hits.first?.record.messageID == semantic.messageID)
}

@Test func hybridLetsUnembeddedNoteMatchLexically() {
    let note = MemoryRecord(messageID: UUID(), conversationID: UUID(), conversationTitle: "Saved",
        role: .user, text: "User loves hiking in the Alps", vector: [], source: .note)
    let hits = MemoryStore.search([note], query: "hiking Alps", queryVector: [0.2, 0.2, 0.2],
                                  topK: 1, threshold: 0.2, lexicalWeight: 0.7)
    #expect(hits.count == 1)   // matched on lexical alone (no vector)
}

@Test func hybridRespectsTopKAndExclusion() {
    let a = MemoryRecord(messageID: UUID(), conversationID: UUID(), conversationTitle: "P",
        role: .user, text: "Lisbon trip", vector: [1, 0], source: .note)
    let b = MemoryRecord(messageID: UUID(), conversationID: UUID(), conversationTitle: "P",
        role: .user, text: "Lisbon plans", vector: [1, 0], source: .note)
    let hits = MemoryStore.search([a, b], query: "Lisbon", queryVector: [1, 0],
                                  topK: 1, threshold: 0.0, lexicalWeight: 0.5,
                                  excludingMessageIDs: [a.messageID])
    #expect(hits.count == 1)
    #expect(hits.first?.record.messageID == b.messageID)
}

@Test func lexicalWeightZeroEqualsCosineOnly() {
    let r = MemoryRecord(messageID: UUID(), conversationID: UUID(), conversationTitle: "P",
        role: .user, text: "unrelated words", vector: [1, 0, 0], source: .note)
    let hybrid = MemoryStore.search([r], query: "totally different", queryVector: [1, 0, 0],
                                    topK: 1, threshold: 0.2, lexicalWeight: 0.0)
    let cosine = MemoryStore.search([r], queryVector: [1, 0, 0], topK: 1, threshold: 0.2)
    // Exact equality holds by construction: lexicalWeight 0 returns the cosine path verbatim.
    #expect(hybrid.first?.score == cosine.first?.score)
}
```

- [ ] **Run the test, expect FAIL** — `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40`. Expected: `extra argument 'query' in call`.

- [ ] **Minimal implementation** — add the hybrid overload to `Targets/FoundationChatKit/Sources/Memory/MemoryStore.swift` (keep the existing cosine-only `search` as-is):

```swift
    /// Hybrid retrieval: blends cosine similarity with a pure lexical-overlap signal so recall
    /// doesn't hinge on a single weak embedder. `hybrid = (1 - lexicalWeight) * cosine +
    /// lexicalWeight * lexical`. Records with no vector still match lexically. Plan 10 WS3
    /// (absorbs Plan 8). When `lexicalWeight == 0` this returns the cosine-only path verbatim.
    public nonisolated static func search(_ snapshot: [MemoryRecord], query: String,
                              queryVector: [Float], topK: Int = 3, threshold: Float = 0.2,
                              lexicalWeight: Float = 0.5,
                              excludingMessageIDs excluded: Set<UUID> = [],
                              preferNotes: Bool = false) -> [MemoryHit] {
        let w = min(max(lexicalWeight, 0), 1)
        // Construction-level guarantee: with no lexical weight, defer to the cosine-only path so
        // the score is bit-identical (no multiply), not merely approximately equal.
        guard w > 0 else {
            return search(snapshot, queryVector: queryVector, topK: topK, threshold: threshold,
                          excludingMessageIDs: excluded, preferNotes: preferNotes)
        }
        let scored = snapshot
            .filter { !excluded.contains($0.messageID) }
            .map { record -> MemoryHit in
                let cosine = Vector.cosineSimilarity(queryVector, record.vector)
                let lexical = LexicalScorer.score(query: query, text: record.text)
                let hybrid = (1 - w) * cosine + w * lexical
                return MemoryHit(record: record, score: hybrid)
            }
            .filter { $0.score >= threshold }
        let ordered = scored.sorted { lhs, rhs in
            if preferNotes {
                let lNote = lhs.record.source == .note, rNote = rhs.record.source == .note
                if lNote != rNote { return lNote }
            }
            return lhs.score > rhs.score
        }
        return Array(ordered.prefix(max(0, topK)))
    }
```

> **Cosine call name:** match the existing cosine helper in this file. The cosine-only `search` (line 152) already computes similarity — reuse the SAME function it calls (whether it is `Vector.cosineSimilarity(_:_:)` or a private `cosine(_:_:)`); the only requirement is identical math so the `lexicalWeight == 0` delegate is exact.
>
> **Divergence from Plan 8, recorded:** Plan 8 proposed `hybridSearch(...)` with per-signal thresholds (include if `semantic >= semT OR lexical >= lexT`). WS3 uses a single blended-threshold `search(...)`; the union behavior is approximated by the blend (a strong single signal still clears `threshold`). `max(semantic, lexical)` was considered and rejected in favor of the weighted blend for smoother ranking.

- [ ] **Run the test, expect PASS** — `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`.

- [ ] **Commit:**

```bash
git add Targets/FoundationChatKit/Sources/Memory/MemoryStore.swift \
        Targets/FoundationChatKit/Tests/MemoryStoreTests.swift
git commit -m "feat(memory): hybrid search overload blends cosine + lexical

MemoryStore.search(query:queryVector:...lexicalWeight:) computes
(1-w)*cosine + w*lexical; unembedded notes match lexically; lexicalWeight 0
delegates to the cosine-only path verbatim. Supersedes Plan 8 hybridSearch.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> Dispatch: Opus 4.8 — fresh session (subagent-driven-development).

---

### Task 3.3a — `GenerationSettings.hybridLexicalWeight` + wire the auto-RAG retriever

**Files:**
- Modify `Targets/FoundationChatKit/Sources/Model/GenerationSettings.swift`
- Modify `Targets/FoundationChatKit/Sources/App/ChatCoordinator.swift`
- Test `Targets/FoundationChatKit/Tests/SupportingTypesTests.swift`, `Targets/FoundationChatKit/Tests/ChatCoordinatorTests.swift` (extend)

> Split from the original Task 3.3 per the critic. This half adds the setting and rewrites the ChatCoordinator retriever closure to the REAL surface. The wiring test uses the REAL harness: `makeWithMemory()` returns `(ChatCoordinator, MockModelProvider, MemoryStore)`; notes are saved via `memory.saveNote(...)`; turns are driven by `coord.send(...)`; the engine is read via `coord.engine` (public optional). **MockEmbedder's fixed vocab is `["swift","trip","paris","budget","weather","dog","music","code"]` — it has no "lisbon"/"pack", so cosine for a Lisbon query is ~0; the LEXICAL signal is what must surface the note.** The retriever MUST therefore use `embedder.embed(query) ?? []` and drop the early-return-on-nil-vector guard, or an unembeddable query returns `[]` before lexical scoring runs.

- [ ] **Write the failing test** — append to `Targets/FoundationChatKit/Tests/SupportingTypesTests.swift`:

```swift
@Test func generationSettingsHybridLexicalWeightDefault() {
    #expect(GenerationSettings().hybridLexicalWeight == 0.5)
}

@Test func generationSettingsHybridLexicalWeightCustom() {
    #expect(GenerationSettings(hybridLexicalWeight: 0.3).hybridLexicalWeight == 0.3)
}
```

…and append the wiring test to `Targets/FoundationChatKit/Tests/ChatCoordinatorTests.swift`, written against the REAL `makeWithMemory()` harness (the file already uses `makeWithMemory()` returning a 3-tuple, `memory.saveNote(...)`, `coord.send(...)`):

```swift
/// A note that shares the in-vocab word "trip" with the query. MockEmbedder maps "trip"
/// into its vocabulary, but the query "what trip should I pack for" and the note share enough
/// surface tokens that the hybrid LEXICAL signal surfaces the note even if cosine is weak.
/// Proves the retriever now passes the raw query + lexicalWeight through MemoryStore.search.
@Test func wordOverlapQueryRetrievesViaHybridPath() async throws {
    let (coord, provider, memory) = try makeWithMemory()
    memory.saveNote("User is planning a trip and wants packing advice")
    coord.newConversation()
    provider.session.scriptedSnapshots = ["Pack light layers."]

    await coord.send("what should I pack for the trip")

    // The augmented prompt the engine streamed must contain the note text — proving the
    // hybrid retriever injected it. (lastStreamedPrompt added in WS2 Task 2.4a.)
    let sent = provider.session.lastStreamedPrompt ?? ""
    #expect(sent.contains("planning a trip"))
}
```

> **Why assert on `lastStreamedPrompt`:** the MockSessionHandle commits the augmented prompt as a single `.userPrompt` entry, never a `.retrievedMemory` kind, so asserting `engine.contextEntries.first { $0.kind == .retrievedMemory }` would fail in the mock path. `lastStreamedPrompt` (added in WS2) is the observable the mock CAN produce and directly proves injection. If `coord.newConversation()` is named differently in this codebase, use the existing method the other ChatCoordinatorTests call to start a conversation (the file's helpers already drive `coord.send` after setup).

- [ ] **Run the test, expect FAIL** — `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40`. Expected: `has no member 'hybridLexicalWeight'`, and the wiring test failing because the retriever still calls cosine-only `search` (the note isn't injected).

- [ ] **Minimal implementation** — two production edits.

(1) In `Targets/FoundationChatKit/Sources/Model/GenerationSettings.swift`, add the field after `memoryInjectionMaxCharsPerHit` and thread it through the init (param `hybridLexicalWeight: Float = 0.5,` + `self.hybridLexicalWeight = hybridLexicalWeight`):

```swift
    /// Weight of the lexical signal in hybrid retrieval (Plan 10 WS3). 0 = cosine-only,
    /// 1 = lexical-only. Default 0.5 blends them evenly.
    public var hybridLexicalWeight: Float = 0.5
```

(2) In `Targets/FoundationChatKit/Sources/App/ChatCoordinator.swift`, rewrite the retriever closure (currently lines ~210–227). **Preserve the existing `EmberLog.retrieval` diagnostics (the `scored`/`topPreview`/`hits` logging) — they are deliberately kept — and REMOVE the early-return-on-nil-vector guard.** The authoritative replacement:

```swift
            retrieval = ConversationEngine.MemoryRetrieval { query in
                // Hybrid path: an unembeddable query must still match lexically, so default the
                // vector to [] (cosine 0) rather than early-returning. Plan 10 WS3.
                let qv = embedder.embed(query) ?? []
                // Diagnostics: score the WHOLE snapshot once (no threshold/topK) so we can see how
                // close the best candidates came to the cutoff even when nothing passes.
                let scored = MemoryStore.search(snapshot, query: query, queryVector: qv,
                                                topK: snapshot.count, threshold: -1,
                                                lexicalWeight: settings.hybridLexicalWeight,
                                                excludingMessageIDs: excluded)
                let topPreview = scored.prefix(3)
                    .map { String(format: "%.3f:%@", $0.score, String($0.record.text.prefix(40))) }
                    .joined(separator: " | ")
                let hits = MemoryStore.search(snapshot, query: query, queryVector: qv,
                                              topK: topK, threshold: threshold,
                                              lexicalWeight: settings.hybridLexicalWeight,
                                              excludingMessageIDs: excluded, preferNotes: true)
                EmberLog.retrieval.info("retrieve: query=\"\(query, privacy: .public)\" → \(hits.count, privacy: .public)/\(topK, privacy: .public) hit(s) ≥ \(threshold, privacy: .public). best3=[\(topPreview, privacy: .public)]")
                return hits
            }
```

> The closure stays `@Sendable`: `LexicalScorer` is pure; `embedder`, `snapshot`, `excluded`, `topK`, `threshold` are already captured as Sendable locals, and `settings` is a value type. Match the EXACT local names already in `makeEngine` (`embedder`, `snapshot`, `excluded`, `topK`, `threshold`, `settings`). The only behavioral change: pass `query:` + `lexicalWeight:`, default the vector to `[]`, and drop the `guard let qv = embedder.embed(query) else { ... return [] }` early return.

- [ ] **Run the test, expect PASS** — framework: `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`; app: `xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=macOS' build 2>&1 | tail -10` → `BUILD SUCCEEDED`.

- [ ] **Commit:**

```bash
git checkout -b feat/plan10-ws3-hybrid-retrieval  # (already on it from Task 3.1)
git add Targets/FoundationChatKit/Sources/Model/GenerationSettings.swift \
        Targets/FoundationChatKit/Sources/App/ChatCoordinator.swift \
        Targets/FoundationChatKit/Tests/SupportingTypesTests.swift \
        Targets/FoundationChatKit/Tests/ChatCoordinatorTests.swift
git commit -m "feat(rag): wire hybrid retrieval through the auto-RAG retriever

Adds GenerationSettings.hybridLexicalWeight (0.5); ChatCoordinator's retriever
passes the raw query + lexicalWeight to MemoryStore.search, defaults the vector
to [] so unembeddable queries still match lexically, and keeps the EmberLog
diagnostics. A word-overlap query that cosine alone misses now injects memory.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> Dispatch: Opus 4.8 — fresh session (subagent-driven-development).

---

### Task 3.3b — Wire `MemorySearchTool` through the hybrid blend (preserve its defaults)

**Files:**
- Modify `Targets/FoundationChatKit/Sources/Tools/MemorySearchTool.swift`
- Test `Targets/FoundationChatKit/Tests/MemorySearchToolTests.swift` (extend)

> **MAJOR FIX.** The current `MemorySearchTool.call` (MemorySearchTool.swift line 31) calls `MemoryStore.search(snapshot, queryVector: queryVector, excludingMessageIDs: excludedIDs)` with NO explicit topK/threshold — i.e. it uses the cosine-only DEFAULTS `topK: 3, threshold: 0.2`. The original plan's "keep the tool's existing broad topK=5/threshold=0.15" was WRONG and would have silently widened the search and could push a near-miss above 0.15, breaking the existing `noMatchReturnsFallback` test (query `"music dog weather"` must return the fallback string). So: switch to the hybrid overload, add ONLY `query:` and `lexicalWeight: 0.5`, and PRESERVE the existing default `topK: 3, threshold: 0.2` (pass them explicitly for clarity).

- [ ] **Write the failing test** — append to `Targets/FoundationChatKit/Tests/MemorySearchToolTests.swift`:

```swift
@Test func toolUsesHybridBlendButKeepsFallbackForNoMatch() async throws {
    // Existing fallback contract must survive the hybrid switch: an off-vocab, off-topic query
    // still returns the no-match fallback (not a spurious near-miss).
    let tool = MemorySearchTool(embedder: MockEmbedder(), snapshot: snapshot())
    let result = try await tool.call(arguments: .init(query: "music dog weather"))
    #expect(result.contains("No relevant earlier context found."))
}

@Test func toolStillReturnsLexicalMatch() async throws {
    // "trip to paris" snapshot record shares words with the query → hybrid surfaces it even if
    // the embedder vector were weak. Confirms query+lexicalWeight are threaded.
    let tool = MemorySearchTool(embedder: MockEmbedder(), snapshot: snapshot())
    let result = try await tool.call(arguments: .init(query: "paris trip"))
    #expect(result.contains("trip to paris"))
}
```

- [ ] **Run the test, expect FAIL** — `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40`. Expected (before the edit) the tests compile and pass against cosine-only — so to make this a genuine red→green, write the impl edit FIRST is NOT allowed; instead these tests pin the contract the hybrid switch must preserve. If both already pass against the current code, they still serve as regression guards; the edit below must keep them green. (The `toolStillReturnsLexicalMatch` query `"paris trip"` already matches via cosine, so it is a guard; the new assertion that genuinely exercises the blend is the preserved fallback under the new code path.)

> Note: because the tool's behavior for these inputs is unchanged by design (same topK/threshold), these are guard tests, not red-first tests. The red→green for the hybrid wiring itself is covered by Task 3.3a's `wordOverlapQueryRetrievesViaHybridPath`. These two ensure the tool edit does not regress the fallback.

- [ ] **Minimal implementation** — in `Targets/FoundationChatKit/Sources/Tools/MemorySearchTool.swift`, change ONLY the `MemoryStore.search` call inside `call(arguments:)` to the hybrid overload, adding `query:` and `lexicalWeight:` while preserving the existing default `topK: 3, threshold: 0.2`:

```swift
        let hits = MemoryStore.search(
            snapshot,
            query: arguments.query,
            queryVector: queryVector,
            topK: 3,                  // preserve the tool's existing default topK
            threshold: 0.2,           // preserve the tool's existing default threshold
            lexicalWeight: 0.5,
            excludingMessageIDs: excludedIDs)
```

> Do NOT introduce `topK: 5` / `threshold: 0.15`. The local is named `queryVector` (from `guard let queryVector = embedder.embed(arguments.query)`) and `excludedIDs` — match those exactly. The existing `guard let queryVector = embedder.embed(...)` early return stays (the tool's own contract returns the fallback string when the query can't embed); the hybrid blend then runs with that vector.

- [ ] **Run the test, expect PASS** — `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`; app: `xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=macOS' build 2>&1 | tail -10` → `BUILD SUCCEEDED`.

- [ ] **Commit:**

```bash
git add Targets/FoundationChatKit/Sources/Tools/MemorySearchTool.swift \
        Targets/FoundationChatKit/Tests/MemorySearchToolTests.swift
git commit -m "feat(rag): MemorySearchTool uses hybrid blend, preserving its defaults

Adds query + lexicalWeight 0.5 to the tool's MemoryStore.search call while
keeping the existing default topK 3 / threshold 0.2 so the no-match fallback
contract is unchanged.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> Dispatch: Opus 4.8 — fresh session (subagent-driven-development).

---

## Workstream 4 — Structured @Generable compaction summary

**Branch:** `feat/plan10-ws4-structured-summary`

> **Hard dependency:** WS4 uses `UtilityGenerationOptions.summary` from WS1. WS4 branches off `main` only AFTER WS1 has merged. There is no inline-TODO fallback — the merge order guarantees WS1 is present.

**Goal (2 lines):** Replace the plain-string `summarize` used by `ContextCompactor` with a structured `ConversationSummary` (`summary` + `keyTopics` + `userPreferences`), rendered deterministically into the recap, and route each `userPreferences` entry through `MemoryStore.saveNoteIfNovel` so durable prefs survive compaction as notes.

**Files map:**

- **Create** `Targets/FoundationChatKit/Sources/Context/ConversationSummary.swift` — the `@Generable` type + a pure `render()`.
- **Create** `Targets/FoundationChatKit/Tests/ConversationSummaryTests.swift`.
- **Modify** `Targets/FoundationChatKit/Sources/Provider/ChatModelProvider.swift` — add `summarizeStructured` to the protocol.
- **Modify** `Targets/FoundationChatKit/Sources/Provider/FoundationModelProvider.swift` — real `summarizeStructured`.
- **Modify** `Targets/FoundationChatKit/Tests/MockModelProvider.swift` — mock `summarizeStructured` (with a DISTINCT captured field).
- **Modify** `Targets/FoundationChatKit/Sources/Context/ContextCompactor.swift` — use structured summary; render; harvest prefs.
- **Test** `ContextCompactorTests.swift` (**migrate 2 existing tests** + extend), `OverflowCompactionTests.swift` (**update dead scripting**), `MockModelProviderTests.swift` (extend).

> **Decision on the old string `summarize`:** **Keep** it on the protocol and `FoundationModelProvider` (cheap to retain; still a valid seam), but `ContextCompactor` switches to `summarizeStructured`. The deterministic fallback (`OverflowRecovery.condense`) is unchanged. Stated explicitly so the app + all tests keep compiling.

---

### Task 4.1 — `ConversationSummary` @Generable type + pure `render()`

**Files:**
- Create `Targets/FoundationChatKit/Sources/Context/ConversationSummary.swift`
- Create `Targets/FoundationChatKit/Tests/ConversationSummaryTests.swift`

- [ ] **Write the failing test** — `Targets/FoundationChatKit/Tests/ConversationSummaryTests.swift`:

```swift
import Testing
@testable import FoundationChatKit

@Suite struct ConversationSummaryTests {
    @Test func rendersAllSectionsWhenPresent() {
        let s = ConversationSummary(
            summary: "Discussed a December trip to Lisbon.",
            keyTopics: ["Lisbon", "packing"],
            userPreferences: ["User prefers boutique hotels"])
        let out = s.render()
        #expect(out.contains("Discussed a December trip to Lisbon."))
        #expect(out.contains("Lisbon"))
        #expect(out.contains("packing"))
        #expect(out.contains("User prefers boutique hotels"))
    }

    @Test func rendersSummaryOnlyWhenTopicsAndPrefsEmpty() {
        let s = ConversationSummary(summary: "Short chat.", keyTopics: [], userPreferences: [])
        #expect(s.render() == "Short chat.")
    }

    @Test func renderTrimsAndDropsEmptyEntries() {
        let s = ConversationSummary(
            summary: "  Trip talk.  ",
            keyTopics: ["Lisbon", "  ", ""],
            userPreferences: ["  "])
        let out = s.render()
        #expect(out.hasPrefix("Trip talk."))
        #expect(out.contains("Lisbon"))
        #expect(!out.contains("Preferences"))   // all prefs blank → section omitted
    }

    @Test func isEmptyWhenNothingMeaningful() {
        #expect(ConversationSummary(summary: "   ", keyTopics: [], userPreferences: []).isEmpty)
        #expect(!ConversationSummary(summary: "x", keyTopics: [], userPreferences: []).isEmpty)
    }
}
```

- [ ] **Run the test, expect FAIL** — `tuist generate --no-open` then `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40`. Expected: `cannot find 'ConversationSummary' in scope`.

- [ ] **Minimal implementation** — `Targets/FoundationChatKit/Sources/Context/ConversationSummary.swift`:

```swift
import Foundation
import FoundationModels

/// Structured compaction summary (Plan 10 WS4). Produced by the model in a throwaway session
/// and rendered deterministically into the recap. `userPreferences` are additionally harvested
/// into durable notes by ContextCompactor so they survive future compactions.
@Generable(description: "A structured recap of earlier conversation for context compaction.")
public struct ConversationSummary: Sendable, Equatable {
    @Guide(description: "A brief factual summary of the earlier conversation in 1-3 sentences, preserving names, facts, and decisions.")
    public var summary: String

    @Guide(description: "Up to 5 short key topics discussed.", .maximumCount(5))
    public var keyTopics: [String]

    @Guide(description: "Up to 5 durable USER preferences or stable personal facts, in the third person. Empty if none.", .maximumCount(5))
    public var userPreferences: [String]

    public init(summary: String, keyTopics: [String], userPreferences: [String]) {
        self.summary = summary
        self.keyTopics = keyTopics
        self.userPreferences = userPreferences
    }

    /// Non-empty entries only, trimmed.
    var cleanTopics: [String] { keyTopics.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    var cleanPreferences: [String] { userPreferences.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    var cleanSummary: String { summary.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var isEmpty: Bool {
        cleanSummary.isEmpty && cleanTopics.isEmpty && cleanPreferences.isEmpty
    }

    /// Deterministic recap text. Sections are appended only when non-empty.
    public func render() -> String {
        var parts: [String] = []
        if !cleanSummary.isEmpty { parts.append(cleanSummary) }
        if !cleanTopics.isEmpty { parts.append("Topics: \(cleanTopics.joined(separator: ", "))") }
        if !cleanPreferences.isEmpty {
            parts.append("Preferences: \(cleanPreferences.joined(separator: "; "))")
        }
        return parts.joined(separator: "\n")
    }
}
```

> **`.maximumCount` fallback:** if the macro guide fails to compile in-session, drop the `.maximumCount(5)` arguments (keep descriptions). `render()`/`isEmpty` don't depend on the count guide. `renderTrimsAndDropsEmptyEntries` is verified: `cleanSummary`="Trip talk." (first → `hasPrefix`), `cleanTopics`=["Lisbon"], `cleanPreferences`=[] → "Preferences" omitted.

- [ ] **Run the test, expect PASS** — `tuist generate --no-open` then `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`.

- [ ] **Commit:**

```bash
git checkout -b feat/plan10-ws4-structured-summary
git add Targets/FoundationChatKit/Sources/Context/ConversationSummary.swift \
        Targets/FoundationChatKit/Tests/ConversationSummaryTests.swift
git commit -m "feat(compaction): add @Generable ConversationSummary + deterministic render

summary + keyTopics + userPreferences with a pure render()/isEmpty.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> Dispatch: Opus 4.8 — fresh session (subagent-driven-development).

---

### Task 4.2 — Provider seam: `summarizeStructured` (protocol + real + mock)

**Files:**
- Modify `Targets/FoundationChatKit/Sources/Provider/ChatModelProvider.swift`
- Modify `Targets/FoundationChatKit/Sources/Provider/FoundationModelProvider.swift`
- Modify `Targets/FoundationChatKit/Tests/MockModelProvider.swift`
- Test `Targets/FoundationChatKit/Tests/MockModelProviderTests.swift` (extend)

> **MAJOR FIX — name collision.** `MockModelProvider` ALREADY declares `private(set) var capturedSummarizeInput: String?` (line 112), written by the string `summarize` (line 134). The new `summarizeStructured` must NOT reuse it (ambiguous and pollutes the string-summarize tests). Use a DISTINCT field `capturedStructuredSummarizeInput` and assert against that.

- [ ] **Write the failing test** — append to `Targets/FoundationChatKit/Tests/MockModelProviderTests.swift`:

```swift
@Test func mockSummarizeStructuredReturnsScripted() async {
    let provider = MockModelProvider()
    provider.scriptedStructuredSummary = ConversationSummary(
        summary: "A planning chat.", keyTopics: ["Lisbon"],
        userPreferences: ["User prefers window seats"])
    let result = await provider.summarizeStructured("long history text")
    #expect(result?.summary == "A planning chat.")
    #expect(result?.userPreferences == ["User prefers window seats"])
    #expect(provider.capturedStructuredSummarizeInput == "long history text")
}

@Test func mockSummarizeStructuredNilByDefault() async {
    let provider = MockModelProvider()
    #expect(await provider.summarizeStructured("x") == nil)
}
```

- [ ] **Run the test, expect FAIL** — `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40`. Expected: `value of type 'MockModelProvider' has no member 'summarizeStructured'`.

- [ ] **Minimal implementation** — three edits.

(1) In `Targets/FoundationChatKit/Sources/Provider/ChatModelProvider.swift`, add to the `ChatModelProvider` protocol (after `summarize`):

```swift
    func summarizeStructured(_ text: String) async -> ConversationSummary?
```

(2) In `Targets/FoundationChatKit/Sources/Provider/FoundationModelProvider.swift`, add the real implementation (after `summarize`):

```swift
    public func summarizeStructured(_ text: String) async -> ConversationSummary? {
        guard case .available = availability else { return nil }
        let session = LanguageModelSession(
            instructions: "You compress chat history into a structured recap: a brief summary, key topics, and durable user preferences (third person).")
        do {
            let response = try await session.respond(
                to: "Summarize the following conversation. Preserve names, facts, and decisions.\n\(text)",
                generating: ConversationSummary.self,
                options: UtilityGenerationOptions.summary)
            return response.content.isEmpty ? nil : response.content
        } catch {
            return nil
        }
    }
```

(3) In `Targets/FoundationChatKit/Tests/MockModelProvider.swift`, add the scripted hook + a DISTINCT captured field + the method (do NOT reuse `capturedSummarizeInput`):

```swift
    // Plan 10 WS4 — structured summary scripting. Separate captured field from the string
    // `summarize` path's `capturedSummarizeInput` to avoid cross-method pollution.
    var scriptedStructuredSummary: ConversationSummary?
    var capturedStructuredSummarizeInput: String?

    func summarizeStructured(_ text: String) async -> ConversationSummary? {
        capturedStructuredSummarizeInput = text
        return scriptedStructuredSummary
    }
```

- [ ] **Run the test, expect PASS** — framework: `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`; app: `xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=macOS' build 2>&1 | tail -10` → `BUILD SUCCEEDED` (the app's `FoundationModelProvider` implements the extended protocol).

- [ ] **Commit:**

```bash
git add Targets/FoundationChatKit/Sources/Provider/ChatModelProvider.swift \
        Targets/FoundationChatKit/Sources/Provider/FoundationModelProvider.swift \
        Targets/FoundationChatKit/Tests/MockModelProvider.swift \
        Targets/FoundationChatKit/Tests/MockModelProviderTests.swift
git commit -m "feat(provider): add summarizeStructured seam (protocol + real + mock)

ChatModelProvider gains summarizeStructured -> ConversationSummary?; real impl
uses guided generation + deterministic options; mock is scriptable with a
distinct capturedStructuredSummarizeInput field.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> Dispatch: Opus 4.8 — fresh session (subagent-driven-development).

---

### Task 4.3 — `ContextCompactor` uses structured summary + harvests prefs (+ migrate existing tests)

**Files:**
- Modify `Targets/FoundationChatKit/Sources/Context/ContextCompactor.swift`
- Test `Targets/FoundationChatKit/Tests/ContextCompactorTests.swift` — **migrate 2 existing tests + extend**
- Test `Targets/FoundationChatKit/Tests/OverflowCompactionTests.swift` — **update dead `summarizeResult` scripting**

> **BLOCKER FIX — existing tests regress.** Switching `compact` from string `summarize` to `summarizeStructured` breaks tests the original plan never touched:
> - `ContextCompactorTests.summarizesOlderKeepsRecent` sets `p.summarizeResult = "RECAP"` and asserts the recap contains `"RECAP"`. After the switch, the compactor reads `scriptedStructuredSummary` (default nil) → falls to `OverflowRecovery.condense` → `"RECAP"` never appears → FAIL.
> - `ContextCompactorTests.excludesRetrievedMemoryFromSummaryInput` asserts on `capturedSummarizeInput` (string path), which is never set after the switch → FAIL.
> - `OverflowCompactionTests.proactivelyCompactsBeforeOverflow` / `reactiveRecoveryUsesCompactor` set `provider.summarizeResult = "RECAP"` (now dead) but only assert on the systemNotice text, which survives via the condense fallback — they still pass, but the dead `summarizeResult` lines should be migrated to `scriptedStructuredSummary` so intent matches and the recap is actually structured.
>
> This task migrates ALL of the above in the same commit. `ContextCompactorTests.fallsBackToCondenseWhenSummaryNil` and `shortInputUnchanged` are already correct against the new path (nil structured summary → condense) and need no change.

> **Compactor signature & trailing closure:** `compact(_:keepingRecent:using:onPreference:)` — `onPreference` is LAST, so the trailing-closure call `compact(entries, using: provider) { pref in ... }` compiles. Existing zero-arg call sites keep working via the default `nil`.

- [ ] **Write the failing test** — first MIGRATE the two existing `ContextCompactorTests`:

Replace `summarizesOlderKeepsRecent`:

```swift
    @Test func summarizesOlderKeepsRecent() async {
        let p = MockModelProvider()
        p.scriptedStructuredSummary = ConversationSummary(
            summary: "RECAP", keyTopics: [], userPreferences: [])
        let result = await ContextCompactor.compact(entries(10), keepingRecent: 4, using: p)
        #expect(result.count == 5)                       // 1 recap + 4 recent
        #expect(result.first?.kind == .instructions)
        #expect(result.first?.text.contains("RECAP") == true)
        #expect(result.last?.text == "msg9")
    }
```

Replace `excludesRetrievedMemoryFromSummaryInput` to assert on the STRUCTURED captured field:

```swift
    @Test func excludesRetrievedMemoryFromSummaryInput() async {
        let p = MockModelProvider()
        p.scriptedStructuredSummary = ConversationSummary(
            summary: "RECAP", keyTopics: [], userPreferences: [])
        let older: [ContextEntry] = [
            ContextEntry(kind: .userPrompt, text: "USER_OLD"),
            ContextEntry(kind: .retrievedMemory, text: "SECRET_MEMORY"),
            ContextEntry(kind: .modelResponse, text: "ASSISTANT_OLD"),
        ]
        let recent = entries(4)
        _ = await ContextCompactor.compact(older + recent, keepingRecent: 4, using: p)
        let captured = p.capturedStructuredSummarizeInput ?? ""
        #expect(captured.contains("USER_OLD"))
        #expect(captured.contains("ASSISTANT_OLD"))
        #expect(!captured.contains("SECRET_MEMORY"))
    }
```

Then APPEND the new tests:

```swift
    @Test func compactUsesStructuredSummaryAndRendersIt() async {
        let provider = MockModelProvider()
        provider.scriptedStructuredSummary = ConversationSummary(
            summary: "Planned a Lisbon trip.", keyTopics: ["Lisbon"],
            userPreferences: ["User prefers boutique hotels"])
        let result = await ContextCompactor.compact(entries(10), keepingRecent: 4, using: provider)
        let recap = result.first { $0.kind == .instructions }
        #expect(recap?.text.contains("Planned a Lisbon trip.") == true)
        #expect(recap?.text.contains("Lisbon") == true)
        #expect(recap?.text.contains("boutique hotels") == true)
    }

    @Test func compactHarvestsUserPreferencesViaCallback() async {
        let provider = MockModelProvider()
        provider.scriptedStructuredSummary = ConversationSummary(
            summary: "Chat.", keyTopics: [],
            userPreferences: ["User is vegetarian", "User prefers aisle seats"])
        var harvested: [String] = []
        _ = await ContextCompactor.compact(entries(10), keepingRecent: 4, using: provider) {
            harvested.append($0)
        }
        #expect(harvested == ["User is vegetarian", "User prefers aisle seats"])
    }

    @Test func compactFallsBackWhenStructuredSummaryNil() async {
        let provider = MockModelProvider()
        provider.scriptedStructuredSummary = nil   // forces the deterministic fallback
        var harvested: [String] = []
        let out = await ContextCompactor.compact(entries(10), keepingRecent: 4, using: provider) {
            harvested.append($0)
        }
        #expect(!out.isEmpty)            // condensed fallback still returns entries
        #expect(harvested.isEmpty)       // no prefs harvested when summary is nil
    }
```

Then MIGRATE the dead scripting in `Targets/FoundationChatKit/Tests/OverflowCompactionTests.swift` (lines 10 and 24): change both `provider.summarizeResult = "RECAP"` to:

```swift
        provider.scriptedStructuredSummary = ConversationSummary(
            summary: "RECAP", keyTopics: [], userPreferences: [])
```

(The systemNotice assertions in those tests are unchanged and still pass.)

- [ ] **Run the test, expect FAIL** — `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40`. Expected: `extra trailing closure passed in call` (the `onPreference` param doesn't exist yet) and the compactor still calling string `summarize`.

- [ ] **Minimal implementation** — replace `Targets/FoundationChatKit/Sources/Context/ContextCompactor.swift`:

```swift
import Foundation

public enum ContextCompactor {
    @MainActor
    public static func compact(_ entries: [ContextEntry], keepingRecent: Int = 4,
                               using provider: any ChatModelProvider,
                               onPreference: (@MainActor (String) -> Void)? = nil) async -> [ContextEntry] {
        guard entries.count > keepingRecent else { return entries }
        let older = entries.prefix(entries.count - keepingRecent)
        let recent = Array(entries.suffix(keepingRecent))
        let text = older.compactMap { entry -> String? in
            let who: String
            switch entry.kind {
            case .userPrompt: who = "User"
            case .modelResponse: who = "Assistant"
            case .instructions: who = "System"
            case .toolCall: who = "Tool call"
            case .toolOutput: who = "Tool output"
            case .retrievedMemory: return nil
            }
            return "\(who): \(entry.text)"
        }.joined(separator: "\n")

        guard let structured = await provider.summarizeStructured(text), !structured.isEmpty else {
            return OverflowRecovery.condense(entries)
        }
        // Harvest durable preferences so they survive future compactions as notes.
        for pref in structured.cleanPreferences { onPreference?(pref) }
        let recap = ContextEntry(kind: .instructions,
                                 text: "Summary of earlier conversation: \(structured.render())")
        return [recap] + recent
    }
}
```

> The `switch` over `entry.kind` must cover EXACTLY the cases in `ContextEntry.Kind` as it exists in this codebase. If a case is missing or named differently, match the source enum (the existing compactor's `text` builder is the reference). `.retrievedMemory` is excluded from the summary input (preserves the `excludesRetrievedMemoryFromSummaryInput` contract).

- [ ] **Run the test, expect PASS** — framework: `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`.

- [ ] **Commit:**

```bash
git add Targets/FoundationChatKit/Sources/Context/ContextCompactor.swift \
        Targets/FoundationChatKit/Tests/ContextCompactorTests.swift \
        Targets/FoundationChatKit/Tests/OverflowCompactionTests.swift
git commit -m "feat(compaction): render structured summary + harvest prefs via callback

ContextCompactor.compact now uses summarizeStructured and renders summary +
topics + preferences; an onPreference callback surfaces each pref. Migrates the
existing ContextCompactor/OverflowCompaction tests off the dead string-summarize
scripting. Deterministic OverflowRecovery fallback unchanged.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> Dispatch: Opus 4.8 — fresh session (subagent-driven-development).

---

### Task 4.4 — Engine routes harvested prefs into `MemoryStore.saveNoteIfNovel`

**Files:**
- Modify `Targets/FoundationChatKit/Sources/Engine/ConversationEngine.swift`
- Modify `Targets/FoundationChatKit/Sources/App/ChatCoordinator.swift`
- Modify `Targets/FoundationChatKit/Tests/MockModelProvider.swift`
- Test `Targets/FoundationChatKit/Tests/ConversationEngineTests.swift` (extend)

> The engine calls `ContextCompactor.compact` in two places (`compactIfNeeded`, `recoverFromOverflow`). We thread an injectable `onCompactionPreference` closure (matching the `MemoryRetrieval` injection style) so the app routes prefs to `MemoryStore.saveNoteIfNovel` without the engine importing SwiftData. Default `nil` keeps existing tests/call sites compiling.
>
> **Behavioral boundary (documented):** harvested prefs become retrievable on the NEXT `makeEngine` snapshot — the point-in-time snapshot retrieval model, same as Plan 9 facts. They are NOT injectable mid-session; "survive compaction as notes" means they persist and are recalled in subsequent engine builds.

- [ ] **Write the failing test** — append to `Targets/FoundationChatKit/Tests/ConversationEngineTests.swift`:

```swift
@Test func compactionRoutesPreferencesToCallback() async {
    let provider = MockModelProvider()
    provider.scriptedStructuredSummary = ConversationSummary(
        summary: "Chat.", keyTopics: [], userPreferences: ["User prefers tea"])
    // Force compaction: tiny window so the projected turn overflows.
    provider.maxContextTokens = 40
    provider.session.scriptedSnapshots = ["ok"]

    var savedPrefs: [String] = []
    let engine = ConversationEngine(
        provider: provider,
        settings: GenerationSettings(reservedReplyTokens: 8),
        onCompactionPreference: { savedPrefs.append($0) })

    // Seed entries so compact has something to summarize, then send to trigger it.
    await engine.send("first message that is long enough to matter for budgeting here")
    await engine.send("second message that should push us over the tiny window now")

    #expect(savedPrefs.contains("User prefers tea"))
}
```

> `MockModelProvider.maxContextTokens` is already a settable `var` (line 103: `var maxContextTokens: Int = 4096`), so no new test infra is needed — set it directly. (The original plan's `overrideMaxContextTokens` is unnecessary.)

- [ ] **Run the test, expect FAIL** — `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40`. Expected: `extra argument 'onCompactionPreference' in call`.

- [ ] **Minimal implementation** — three edits.

(1) In `Targets/FoundationChatKit/Sources/Engine/ConversationEngine.swift`, add a stored closure + init param. Near the other private lets:

```swift
    private let onCompactionPreference: (@MainActor (String) -> Void)?
```

Add to the `init` signature (after `now:` in the parameter list) and assign it:

```swift
        onCompactionPreference: (@MainActor (String) -> Void)? = nil,
```
```swift
        self.onCompactionPreference = onCompactionPreference
```

Pass it into BOTH compaction call sites. In `compactIfNeeded`:

```swift
        let condensed = await ContextCompactor.compact(session.contextEntries,
                                                       using: provider,
                                                       onPreference: onCompactionPreference)
```

…and identically in `recoverFromOverflow`.

(2) Wire the real route in `Targets/FoundationChatKit/Sources/App/ChatCoordinator.swift`: when constructing the `ConversationEngine` in `makeEngine`, add `onCompactionPreference:`. The coordinator already captures `memory` (the optional `MemoryStore`) in the `if let memory { ... }` block; both `MemoryStore` and `saveNoteIfNovel` are `@MainActor`, so the closure body runs on the main actor (no Sendable issue). Add to the `ConversationEngine(...)` call:

```swift
            onCompactionPreference: memory.map { mem in { @MainActor pref in _ = mem.saveNoteIfNovel(pref) } },
```

> If `memory` is captured under a different local name in `makeEngine`, match it. When `memory` is nil (memory off), `onCompactionPreference` is nil and compaction harvests nothing — correct. `saveNoteIfNovel` returns a Bool (per ChatCoordinator line 167 `let saved = memory.saveNoteIfNovel(fact)`), so discard it with `_ =`.

(3) No mock change is strictly required (test sets `provider.maxContextTokens` directly), but confirm `MockModelProvider` exposes `maxContextTokens` as settable — it does (line 103). No edit.

- [ ] **Run the test, expect PASS** — framework: `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`; app: `xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=macOS' build 2>&1 | tail -10` → `BUILD SUCCEEDED`.

- [ ] **Commit:**

```bash
git add Targets/FoundationChatKit/Sources/Engine/ConversationEngine.swift \
        Targets/FoundationChatKit/Sources/App/ChatCoordinator.swift \
        Targets/FoundationChatKit/Tests/ConversationEngineTests.swift
git commit -m "feat(engine): route compaction userPreferences to saveNoteIfNovel

ConversationEngine gains an injectable onCompactionPreference closure passed to
ContextCompactor at both compaction sites; ChatCoordinator routes it to
MemoryStore.saveNoteIfNovel so durable prefs survive compaction as deduped notes
(retrievable in subsequent engine builds, matching the snapshot model).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> Dispatch: Opus 4.8 — fresh session (subagent-driven-development).

---

## Workstream 5 — Token-cost breakdown in the inspector

**Branch:** `feat/plan10-ws5-token-breakdown`

> **Depends on WS2** (the `"Retrieved memory"` synthetic line) — branch off `main` after WS2 merges.

**Goal (2 lines):** Surface WHERE tokens go (instructions / tools / history / retrieved-memory / reply-reserve) as a pure `TokenBreakdown` produced by `TokenBudgetCalculator`, plus a color-coded fraction via a pure `TokenMeterColor.for(fraction:)` (green<0.5, yellow<0.75, orange<0.9, red). All logic is unit-tested in `FoundationChatKit`; the SwiftUI views stay thin.

**Files map:**

- **Create** `Targets/FoundationChatKit/Sources/Tokens/TokenBreakdown.swift` — the struct + `TokenMeterColorBucket` + `TokenMeterColor.for(fraction:)`.
- **Create** `Targets/FoundationChatKit/Tests/TokenBreakdownTests.swift`.
- **Modify** `Targets/FoundationChatKit/Sources/Tokens/TokenBudgetCalculator.swift` — add `breakdown(...)`.
- **Test** `Targets/FoundationChatKit/Tests/TokenBudgetCalculatorTests.swift` (extend).
- **Modify** `Targets/FoundationChatKit/Sources/Engine/ConversationEngine.swift` — expose a `tokenBreakdown` computed value.
- **Modify** `Targets/Ember/Sources/TokenMeterView.swift` — render breakdown rows + bucket color.
- **Modify** `Targets/Ember/Sources/InspectorPanel.swift` — pass `breakdown: engine.tokenBreakdown`.

---

### Task 5.1 — `TokenBreakdown` + `TokenMeterColor.for(fraction:)` (pure)

**Files:**
- Create `Targets/FoundationChatKit/Sources/Tokens/TokenBreakdown.swift`
- Create `Targets/FoundationChatKit/Tests/TokenBreakdownTests.swift`

- [ ] **Write the failing test** — `Targets/FoundationChatKit/Tests/TokenBreakdownTests.swift`:

```swift
import Testing
@testable import FoundationChatKit

@Suite struct TokenBreakdownTests {
    @Test func totalSumsAllBuckets() {
        let b = TokenBreakdown(instructions: 10, tools: 20, history: 100,
                               retrievedMemory: 30, replyReserve: 512)
        #expect(b.total == 10 + 20 + 100 + 30 + 512)
    }

    @Test func breakdownIsEquatable() {
        let a = TokenBreakdown(instructions: 1, tools: 2, history: 3, retrievedMemory: 4, replyReserve: 5)
        let b = TokenBreakdown(instructions: 1, tools: 2, history: 3, retrievedMemory: 4, replyReserve: 5)
        #expect(a == b)
    }

    @Test func colorBucketsMatchThresholds() {
        #expect(TokenMeterColor.for(fraction: 0.0) == .green)
        #expect(TokenMeterColor.for(fraction: 0.49) == .green)
        #expect(TokenMeterColor.for(fraction: 0.5) == .yellow)
        #expect(TokenMeterColor.for(fraction: 0.74) == .yellow)
        #expect(TokenMeterColor.for(fraction: 0.75) == .orange)
        #expect(TokenMeterColor.for(fraction: 0.89) == .orange)
        #expect(TokenMeterColor.for(fraction: 0.9) == .red)
        #expect(TokenMeterColor.for(fraction: 1.5) == .red)   // clamps above 1
    }
}
```

- [ ] **Run the test, expect FAIL** — `tuist generate --no-open` then `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40`. Expected: `cannot find 'TokenBreakdown' in scope`.

- [ ] **Minimal implementation** — `Targets/FoundationChatKit/Sources/Tokens/TokenBreakdown.swift`:

```swift
import Foundation

/// Per-bucket view of where the context budget goes (Plan 10 WS5). Pure, Sendable, Equatable —
/// the SwiftUI inspector renders it directly.
public struct TokenBreakdown: Sendable, Equatable {
    public var instructions: Int
    public var tools: Int
    public var history: Int
    public var retrievedMemory: Int
    public var replyReserve: Int
    public var total: Int

    public init(instructions: Int, tools: Int, history: Int,
                retrievedMemory: Int, replyReserve: Int) {
        self.instructions = instructions
        self.tools = tools
        self.history = history
        self.retrievedMemory = retrievedMemory
        self.replyReserve = replyReserve
        self.total = instructions + tools + history + retrievedMemory + replyReserve
    }
}

/// Color bucket for the token gauge fraction. Borrows Foundation Lab's TokenUsageBar
/// thresholds: green < 0.5, yellow < 0.75, orange < 0.9, red >= 0.9.
public enum TokenMeterColorBucket: Sendable, Equatable { case green, yellow, orange, red }

public enum TokenMeterColor {
    public static func `for`(fraction: Double) -> TokenMeterColorBucket {
        let f = min(max(fraction, 0), 1)
        switch f {
        case ..<0.5: return .green
        case ..<0.75: return .yellow
        case ..<0.9: return .orange
        default: return .red
        }
    }
}
```

- [ ] **Run the test, expect PASS** — `tuist generate --no-open` then `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`.

- [ ] **Commit:**

```bash
git checkout -b feat/plan10-ws5-token-breakdown
git add Targets/FoundationChatKit/Sources/Tokens/TokenBreakdown.swift \
        Targets/FoundationChatKit/Tests/TokenBreakdownTests.swift
git commit -m "feat(tokens): add TokenBreakdown + TokenMeterColor.for(fraction:)

Pure per-bucket breakdown (instructions/tools/history/retrievedMemory/replyReserve)
and 4-tier color thresholds (green<.5, yellow<.75, orange<.9, red).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> Dispatch: Opus 4.8 — fresh session (subagent-driven-development).

---

### Task 5.2 — `TokenBudgetCalculator.breakdown(...)` from a snapshot + reserve

**Files:**
- Modify `Targets/FoundationChatKit/Sources/Tokens/TokenBudgetCalculator.swift`
- Test `Targets/FoundationChatKit/Tests/TokenBudgetCalculatorTests.swift` (extend)

> The calculator already labels lines (`"Instructions"`, `"Tool: …"`, `"You"`/`"Assistant"`/`"Tool call"`/`"Tool output"`/`"Memory"`, and WS2's `"Retrieved memory"`). `breakdown` buckets those existing lines plus the externally-provided reply reserve, so it needs no re-tokenization.
>
> **MAJOR FIX — realistic fixture.** Both `"Memory"` (the real `.retrievedMemory` entry label) and `"Retrieved memory"` (WS2's synthetic in-flight line) map to `retrievedMemory` as defense-in-depth. In production the WS2 guard prevents both from co-existing (the synthetic line is suppressed once a `.retrievedMemory` entry exists). So the test must NOT feed BOTH at once and assert their sum — that fixture is unreachable in the real pipeline. The first test below uses a single `"Retrieved memory"` line; the dual-label mapping is exercised structurally, not by an impossible co-existence.

- [ ] **Write the failing test** — append to `Targets/FoundationChatKit/Tests/TokenBudgetCalculatorTests.swift`:

```swift
@Test func breakdownBucketsSnapshotLines() {
    let lines = [
        BudgetLine(id: 0, label: "Instructions", tokens: 12),
        BudgetLine(id: 1, label: "Tool: calculator", tokens: 8),
        BudgetLine(id: 2, label: "Tool: dateTime", tokens: 6),
        BudgetLine(id: 3, label: "You", tokens: 40),
        BudgetLine(id: 4, label: "Assistant", tokens: 55),
        BudgetLine(id: 5, label: "Retrieved memory", tokens: 9)   // WS2 synthetic line
    ]
    let snapshot = TokenBudgetSnapshot(maxTokens: 4096, usedTokens: 130, isExact: true, lines: lines)
    let calc = TokenBudgetCalculator()
    let b = calc.breakdown(from: snapshot, replyReserve: 512)
    #expect(b.instructions == 12)
    #expect(b.tools == 14)               // 8 + 6
    #expect(b.history == 95)             // 40 + 55
    #expect(b.retrievedMemory == 9)
    #expect(b.replyReserve == 512)
    #expect(b.total == 12 + 14 + 95 + 9 + 512)
}

@Test func breakdownBucketsCommittedMemoryLabel() {
    // The real committed-transcript label "Memory" also maps to retrievedMemory.
    let lines = [
        BudgetLine(id: 0, label: "You", tokens: 20),
        BudgetLine(id: 1, label: "Memory", tokens: 17)
    ]
    let snapshot = TokenBudgetSnapshot(maxTokens: 4096, usedTokens: 37, isExact: true, lines: lines)
    let b = TokenBudgetCalculator().breakdown(from: snapshot, replyReserve: 0)
    #expect(b.retrievedMemory == 17)
    #expect(b.history == 20)
}

@Test func breakdownTreatsTypingLineAsHistory() {
    let lines = [
        BudgetLine(id: 0, label: "You", tokens: 10),
        BudgetLine(id: 1, label: "Assistant (typing\u{2026})", tokens: 3)
    ]
    let snapshot = TokenBudgetSnapshot(maxTokens: 4096, usedTokens: 13, isExact: false, lines: lines)
    let b = TokenBudgetCalculator().breakdown(from: snapshot, replyReserve: 0)
    #expect(b.history == 13)
    #expect(b.replyReserve == 0)
}
```

- [ ] **Run the test, expect FAIL** — `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40`. Expected: `value of type 'TokenBudgetCalculator' has no member 'breakdown'`.

- [ ] **Minimal implementation** — add to `Targets/FoundationChatKit/Sources/Tokens/TokenBudgetCalculator.swift`:

```swift
    /// Fold a snapshot's labeled lines into the five inspector buckets, adding the externally
    /// supplied reply reserve. Pure: it re-buckets existing per-line counts, no re-tokenizing.
    /// Both "Memory" (committed `.retrievedMemory` entry) and "Retrieved memory" (WS2's synthetic
    /// in-flight line) map to retrievedMemory as defense-in-depth; in production the WS2 guard
    /// ensures only one of them is present at a time.
    public func breakdown(from snapshot: TokenBudgetSnapshot, replyReserve: Int) -> TokenBreakdown {
        var instructions = 0, tools = 0, history = 0, retrievedMemory = 0
        for line in snapshot.lines {
            if line.label == "Instructions" {
                instructions += line.tokens
            } else if line.label.hasPrefix("Tool: ") {
                tools += line.tokens
            } else if line.label == "Memory" || line.label == "Retrieved memory" {
                retrievedMemory += line.tokens
            } else {
                // You / Assistant / Assistant (typing…) / Tool call / Tool output → history.
                history += line.tokens
            }
        }
        return TokenBreakdown(instructions: instructions, tools: tools, history: history,
                              retrievedMemory: retrievedMemory, replyReserve: replyReserve)
    }
```

> Match the EXACT label strings the calculator already emits in this codebase (grep `label:` / `BudgetLine(` in `TokenBudgetCalculator.swift`). If the committed-memory label is something other than `"Memory"` (e.g. `"Recalled memory"`), use that literal; the bucket logic is otherwise unchanged.

- [ ] **Run the test, expect PASS** — `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`.

- [ ] **Commit:**

```bash
git add Targets/FoundationChatKit/Sources/Tokens/TokenBudgetCalculator.swift \
        Targets/FoundationChatKit/Tests/TokenBudgetCalculatorTests.swift
git commit -m "feat(tokens): TokenBudgetCalculator.breakdown(from:replyReserve:)

Folds labeled snapshot lines into instructions/tools/history/retrievedMemory
buckets plus the supplied reply reserve. Both memory labels map to
retrievedMemory (defense-in-depth; only one occurs at a time). Pure.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> Dispatch: Opus 4.8 — fresh session (subagent-driven-development).

---

### Task 5.3 — Engine exposes `tokenBreakdown`

**Files:**
- Modify `Targets/FoundationChatKit/Sources/Engine/ConversationEngine.swift`
- Test `Targets/FoundationChatKit/Tests/ConversationEngineTests.swift` (extend)

- [ ] **Write the failing test** — append to `Targets/FoundationChatKit/Tests/ConversationEngineTests.swift`:

```swift
@Test func engineExposesTokenBreakdownWithReserve() async {
    let provider = MockModelProvider()
    provider.session.scriptedSnapshots = ["Hello there"]
    let engine = ConversationEngine(provider: provider,
                                    settings: GenerationSettings(reservedReplyTokens: 512))
    await engine.send("hi")
    let b = engine.tokenBreakdown
    #expect(b.replyReserve == 512)
    #expect(b.total >= b.history)             // total includes history + reserve
    #expect(b.history > 0)                    // a turn happened
}
```

- [ ] **Run the test, expect FAIL** — `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40`. Expected: `value of type 'ConversationEngine' has no member 'tokenBreakdown'`.

- [ ] **Minimal implementation** — add a computed property to `Targets/FoundationChatKit/Sources/Engine/ConversationEngine.swift` (near `reservedReplyTokens`):

```swift
    /// Per-bucket token breakdown for the inspector (Plan 10 WS5), derived from the current
    /// budget snapshot plus the reserved reply headroom.
    public var tokenBreakdown: TokenBreakdown {
        calculator.breakdown(from: budget, replyReserve: settings.reservedReplyTokens)
    }
```

- [ ] **Run the test, expect PASS** — framework: `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`.

- [ ] **Commit:**

```bash
git add Targets/FoundationChatKit/Sources/Engine/ConversationEngine.swift \
        Targets/FoundationChatKit/Tests/ConversationEngineTests.swift
git commit -m "feat(engine): expose tokenBreakdown for the inspector

Computed from the current budget snapshot + reservedReplyTokens via
TokenBudgetCalculator.breakdown.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> Dispatch: Opus 4.8 — fresh session (subagent-driven-development).

---

### Task 5.4 — `TokenMeterView` renders the breakdown + bucket color (thin SwiftUI)

**Files:**
- Modify `Targets/Ember/Sources/TokenMeterView.swift`
- Modify `Targets/Ember/Sources/InspectorPanel.swift`

> Thin binding only — all numbers and the color bucket come from `FoundationChatKit`. The view maps `TokenMeterColorBucket` → SwiftUI `Color` (the only UI-layer logic) and renders a "Where tokens go" section above the existing per-line Breakdown.
>
> **Intentional, documented divergence (do not claim "no divergence"):** the gauge tint now uses the 4-tier `TokenMeterColor` (thresholds 0.5/0.75/0.9) while the warning Label still keys off the existing 3-tier `budget.zone` (amber/red at 0.70/0.90). These are DIFFERENT thresholds on purpose: the gauge gives finer visual gradation; the banner only warns near the limit. At fraction 0.55 the gauge is yellow but no banner shows; at 0.72 the gauge is yellow and the banner shows. A comment in the view records this. Also note: the "Where tokens go" section lists `Reserved for reply` as a real bucket (it is part of `total`), whereas the per-line "Breakdown" section lists only the context-occupying lines (no reserve row). Both are intentional; the reserve is labeled clearly so the two sections don't imply conflicting totals.

- [ ] **Write the failing test** — N/A (SwiftUI view; no framework test target for `Ember`). Verification is the app build. The logic this view depends on is covered by `TokenBreakdownTests` and `TokenBudgetCalculatorTests`. Explicit N/A justification: there is no `Ember`-target unit test harness; rendering correctness is gated by the multi-platform build below.

- [ ] **Run the baseline, expect PASS** — `xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=macOS' build 2>&1 | tail -10` → confirm `BUILD SUCCEEDED` BEFORE editing.

- [ ] **Minimal implementation** — two edits.

(1) Pass the breakdown into the view from `Targets/Ember/Sources/InspectorPanel.swift`. Change the `.tokens` case:

```swift
            case .tokens: TokenMeterView(budget: engine.budget,
                                         reservedReplyTokens: engine.reservedReplyTokens,
                                         breakdown: engine.tokenBreakdown)
```

(2) Replace the body of `Targets/Ember/Sources/TokenMeterView.swift`:

```swift
import SwiftUI
import FoundationChatKit

struct TokenMeterView: View {
    let budget: TokenBudgetSnapshot
    var reservedReplyTokens: Int = 0
    var breakdown: TokenBreakdown? = nil

    var body: some View {
        List {
            Section {
                Gauge(value: budget.fraction) {
                    Text("Context window")
                } currentValueLabel: {
                    Text("\(budget.usedTokens) / \(budget.maxTokens)").monospacedDigit()
                }
                .tint(meterColor)
                Text("\(budget.remaining) tokens remaining" + (budget.isExact ? "" : " · estimated"))
                    .font(.caption).foregroundStyle(.secondary)
                if reservedReplyTokens > 0 {
                    Text("Reserved for reply: \(reservedReplyTokens)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                // Warning banner intentionally uses the 3-tier budget.zone (0.70/0.90), which is a
                // coarser threshold than the 4-tier gauge tint above — the gauge gives fine visual
                // gradation; the banner only warns near the limit.
                if budget.zone != .green {
                    Label(zoneMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(budget.zone == .red ? .red : .orange)
                }
            }
            if let breakdown {
                Section("Where tokens go") {
                    breakdownRow("Instructions", breakdown.instructions)
                    breakdownRow("Tools", breakdown.tools)
                    breakdownRow("History", breakdown.history)
                    breakdownRow("Retrieved memory", breakdown.retrievedMemory)
                    breakdownRow("Reserved for reply", breakdown.replyReserve)
                }
            }
            Section("Breakdown") {
                ForEach(budget.lines) { line in
                    HStack {
                        Text(line.label)
                        Spacer()
                        Text("\(line.tokens)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func breakdownRow(_ label: String, _ tokens: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(tokens)").monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private var zoneMessage: String {
        budget.zone == .red
            ? "Approaching the limit — older turns compact automatically."
            : "Context is filling up."
    }

    /// 4-tier color from the pure FoundationChatKit bucket (green/yellow/orange/red).
    private var meterColor: Color {
        switch TokenMeterColor.for(fraction: budget.fraction) {
        case .green: return .green
        case .yellow: return .yellow
        case .orange: return .orange
        case .red: return .red
        }
    }
}
```

> If `budget.fraction`, `budget.remaining`, or `budget.zone` differ in name in this codebase, match the existing `TokenMeterView` body (this rewrite preserves the original gauge/zone wiring and only swaps the gauge tint to `TokenMeterColor` and adds the breakdown section).

- [ ] **Run the test, expect PASS** — app (macOS): `xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=macOS' build 2>&1 | tail -10` → `BUILD SUCCEEDED`; app (iOS): `xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -10` → `BUILD SUCCEEDED`; framework still green: `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`.

- [ ] **Commit:**

```bash
git add Targets/Ember/Sources/TokenMeterView.swift \
        Targets/Ember/Sources/InspectorPanel.swift
git commit -m "feat(ui): inspector shows 'Where tokens go' breakdown + 4-tier meter color

TokenMeterView renders the per-bucket TokenBreakdown and colors the gauge via
the pure TokenMeterColor (green<.5/yellow<.75/orange<.9/red). The warning banner
keeps the 3-tier budget.zone threshold by design (commented). Logic stays in
FoundationChatKit; the view is a thin binding.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> Dispatch: Sonnet — fresh session (subagent-driven-development).

---

## Self-review

**Outstanding-item → task coverage:**

- [ ] Plan 8 (hybrid retrieval, unbuilt) — **absorbed by WS3** (Tasks 3.1–3.3b: `LexicalScorer`, `MemoryStore.search(... lexicalWeight:)`, settings + retriever/tool wiring). Divergences documented in the header and inline in 3.2.
- [ ] Plan 7 within-window memory accumulation — **partially mitigated by WS2** (2.2 inject-fewer + truncate, 2.4b explicit per-turn budget line). Full ephemeral-injection fix remains documented future work.
- [ ] On-device E2E (Plans 5/6/7/9) — **not addressed** (sim `ModelManagerError 1026`); listed as carried-forward. All WS tasks gate on framework tests, not the sim.
- [ ] Plan 9 Task 4 provenance field, multilingual `NLEmbedding`, per-turn input ceiling, `searchMemory` gating — **not addressed**; noted as carried-forward.

**Workstream → task map:**

- [ ] WS1: 1.1 options factory (w/ readability fallback), 1.2 titler clamp, 1.3 extractor cap, 1.4 summarize options.
- [ ] WS2: 2.1 truncate, 2.2 wrap/augment knobs + split round-trip, 2.3 settings + threshold-assertion migration, 2.4a engine wires knobs + mock lastStreamedPrompt, 2.4b budget-line lifecycle (shared injector in recompute+refresh; clear after refresh).
- [ ] WS3: 3.1 LexicalScorer, 3.2 hybrid search (w==0 delegates verbatim), 3.3a settings + retriever rewrite (real harness, `?? []`, keep diagnostics), 3.3b MemorySearchTool (preserve default 3/0.2).
- [ ] WS4: 4.1 ConversationSummary, 4.2 provider seam (distinct captured field), 4.3 compactor render + harvest + MIGRATE 2 existing ContextCompactorTests + OverflowCompaction scripting, 4.4 engine routes prefs (uses settable mock maxContextTokens).
- [ ] WS5: 5.1 TokenBreakdown + color, 5.2 calculator.breakdown (realistic single-source fixture), 5.3 engine.tokenBreakdown, 5.4 view binding (documented 4-tier/3-tier divergence).

**Convention & gate checks:**

- [ ] **Existing-test migrations are explicit and committed in the same task:** WS2.3 (SupportingTypesTests:17 0.5→0.35), WS4.3 (summarizesOlderKeepsRecent + excludesRetrievedMemoryFromSummaryInput → structured scripting; OverflowCompactionTests dead `summarizeResult`). No appended-only test set leaves the gate red.
- [ ] **All tests written against the REAL surface** (verified by reading source): `makeWithMemory()` 3-tuple, `memory.saveNote`/`saveNoteIfNovel`, `coord.send`, `coord.engine`, `provider.session.scriptedSnapshots`, `provider.maxContextTokens` (settable), `MockSessionHandle.stream(prompt:)`, `MemoryStore.search(...preferNotes:)`, `MemorySearchTool` defaults (3/0.2). No invented helpers (`makeCoordinatorWithMemory`, `activeEngineForTesting`, `providerSession`, `overrideMaxContextTokens`) remain.
- [ ] **Verified APIs honored; uncertain APIs carry fallbacks:** `.greedy`/`temperature:0` (greedy fallback → drop sampling), `.maximumCount(5)` (fallback → code-side `prefix` cap), `GenerationOptions` property readability (fallback → construction-only test), `tokenCount(for:)` only `Instructions` overload (engine uses existing `exactTokenCount`/`tokenCount` seam, not new overloads), `contextSize` synchronous (unchanged usage via `maxContextTokens`).
- [ ] **Hard dependency order stated:** WS4 needs WS1 (no inline-TODO escape hatch), WS5 needs WS2. Each WS that touches the app ends with an app build; no new `ChatError` case, so `ErrorBanner`'s exhaustive switch is untouched.
- [ ] **`tuist generate --no-open` precedes xcodebuild on every file-adding task** (1.1, 3.1, 4.1, 5.1) and is called out in their run steps.
- [ ] **CANONICAL NAMES verbatim:** `memoryInjectionMaxHits`/`memoryInjectionMaxCharsPerHit`/`memoryRetrievalThreshold`(0.35), `wrap(_:maxHits:maxCharsPerHit:)`/`augment(prompt:with:maxHits:maxCharsPerHit:)`/`truncate(_:maxChars:)`, `LexicalScorer.score(query:text:)`, `hybridLexicalWeight`(0.5), `ConversationSummary`(`summary`/`keyTopics`/`userPreferences`)/`summarizeStructured`, `TokenBreakdown`(5 fields + `total`)/`TokenMeterColor.for(fraction:)`.
- [ ] **Every task has the 5 TDD step types** (or an explicit, justified N/A for the two real-model/SwiftUI cases) **+ a `> Dispatch:` line.** Tasks 2.4 and 3.3 were SPLIT (2.4a/2.4b, 3.3a/3.3b) per critic feedback.
- [ ] No placeholders: every test body and implementation is shown in full; no "TBD"/"similar to"/inline-`// TODO` escape hatches remain.