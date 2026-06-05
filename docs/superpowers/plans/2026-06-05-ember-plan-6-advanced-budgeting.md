# Ember — Plan 6: Advanced Budgeting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace keep-first-last overflow recovery with model-summarized compaction, and proactively reserve reply headroom — compacting *before* a turn would overflow.

**Architecture:** A `summarize` provider-seam method (real = throwaway session; mock = scripted) feeds a `ContextCompactor` that keeps recent turns + a model summary, falling back to `OverflowRecovery.condense`. `ConversationEngine` compacts proactively (pre-turn, when `used + prompt + reserve > max`) and reactively (on overflow), both via the existing `makeSession(seeding:)` path. No schema change.

**Tech Stack:** Swift 6, FoundationModels, SwiftData, Tuist, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-06-05-ember-advanced-budgeting-design.md`

---

## Conventions for the executing engineer
- **Branch:** `plan-6-budgeting` (already created off `plan-5-rag`; the spec is already committed here).
- **TDD** for all `FoundationChatKit` logic (S, T, U). App view change (V) verified by **build**; W by **running**.
- **Tuist:** after creating/deleting any file run `tuist generate --no-open` before building/testing.
- **Framework test:** `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`.
- **Build app (macOS):** `xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=macOS' build 2>&1 | tail -10`.
- **Build app (iOS):** `xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -10`.
- Swift Testing (`import Testing`); `@testable import FoundationChatKit`. Sandbox failure → retry Bash with `dangerouslyDisableSandbox: true`. SourceKit "No such module"/"cannot find type" are false — trust xcodebuild.
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **Current API (do not break):** `GenerationSettings(instructions:temperature:maximumResponseTokens:)`; `ChatModelProvider` (availability, maxContextTokens, tokenCount, exactTokenCount, makeSession×2, generateTitle); `OverflowRecovery.condense(_:)`; `ConversationEngine` (send, cancel, budget, refreshExactBudget); `TokenBudgetCalculator.snapshot(...)`.

---

## File structure
```
FoundationChatKit/Sources/
  Model/GenerationSettings.swift     # MODIFY + reservedReplyTokens
  Tokens/TokenBudgetCalculator.swift # MODIFY + estimate(_:) passthrough
  Provider/ChatModelProvider.swift   # MODIFY + summarize(_:) async
  Provider/FoundationModelProvider.swift # MODIFY summarize via throwaway session
  Context/ContextCompactor.swift     # NEW model-summarized compaction (+ condense fallback)
  Engine/ConversationEngine.swift    # MODIFY proactive + reactive compaction; reservedReplyTokens
FoundationChatKit/Tests/
  AdvancedBudgetingTests.swift (new)  ContextCompactorTests.swift (new)
  OverflowCompactionTests.swift (new)  MockModelProvider.swift (extend)
Ember/Sources/
  TokenMeterView.swift (reserved line)  InspectorPanel.swift (pass reservedReplyTokens)
```

---

## Milestone S — Settings + summarize seam

### Task S1: `reservedReplyTokens` + `TokenBudgetCalculator.estimate`

**Files:**
- Modify: `Targets/FoundationChatKit/Sources/Model/GenerationSettings.swift`, `Tokens/TokenBudgetCalculator.swift`
- Test: `Targets/FoundationChatKit/Tests/AdvancedBudgetingTests.swift` (new)

- [ ] **Step 1: Write the failing test** — `AdvancedBudgetingTests.swift`:
```swift
import Testing
@testable import FoundationChatKit

struct AdvancedBudgetingTests {
    @Test func reservedReplyTokensDefaultAndCustom() {
        #expect(GenerationSettings().reservedReplyTokens == 512)
        #expect(GenerationSettings(reservedReplyTokens: 256).reservedReplyTokens == 256)
    }
    @Test func calculatorEstimateMatchesEstimator() {
        #expect(TokenBudgetCalculator().estimate("hello world") == TokenEstimator().estimate("hello world"))
    }
}
```

- [ ] **Step 2: Run → FAIL** — `tuist generate --no-open`, framework test command. Expected: no `reservedReplyTokens` / no `estimate`.

- [ ] **Step 3a: `GenerationSettings`** — replace the struct body to add the field + init param:
```swift
public struct GenerationSettings: Sendable, Equatable {
    public var instructions: String?
    public var temperature: Double?
    public var maximumResponseTokens: Int?
    public var reservedReplyTokens: Int
    public init(instructions: String? = nil, temperature: Double? = nil,
                maximumResponseTokens: Int? = nil, reservedReplyTokens: Int = 512) {
        self.instructions = instructions
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
        self.reservedReplyTokens = reservedReplyTokens
    }
}
```

- [ ] **Step 3b: `TokenBudgetCalculator`** — add a public passthrough (after `init`):
```swift
    /// Estimate tokens for a single string (used for proactive pre-turn budgeting).
    public func estimate(_ text: String) -> Int { estimator.estimate(text) }
```

- [ ] **Step 4: Run → PASS** — framework test command → `** TEST SUCCEEDED **` (existing `GenerationSettings(...)` callers still compile via the defaulted param).

- [ ] **Step 5: Commit**
```bash
git add Targets/FoundationChatKit
git commit -m "feat(kit): reservedReplyTokens setting + calculator.estimate passthrough

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task S2: `ChatModelProvider.summarize` seam

**Files:**
- Modify: `Targets/FoundationChatKit/Sources/Provider/ChatModelProvider.swift`, `Provider/FoundationModelProvider.swift`, `Tests/MockModelProvider.swift`
- Test: `Targets/FoundationChatKit/Tests/AdvancedBudgetingTests.swift` (extend)

- [ ] **Step 1: Add the failing test** (append inside `AdvancedBudgetingTests`):
```swift
    @MainActor @Test func mockSummarizeReturnsScripted() async {
        let p = MockModelProvider()
        p.summarizeResult = "A short summary."
        #expect(await p.summarize("a long conversation") == "A short summary.")
        let q = MockModelProvider()
        #expect(await q.summarize("anything") == nil)
    }
```

- [ ] **Step 2: Run → FAIL** — framework test command. Expected: no `summarize` / `summarizeResult`.

- [ ] **Step 3a: Protocol** — in `ChatModelProvider.swift`, add to the `ChatModelProvider` protocol (after `generateTitle`):
```swift
    /// Summarize free text via the model (throwaway session). Returns nil when unavailable/failed.
    func summarize(_ text: String) async -> String?
```

- [ ] **Step 3b: Real provider** — in `FoundationModelProvider.swift`, add (after `generateTitle`):
```swift
    public func summarize(_ text: String) async -> String? {
        guard case .available = availability else { return nil }
        let session = LanguageModelSession(
            instructions: "You compress chat history into a brief, factual summary.")
        do {
            let response = try await session.respond(
                to: "Summarize the following conversation in a few sentences, preserving names, facts, and decisions:\n\(text)")
            let summary = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return summary.isEmpty ? nil : summary
        } catch {
            return nil
        }
    }
```

- [ ] **Step 3c: Mock** — in `MockModelProvider.swift`, add to `MockModelProvider`:
```swift
    var summarizeResult: String?
```
```swift
    func summarize(_ text: String) async -> String? { summarizeResult }
```

- [ ] **Step 4: Run → PASS** — framework test command → `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**
```bash
git add Targets/FoundationChatKit
git commit -m "feat(kit): provider summarize seam (throwaway session + mock)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone T — ContextCompactor

### Task T1: `ContextCompactor` (model summary + fallback)

**Files:**
- Create: `Targets/FoundationChatKit/Sources/Context/ContextCompactor.swift`
- Test: `Targets/FoundationChatKit/Tests/ContextCompactorTests.swift` (new)

- [ ] **Step 1: Write the failing test** — `ContextCompactorTests.swift`:
```swift
import Testing
import Foundation
@testable import FoundationChatKit

@MainActor
struct ContextCompactorTests {
    private func entries(_ n: Int) -> [ContextEntry] {
        (0..<n).map { ContextEntry(kind: $0 % 2 == 0 ? .userPrompt : .modelResponse, text: "msg\($0)") }
    }
    @Test func summarizesOlderKeepsRecent() async {
        let p = MockModelProvider(); p.summarizeResult = "RECAP"
        let result = await ContextCompactor.compact(entries(10), keepingRecent: 4, using: p)
        #expect(result.count == 5)                       // 1 recap + 4 recent
        #expect(result.first?.kind == .instructions)
        #expect(result.first?.text.contains("RECAP") == true)
        #expect(result.last?.text == "msg9")
    }
    @Test func fallsBackToCondenseWhenSummaryNil() async {
        let p = MockModelProvider(); p.summarizeResult = nil
        let input = entries(10)
        let result = await ContextCompactor.compact(input, keepingRecent: 4, using: p)
        #expect(result == OverflowRecovery.condense(input))
    }
    @Test func shortInputUnchanged() async {
        let p = MockModelProvider(); p.summarizeResult = "RECAP"
        let input = entries(3)
        #expect(await ContextCompactor.compact(input, keepingRecent: 4, using: p) == input)
    }
}
```

- [ ] **Step 2: Run → FAIL** — `tuist generate --no-open`, framework test command. Expected: `ContextCompactor` not found.

- [ ] **Step 3: Implement `ContextCompactor.swift`**:
```swift
import Foundation

/// Phase 3 context compaction: keep the most recent `keepingRecent` entries verbatim and replace
/// the older ones with a single model-generated recap. Falls back to `OverflowRecovery.condense`
/// (deterministic first+last) when the summary is unavailable, so it never blocks a turn.
public enum ContextCompactor {
    @MainActor
    public static func compact(_ entries: [ContextEntry], keepingRecent: Int = 4,
                               using provider: any ChatModelProvider) async -> [ContextEntry] {
        guard entries.count > keepingRecent else { return entries }
        let older = entries.prefix(entries.count - keepingRecent)
        let recent = Array(entries.suffix(keepingRecent))
        let text = older.map { entry -> String in
            let who: String
            switch entry.kind {
            case .userPrompt: who = "User"
            case .modelResponse: who = "Assistant"
            case .instructions: who = "System"
            case .toolCall: who = "Tool call"
            case .toolOutput: who = "Tool output"
            }
            return "\(who): \(entry.text)"
        }.joined(separator: "\n")
        guard let summary = await provider.summarize(text), !summary.isEmpty else {
            return OverflowRecovery.condense(entries)
        }
        let recap = ContextEntry(kind: .instructions, text: "Summary of earlier conversation: \(summary)")
        return [recap] + recent
    }
}
```

- [ ] **Step 4: Run → PASS** — framework test command → `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**
```bash
git add Targets/FoundationChatKit
git commit -m "feat(kit): ContextCompactor (model-summarized compaction + fallback)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone U — Engine integration (proactive + reactive)

### Task U1: Proactive + reactive compaction in `ConversationEngine`

**Files:**
- Modify: `Targets/FoundationChatKit/Sources/Engine/ConversationEngine.swift`
- Test: `Targets/FoundationChatKit/Tests/OverflowCompactionTests.swift` (new)

- [ ] **Step 1: Write the failing tests** — `OverflowCompactionTests.swift`:
```swift
import Testing
import Foundation
@testable import FoundationChatKit

@MainActor
struct OverflowCompactionTests {
    @Test func proactivelyCompactsBeforeOverflow() async {
        let provider = MockModelProvider()
        provider.maxContextTokens = 60
        provider.summarizeResult = "RECAP"
        let seeded = (0..<8).map { ContextEntry(kind: .userPrompt, text: "some earlier message number \($0)") }
        provider.session.contextEntries = seeded
        provider.session.scriptedSnapshots = ["ok"]
        let engine = ConversationEngine(
            provider: provider,
            settings: GenerationSettings(instructions: "sys", reservedReplyTokens: 20),
            restoringEntries: seeded,
            now: { Date(timeIntervalSince1970: 0) })
        await engine.send("a brand new question that needs room")
        #expect(engine.messages.contains { $0.role == .systemNotice && $0.text.contains("summarized to make room") })
    }
    @Test func reactiveRecoveryUsesCompactor() async {
        let provider = MockModelProvider()
        provider.summarizeResult = "RECAP"
        let seeded = (0..<8).map { ContextEntry(kind: .userPrompt, text: "m\($0)") }
        provider.session.contextEntries = seeded
        provider.session.scriptedSnapshots = ["partial"]
        provider.session.scriptedError = ChatError.contextOverflow
        provider.session.errorAfter = 1
        let engine = ConversationEngine(provider: provider, restoringEntries: seeded,
                                        now: { Date(timeIntervalSince1970: 0) })
        await engine.send("hi")
        #expect(engine.messages.contains { $0.role == .systemNotice && $0.text.contains("compacted to keep the chat going") })
    }
}
```

- [ ] **Step 2: Run → FAIL** — `tuist generate --no-open`, framework test command. Expected: no proactive "summarized to make room" notice.

- [ ] **Step 3a: Add `reservedReplyTokens` accessor** — in `ConversationEngine.swift`, after `encodedTranscript`:
```swift
    /// Tokens kept free for the model's reply (drives proactive compaction + the Tokens tab).
    public var reservedReplyTokens: Int { settings.reservedReplyTokens }
```

- [ ] **Step 3b: Proactive compaction** — in `performTurn`, add the call right after `defer { isResponding = false }` and before `let userMessage`:
```swift
        await compactIfNeeded(for: prompt)
```
Add the method (after `recoverFromOverflow`):
```swift
    /// Compact proactively when the projected turn (current context + this prompt + the reserved
    /// reply headroom) would exceed the window, so the reply always has room.
    private func compactIfNeeded(for prompt: String) async {
        let projected = budget.usedTokens + calculator.estimate(prompt) + settings.reservedReplyTokens
        guard projected > provider.maxContextTokens, session.contextEntries.count > 1 else { return }
        let condensed = await ContextCompactor.compact(session.contextEntries, using: provider)
        session = provider.makeSession(settings: settings, tools: tools, seeding: condensed)
        let notice = ChatMessage(role: .systemNotice,
                                 text: "Older turns were summarized to make room.",
                                 createdAt: now())
        messages.append(notice)
        persistence?.recordMessage(notice)
        recomputeBudget(inFlight: nil)
        persistence?.recordResumeState(session.encodedTranscript(), budget.usedTokens)
    }
```

- [ ] **Step 3c: Reactive recovery via the compactor** — make `recoverFromOverflow` async and use `ContextCompactor`. Replace its first line:
```swift
    private func recoverFromOverflow() async {
        let condensed = await ContextCompactor.compact(session.contextEntries, using: provider)
```
(leave the rest of the method body unchanged: rebuild session, append the "compacted to keep the chat going" notice, recompute, persist.)

- [ ] **Step 3d: Make `handle` async** — change its signature and the overflow case, and the call site:
  - Signature: `private func handle(_ error: Error, assistantIndex: Int) async {`
  - Overflow case: `case .contextOverflow: await recoverFromOverflow()`
  - Call site in `performTurn`'s final `catch`: `} catch { await handle(error, assistantIndex: assistantIndex) }`

- [ ] **Step 4: Run → PASS** — framework test command → `** TEST SUCCEEDED **` (both new tests pass; all prior engine tests still green — proactive only fires when over budget, so normal-size turns are unaffected).

- [ ] **Step 5: Commit**
```bash
git add Targets/FoundationChatKit
git commit -m "feat(kit): proactive + reactive model-summarized compaction in the engine

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone V — Tokens tab reserved line (build)

### Task V1: Show "Reserved for reply" in `TokenMeterView`

**Files:**
- Modify: `Targets/Ember/Sources/TokenMeterView.swift`, `Targets/Ember/Sources/InspectorPanel.swift`

- [ ] **Step 1: `TokenMeterView`** — add a defaulted parameter and a row. Change the declaration:
```swift
struct TokenMeterView: View {
    let budget: TokenBudgetSnapshot
    var reservedReplyTokens: Int = 0
```
In the first `Section`, immediately after the `"\(budget.remaining) tokens remaining…"` Text, add:
```swift
                if reservedReplyTokens > 0 {
                    Text("Reserved for reply: \(reservedReplyTokens)")
                        .font(.caption).foregroundStyle(.secondary)
                }
```

- [ ] **Step 2: `InspectorPanel`** — pass the engine's value. Change the `TokenMeterView(budget: engine.budget)` call to:
```swift
                TokenMeterView(budget: engine.budget, reservedReplyTokens: engine.reservedReplyTokens)
```

- [ ] **Step 3: Build both platforms** — `tuist generate --no-open`; macOS + iOS app builds → `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**
```bash
git add Targets/Ember
git commit -m "feat(app): show reserved-for-reply tokens in the Tokens tab

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone W — Run verification + finalize

### Task W1: Run, exercise compaction, finalize

- [ ] **Step 1: Full test + both builds**
```bash
xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -5
xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=macOS' build 2>&1 | tail -3
xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -3
```
All three must succeed.

- [ ] **Step 2: Run on the iOS simulator**
```bash
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null || true
xcodebuild -workspace Ember.xcworkspace -scheme Ember -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/ember-ios-p6 build 2>&1 | tail -3
APP=$(find /tmp/ember-ios-p6/Build/Products -name "Ember.app" -maxdepth 3 | head -1)
xcrun simctl install booted "$APP"; xcrun simctl launch booted dev.iosunpi.ember; sleep 6
xcrun simctl io booted screenshot /tmp/ember-p6-ios.png
```
Verify (xcodebuildmcp `describe_ui`/`tap`/`type_text`/`screenshot`): the app launches and a normal turn still works; open the Tokens tab and confirm the **"Reserved for reply: 512"** line shows. Proactive compaction is hard to trigger by hand (needs a near-4096 context) — it is covered by the unit tests; record the launch + Tokens-tab screenshot as the artifact.

- [ ] **Step 3: Final commit + tag**
```bash
git commit --allow-empty -m "chore: Plan 6 complete — advanced budgeting (Phase 3 done)

Model-summarized context compaction (ContextCompactor + provider.summarize, with
keep-first-last fallback) and reserve-for-reply: proactive pre-turn compaction +
upgraded reactive recovery; reservedReplyTokens setting + Tokens-tab line.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git tag plan-6-budgeting-complete
```

- [ ] **Step 4: PR** — push and open (base `plan-5-rag` while the stack is unmerged; retarget to `main` as it merges):
```bash
git push -u origin plan-6-budgeting
gh pr create --base plan-5-rag --head plan-6-budgeting --title "Plan 6 — Advanced budgeting" --body "Model-summarized context compaction (ContextCompactor + provider.summarize seam, keep-first-last fallback) and reserve-for-reply: proactive pre-turn compaction + upgraded reactive recovery; reservedReplyTokens setting + Tokens-tab line. All FoundationChatKit logic TDD; app build-verified. Completes roadmap Phase 3. Stacked on #5."
```

---

## Self-review (author check against spec)

**Spec coverage (spec §):**
- §3 `reservedReplyTokens` → S1; `summarize` seam (protocol+real+mock) → S2; `ContextCompactor` (summary + condense fallback) → T1; engine proactive + reactive (reuse `makeSession(seeding:)`) + `reservedReplyTokens` accessor → U1; Tokens-tab reserved line → V1. ✓
- §3 fallback to `OverflowRecovery.condense` → T1 (`fallsBackToCondenseWhenSummaryNil`). ✓
- §4 no schema change → no model edits. ✓
- §5 tests → AdvancedBudgetingTests, ContextCompactorTests, OverflowCompactionTests, MockModelProvider extension. ✓
- §1 per-turn input ceiling omitted (YAGNI) — intentional, stated. ✓

**Placeholder scan:** none. Every code step shows full code.

**Type consistency:** `reservedReplyTokens` defined in `GenerationSettings` (S1), read by the engine accessor + `compactIfNeeded` (U1) and `TokenMeterView` via `engine.reservedReplyTokens` (V1). `summarize(_:) async -> String?` identical across protocol/real/mock (S2) and consumed by `ContextCompactor` (T1). `ContextCompactor.compact(_:keepingRecent:using:)` defined T1, called in `compactIfNeeded` + `recoverFromOverflow` (U1). `TokenBudgetCalculator.estimate(_:)` defined S1, used in `compactIfNeeded` (U1). `handle` made `async` with the overflow case awaiting `recoverFromOverflow` (U1).

**Ordering:** S (settings + seam — defaulted, no breaks) → T (compactor) → U (engine wiring) → V (app build) → W (run). Each task ends green/committed; `reservedReplyTokens` defaulting keeps existing `GenerationSettings(...)` call sites compiling.
