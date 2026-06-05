# Ember — Plan 4: Hardening & Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden and polish Ember — exact async token counts (+ fix the double-"Instructions" budget line), deep producer cancellation, live availability reactivity, Markdown rendering, conversation rename, and search — plus the titling-robustness follow-ups from the Plan 3 review.

**Architecture:** Extend the existing `ChatModelProvider` seam (`exactTokenCount(for:) async`), the engine (`refreshExactBudget()`), and the coordinator (stored availability, `isProcessing`, rename, search) — all mock-testable. The real provider gains producer-cancellation via `AsyncThrowingStream.onTermination`. Markdown is a unit-tested pure parser (`MarkdownBlocks`) + a SwiftUI renderer. One additive SwiftData field (`Conversation.titleIsCustom`).

**Tech Stack:** Swift 6, FoundationModels, SwiftData, SwiftUI, Tuist, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-06-05-ember-hardening-and-polish-design.md`

---

## Conventions for the executing engineer
- **Branch:** `plan-4-hardening` (already created off `plan-3-tools`; the spec is already committed here).
- **TDD** for all `FoundationChatKit` logic (H, I, K, L parser, M1). SwiftUI changes (J, K UI, L renderer) are verified by **build**; M2 verifies by **running**.
- **Tuist:** after creating/deleting any file run `tuist generate --no-open` before building/testing.
- **Framework test:** `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`.
- **Build app (macOS):** `xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=macOS' build 2>&1 | tail -10` → `** BUILD SUCCEEDED **`.
- **Build app (iOS):** `xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -10`.
- Swift Testing (`import Testing`); `@testable import FoundationChatKit`. Sandbox failure → retry Bash with `dangerouslyDisableSandbox: true`; real failure → BLOCKED with output. SourceKit "No such module"/"cannot find type" are false — trust xcodebuild.
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **Current API (post-Plan-3, do not break):** `ChatModelProvider` (`availability`, `maxContextTokens`, `tokenCount(for:)`, `makeSession(settings:tools:restoring:)`, `makeSession(settings:tools:seeding:)`, `generateTitle(forFirstExchange:)`); `ConversationEngine.init(provider:settings:restoring:restoringEntries:tools:persistence:calculator:now:)`; `TokenBudgetCalculator.snapshot(maxTokens:instructions:entries:inFlight:tools:exactCount:)`; `ConversationStore` (`allConversations`,`createConversation`,`appendMessage`,`updateResumeState`,`setTitle(_:for:)`,`delete`,`contextEntries(for:)`); `ChatCoordinator` (`conversations`,`engine`,`selectedID`,`availability`,`reload`,`newConversation`,`select`,`deleteConversation`,`send`).

---

## File structure
```
FoundationChatKit/Sources/
  Tokens/TokenBudgetCalculator.swift     # MODIFY: instructions de-dupe
  Provider/ChatModelProvider.swift       # MODIFY: + exactTokenCount(for:) async
  Provider/FoundationModelProvider.swift # MODIFY: exact count; producer cancel; title availability pre-check
  Engine/ConversationEngine.swift        # MODIFY: refreshExactBudget(); call post-turn
  App/ChatCoordinator.swift              # MODIFY: stored availability + refreshAvailability; isProcessing; rename; search; no-clobber
  Persistence/ConversationStore.swift    # MODIFY: search(_:); setTitle(_:for:custom:)
  Persistence/Conversation.swift         # MODIFY: + titleIsCustom
  Markdown/MarkdownBlocks.swift          # NEW: pure parser
  Tools/CalculatorTool.swift             # MODIFY: format polish
FoundationChatKit/Tests/
  TokenBudgetCalculatorTests.swift (extend)  ExactBudgetTests.swift (new)
  CancellationTests.swift (new)  ConversationStoreTests.swift (extend)
  ChatCoordinatorTests.swift (extend)  MarkdownBlocksTests.swift (new)
  CalculatorToolTests.swift (extend)  MockModelProvider.swift (extend)
Ember/Sources/
  RootView.swift (scenePhase refresh)  UnavailableView.swift (Retry)
  ConversationListView.swift (rename alert + .searchable + visibleConversations)
  ComposerView.swift (disable on isProcessing)  MessageBubble.swift (assistant -> MarkdownText)
  MarkdownText.swift (NEW renderer)
```

---

## Milestone H — Exact tokens + instructions de-dupe (TDD)

### Task H1: De-dupe the Instructions budget line

**Files:**
- Modify: `Targets/FoundationChatKit/Sources/Tokens/TokenBudgetCalculator.swift`
- Test: `Targets/FoundationChatKit/Tests/TokenBudgetCalculatorTests.swift` (extend)

- [ ] **Step 1: Add failing tests** (append inside the existing test type):
```swift
    @Test func instructionsCountedOnceWhenEntryPresent() {
        let calc = TokenBudgetCalculator()
        let snap = calc.snapshot(
            maxTokens: 4096, instructions: "sys",
            entries: [ContextEntry(kind: .instructions, text: "sys"),
                      ContextEntry(kind: .userPrompt, text: "hi")],
            inFlight: nil, exactCount: { _ in nil })
        #expect(snap.lines.filter { $0.label == "Instructions" }.count == 1)
    }
    @Test func instructionsLineShownWhenNoEntry() {
        let calc = TokenBudgetCalculator()
        let snap = calc.snapshot(
            maxTokens: 4096, instructions: "sys",
            entries: [ContextEntry(kind: .userPrompt, text: "hi")],
            inFlight: nil, exactCount: { _ in nil })
        #expect(snap.lines.contains { $0.label == "Instructions" })
    }
```

- [ ] **Step 2: Run → FAIL** (`instructionsCountedOnceWhenEntryPresent` finds 2 lines). Run the framework test command.

- [ ] **Step 3: Implement** — in `snapshot`, replace the instructions block:
```swift
        let hasInstructionEntry = entries.contains { $0.kind == .instructions }
        if let instructions, !instructions.isEmpty, !hasInstructionEntry {
            add("Instructions", instructions)
        }
```

- [ ] **Step 4: Run → PASS** (framework test command → `** TEST SUCCEEDED **`).

- [ ] **Step 5: Commit**
```bash
git add Targets/FoundationChatKit
git commit -m "fix(kit): count instructions once in the token budget

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task H2: Exact async token counts

**Files:**
- Modify: `Targets/FoundationChatKit/Sources/Provider/ChatModelProvider.swift`, `Provider/FoundationModelProvider.swift`, `Engine/ConversationEngine.swift`, `Tests/MockModelProvider.swift`
- Test: `Targets/FoundationChatKit/Tests/ExactBudgetTests.swift` (new)

> Verify the exact overload before implementing: `fetchAppleDocumentation /documentation/foundationmodels/systemlanguagemodel/tokencount(for:)`. It is `async throws`; use the `String` overload.

- [ ] **Step 1: Write the failing test** — `ExactBudgetTests.swift`:
```swift
import Testing
import Foundation
@testable import FoundationChatKit

@MainActor
struct ExactBudgetTests {
    @Test func turnRefreshesToExactWhenAvailable() async {
        let provider = MockModelProvider()
        provider.exactAsyncCount = true
        provider.session.scriptedSnapshots = ["hello"]
        let engine = ConversationEngine(provider: provider,
                                        settings: GenerationSettings(instructions: "sys"),
                                        now: { Date(timeIntervalSince1970: 0) })
        await engine.send("hi")
        #expect(engine.budget.isExact == true)
        #expect(engine.budget.usedTokens > 0)
    }
    @Test func turnStaysEstimatedWhenExactUnavailable() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["hello"]
        let engine = ConversationEngine(provider: provider,
                                        settings: GenerationSettings(instructions: "sys"),
                                        now: { Date(timeIntervalSince1970: 0) })
        await engine.send("hi")
        #expect(engine.budget.isExact == false)
    }
}
```

- [ ] **Step 2: Run → FAIL** (`exactAsyncCount`/`exactTokenCount`/`refreshExactBudget` not found). Run `tuist generate --no-open` then the framework test command.

- [ ] **Step 3a: Protocol** — in `ChatModelProvider.swift`, add to the `ChatModelProvider` protocol (after `tokenCount(for:)`):
```swift
    /// Exact token count for `text` via the async SDK API (26.4+); nil when unavailable.
    func exactTokenCount(for text: String) async -> Int?
```

- [ ] **Step 3b: Real provider** — in `FoundationModelProvider.swift`, add after `tokenCount(for:)`:
```swift
    public func exactTokenCount(for text: String) async -> Int? {
        if #available(iOS 26.4, macOS 26.4, *) {
            return try? await model.tokenCount(for: text)
        }
        return nil
    }
```

- [ ] **Step 3c: Mock** — in `MockModelProvider.swift`, add a flag and method to `MockModelProvider`:
```swift
    var exactAsyncCount: Bool = false
```
```swift
    func exactTokenCount(for text: String) async -> Int? {
        (exactCounts || exactAsyncCount) ? text.count : nil
    }
```

- [ ] **Step 3d: Engine** — in `ConversationEngine.swift`, add this method (after `recomputeBudget`):
```swift
    /// Recompute the budget using exact async token counts (26.4+). Reuses the synchronous
    /// snapshot with a prefilled cache, so there is no duplicated budget logic. Called after a
    /// turn completes; live typing keeps the estimator. Falls back to estimates per-string when
    /// the exact API is unavailable.
    public func refreshExactBudget() async {
        let providerRef = provider
        var cache: [String: Int] = [:]
        func fill(_ s: String) async {
            guard !s.isEmpty, cache[s] == nil else { return }
            if let n = await providerRef.exactTokenCount(for: s) { cache[s] = n }
        }
        if let instructions = settings.instructions { await fill(instructions) }
        for entry in session.contextEntries { await fill(entry.text) }
        for tool in toolAccounting { await fill(tool.schemaDigest) }
        budget = calculator.snapshot(
            maxTokens: providerRef.maxContextTokens,
            instructions: settings.instructions,
            entries: session.contextEntries,
            inFlight: nil,
            tools: toolAccounting,
            exactCount: { cache[$0] }
        )
    }
```
Then call it after finalize in `performTurn`. Change the success branch and the cancel branch so each ends with a refresh:
```swift
            if assistantIndex < messages.count { messages[assistantIndex].isStreaming = false }
            recomputeBudget(inFlight: nil)
            finalizeAssistant(at: assistantIndex)
            await refreshExactBudget()
        } catch is CancellationError {
            if assistantIndex < messages.count { messages[assistantIndex].isStreaming = false }
            finalizeAssistant(at: assistantIndex)
            await refreshExactBudget()
        } catch {
```

- [ ] **Step 4: Run → PASS** (framework test command → `** TEST SUCCEEDED **`; all prior tests still pass — every other `ChatModelProvider` conformer is the mock + real, both updated).

- [ ] **Step 5: Commit**
```bash
git add Targets/FoundationChatKit
git commit -m "feat(kit): exact async token counts (refreshExactBudget post-turn)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone I — Deep producer cancellation (TDD + build)

### Task I1: Cancel the producer on stream termination

**Files:**
- Modify: `Targets/FoundationChatKit/Sources/Provider/FoundationModelProvider.swift`
- Test: `Targets/FoundationChatKit/Tests/CancellationTests.swift` (new)

> The producer-cancel wiring is real-provider-only (needs a model), so it is **build-verified** + confirmed at runtime in Milestone M (Stop button). The test here locks the engine's mid-stream cancellation handling (partial kept, graceful).

- [ ] **Step 1: Write the failing test** — `CancellationTests.swift`:
```swift
import Testing
import Foundation
@testable import FoundationChatKit

@MainActor
struct CancellationTests {
    @Test func cancellationMidStreamKeepsPartial() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["partial", "partial full"]
        provider.session.scriptedError = CancellationError()
        provider.session.errorAfter = 1
        let engine = ConversationEngine(provider: provider, now: { Date(timeIntervalSince1970: 0) })
        await engine.send("hi")
        #expect(engine.isResponding == false)
        #expect(engine.lastError == nil)
        let assistant = engine.messages.last(where: { $0.role == .assistant })
        #expect(assistant?.text == "partial")
        #expect(assistant?.isStreaming == false)
    }
}
```

- [ ] **Step 2: Run → confirm behavior** — run `tuist generate --no-open` then the framework test command. This test passes against the current engine (it already catches `CancellationError`); if it FAILS, fix the engine's cancel handling first. Either way, proceed to harden the real producer.

- [ ] **Step 3: Implement producer cancellation** — in `FoundationModelProvider.swift`, replace `FoundationModelSession.stream` with:
```swift
    func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        let session = self.session
        let options = self.options
        return AsyncThrowingStream { continuation in
            let producer = Task { @MainActor in
                do {
                    let responseStream = session.streamResponse(to: Prompt(prompt), options: options)
                    for try await snapshot in responseStream {
                        if Task.isCancelled { break }
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
```

- [ ] **Step 4: Run → PASS + build** — framework test command → `** TEST SUCCEEDED **`; macOS app build → `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**
```bash
git add Targets/FoundationChatKit
git commit -m "feat(kit): cancel the on-device stream producer on Stop

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone J — Availability reactivity (TDD + build)

### Task J1: Stored availability + refresh + Retry

**Files:**
- Modify: `Targets/FoundationChatKit/Sources/App/ChatCoordinator.swift`, `Provider/FoundationModelProvider.swift`, `Targets/Ember/Sources/RootView.swift`, `Targets/Ember/Sources/UnavailableView.swift`
- Test: `Targets/FoundationChatKit/Tests/ChatCoordinatorTests.swift` (extend)

- [ ] **Step 1: Write the failing test** (append inside `ChatCoordinatorTests`):
```swift
    @Test func refreshAvailabilityPicksUpProviderChange() throws {
        let (coord, provider) = try make()
        #expect(coord.availability == .available)
        provider.availability = .unavailable(.modelNotReady)
        coord.refreshAvailability()
        #expect(coord.availability == .unavailable(.modelNotReady))
    }
```
> If `ModelAvailability` is not `Equatable`, add `Equatable` conformance to it (and `ModelUnavailableReason`); it is a simple enum. Verify with the build.

- [ ] **Step 2: Run → FAIL** (`availability` is a computed passthrough; `refreshAvailability` not found). Run `tuist generate --no-open` then the framework test command.

- [ ] **Step 3a: Coordinator** — in `ChatCoordinator.swift`, replace the computed `availability` line `public var availability: ModelAvailability { provider.availability }` with a stored property + refresh. Add the stored property near the other `public private(set)` vars:
```swift
    public private(set) var availability: ModelAvailability
```
Initialize it in `init` (add right after `self.now = now`, before `reload()`):
```swift
        self.availability = provider.availability
```
Add the method (after `reload()`):
```swift
    public func refreshAvailability() {
        availability = provider.availability
    }
```

- [ ] **Step 3b: Title availability pre-check** — in `FoundationModelProvider.swift`, replace `generateTitle` body:
```swift
    public func generateTitle(forFirstExchange exchange: TitleSeed) async -> String? {
        guard case .available = availability else { return nil }
        return await ConversationTitler.generate(from: exchange)
    }
```

- [ ] **Step 3c: RootView** — replace `RootView.swift` body to re-check on scene activation and pass a retry:
```swift
import SwiftUI
import FoundationChatKit

struct RootView: View {
    let coordinator: ChatCoordinator
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch coordinator.availability {
            case .available:
                ChatScene(coordinator: coordinator)
            case .unavailable(let reason):
                UnavailableView(reason: reason) { coordinator.refreshAvailability() }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { coordinator.refreshAvailability() }
        }
    }
}
```

- [ ] **Step 3d: UnavailableView** — add a `retry` closure and a Retry button. Change the declaration `let reason: ModelUnavailableReason` to also accept retry, and add the button in `actions`:
```swift
    let reason: ModelUnavailableReason
    var retry: (() -> Void)? = nil
```
In the `actions:` builder, after the Settings button add:
```swift
            if reason == .modelNotReady, let retry {
                Button("Retry", action: retry)
            }
```

- [ ] **Step 4: Run → PASS + build both platforms** — framework test command → `** TEST SUCCEEDED **`; macOS + iOS app builds → `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**
```bash
git add Targets/FoundationChatKit Targets/Ember
git commit -m "feat: live availability reactivity (refresh on scene active + Retry)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone K — Rename + search + titling robustness

### Task K1: `Conversation.titleIsCustom` + store `search`/`setTitle(custom:)`

**Files:**
- Modify: `Targets/FoundationChatKit/Sources/Persistence/Conversation.swift`, `Persistence/ConversationStore.swift`
- Test: `Targets/FoundationChatKit/Tests/ConversationStoreTests.swift` (extend)

- [ ] **Step 1: Write the failing tests** (append inside `ConversationStoreTests`; it already builds an in-memory store — mirror its existing setup helper):
```swift
    @Test func searchMatchesTitleAndMessageCaseInsensitive() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Conversation.self, Message.self, configurations: config)
        let store = ConversationStore(context: ModelContext(container))
        let c1 = store.createConversation(now: Date(timeIntervalSince1970: 0))
        store.setTitle("Trip Planning", for: c1)
        let c2 = store.createConversation(now: Date(timeIntervalSince1970: 0))
        store.appendMessage(role: .user, text: "Quantum physics", to: c2, now: Date(timeIntervalSince1970: 0))
        #expect(store.search("trip").map(\.id) == [c1.id])
        #expect(store.search("QUANTUM").map(\.id) == [c2.id])
        #expect(store.search("   ").count == 2)
    }
    @Test func setTitleCustomMarksFlag() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Conversation.self, Message.self, configurations: config)
        let store = ConversationStore(context: ModelContext(container))
        let convo = store.createConversation(now: Date(timeIntervalSince1970: 0))
        store.setTitle("My Title", for: convo, custom: true)
        #expect(convo.title == "My Title")
        #expect(convo.titleIsCustom == true)
    }
```

- [ ] **Step 2: Run → FAIL** (`titleIsCustom`/`search`/`custom:` not found). Run `tuist generate --no-open` then the framework test command.

- [ ] **Step 3a: Conversation** — in `Conversation.swift`, add the stored property with a default (lightweight migration) and an init parameter. Add the property after `lastTokenCount`:
```swift
    public var titleIsCustom: Bool = false
```
Add to the initializer parameter list (after `lastTokenCount: Int = 0,`):
```swift
        titleIsCustom: Bool = false,
```
and in the body (after `self.lastTokenCount = lastTokenCount`):
```swift
        self.titleIsCustom = titleIsCustom
```

- [ ] **Step 3b: ConversationStore** — replace `setTitle(_:for:)` with a `custom:` overload and add `search`:
```swift
    public func setTitle(_ title: String, for conversation: Conversation, custom: Bool = false) {
        conversation.title = title
        conversation.titleIsCustom = custom
        try? context.save()
    }

    /// Case-insensitive search over titles and message text. Empty query returns all.
    public func search(_ query: String) -> [Conversation] {
        let all = (try? allConversations()) ?? []
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { convo in
            convo.title.lowercased().contains(q) ||
            convo.messages.contains { $0.text.lowercased().contains(q) }
        }
    }
```

- [ ] **Step 4: Run → PASS** (framework test command → `** TEST SUCCEEDED **`).

- [ ] **Step 5: Commit**
```bash
git add Targets/FoundationChatKit
git commit -m "feat(kit): conversation search + custom-title flag

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task K2: Coordinator rename + search + isProcessing + no-clobber

**Files:**
- Modify: `Targets/FoundationChatKit/Sources/App/ChatCoordinator.swift`
- Test: `Targets/FoundationChatKit/Tests/ChatCoordinatorTests.swift` (extend)

- [ ] **Step 1: Write the failing tests** (append inside `ChatCoordinatorTests`):
```swift
    @Test func renameSetsCustomTitle() throws {
        let (coord, _) = try make()
        coord.newConversation()
        let id = coord.selectedID!
        coord.rename(id, to: "  My Chat  ")
        #expect(coord.conversations.first?.title == "My Chat")
    }
    @Test func autoTitleDoesNotClobberRenamed() async throws {
        let (coord, provider) = try make()
        provider.session.scriptedSnapshots = ["ok"]
        provider.titleResult = "Generated"
        coord.newConversation()
        let id = coord.selectedID!
        coord.rename(id, to: "Manual")
        await coord.send("hello there")
        #expect(coord.conversations.first?.title == "Manual")
    }
    @Test func visibleConversationsFiltersBySearch() async throws {
        let (coord, provider) = try make()
        provider.session.scriptedSnapshots = ["ok"]
        coord.newConversation(); await coord.send("apples")
        coord.newConversation(); await coord.send("oranges")
        coord.searchText = "apple"
        #expect(coord.visibleConversations.count == 1)
    }
```

- [ ] **Step 2: Run → FAIL** (`rename`/`searchText`/`visibleConversations` not found). Run the framework test command.

- [ ] **Step 3a: Add state + methods** — in `ChatCoordinator.swift`, add stored properties near `selectedID`:
```swift
    public private(set) var isProcessing = false
    public var searchText: String = ""
```
Add (after `deleteConversation`):
```swift
    public var visibleConversations: [Conversation] {
        store.search(searchText)
    }

    public func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let convo = conversations.first(where: { $0.id == id }) else { return }
        store.setTitle(trimmed, for: convo, custom: true)
        reload()
    }
```

- [ ] **Step 3b: Harden `send`** — replace the `send(_:)` method body with the `isProcessing`-guarded, no-clobber version:
```swift
    public func send(_ text: String) async {
        guard let engine,
              let id = selectedID,
              let convo = conversations.first(where: { $0.id == id }) else { return }
        isProcessing = true
        defer { isProcessing = false }
        let isFirstExchange = convo.orderedMessages.isEmpty
        await engine.send(text)
        // Title only after a genuinely completed first exchange (no error, non-empty reply),
        // never clobbering a user-renamed conversation, and only if it still exists.
        if isFirstExchange,
           engine.lastError == nil,
           let assistantText = engine.messages.last(where: { $0.role == .assistant })?.text,
           !assistantText.isEmpty {
            let seed = TitleSeed(userText: text, assistantText: assistantText)
            if let title = await provider.generateTitle(forFirstExchange: seed),
               conversations.contains(where: { $0.id == id }),
               !convo.titleIsCustom {
                store.setTitle(title, for: convo)
            }
        }
        reload()
    }
```

- [ ] **Step 4: Run → PASS** (framework test command → `** TEST SUCCEEDED **`; the Plan 3 titling tests still pass).

- [ ] **Step 5: Commit**
```bash
git add Targets/FoundationChatKit
git commit -m "feat(kit): coordinator rename, search, isProcessing + no-clobber titling

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task K3: Sidebar rename + search UI; composer guard (build)

**Files:**
- Modify: `Targets/Ember/Sources/ConversationListView.swift`, `Targets/Ember/Sources/ComposerView.swift`

- [ ] **Step 1: Replace `ConversationListView.swift`**:
```swift
import SwiftUI
import FoundationChatKit

struct ConversationListView: View {
    let coordinator: ChatCoordinator
    @State private var renamingID: UUID?
    @State private var renameDraft = ""

    var body: some View {
        List(selection: Binding(get: { coordinator.selectedID },
                                set: { coordinator.select($0) })) {
            ForEach(coordinator.visibleConversations, id: \.id) { convo in
                VStack(alignment: .leading, spacing: 2) {
                    Text(convo.title).lineLimit(1)
                    Text(convo.updatedAt, style: .relative)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(convo.id)
                .contextMenu {
                    Button { renamingID = convo.id; renameDraft = convo.title } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        coordinator.deleteConversation(convo.id)
                    } label: { Label("Delete", systemImage: "trash") }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        coordinator.deleteConversation(convo.id)
                    } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .searchable(text: Binding(get: { coordinator.searchText },
                                  set: { coordinator.searchText = $0 }),
                    prompt: "Search chats")
        .navigationTitle("Ember")
        .toolbar {
            ToolbarItem {
                Button { coordinator.newConversation() } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("New chat")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .alert("Rename Chat", isPresented: Binding(get: { renamingID != nil },
                                                   set: { if !$0 { renamingID = nil } })) {
            TextField("Title", text: $renameDraft)
            Button("Cancel", role: .cancel) { renamingID = nil }
            Button("Save") {
                if let id = renamingID { coordinator.rename(id, to: renameDraft) }
                renamingID = nil
            }
        }
        .overlay {
            if coordinator.visibleConversations.isEmpty {
                ContentUnavailableView("No Chats", systemImage: "bubble.left",
                                       description: Text("Tap compose to start."))
            }
        }
    }
}
```

- [ ] **Step 2: Guard the composer** — in `ComposerView.swift`, change the text field and send-button disabled modifiers to also respect `coordinator.isProcessing`:
  - text field: `.disabled(engine.isResponding || coordinator.isProcessing)`
  - send button (the `else` branch): `.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coordinator.isProcessing)`

- [ ] **Step 3: Build both platforms** — `tuist generate --no-open`; macOS + iOS app builds → `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**
```bash
git add Targets/Ember
git commit -m "feat(app): rename + search sidebar UI; composer guards on isProcessing

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone L — Markdown rendering

### Task L1: `MarkdownBlocks` parser (TDD)

**Files:**
- Create: `Targets/FoundationChatKit/Sources/Markdown/MarkdownBlocks.swift`
- Test: `Targets/FoundationChatKit/Tests/MarkdownBlocksTests.swift` (new)

- [ ] **Step 1: Write the failing test** — `MarkdownBlocksTests.swift`:
```swift
import Testing
@testable import FoundationChatKit

struct MarkdownBlocksTests {
    @Test func plainProse() {
        #expect(MarkdownBlocks.parse("hello world") == [.prose("hello world")])
    }
    @Test func singleCodeBlock() {
        #expect(MarkdownBlocks.parse("```swift\nlet x = 1\n```")
                == [.code(language: "swift", code: "let x = 1")])
    }
    @Test func proseCodeProse() {
        #expect(MarkdownBlocks.parse("before\n```\ncode\n```\nafter")
                == [.prose("before"), .code(language: nil, code: "code"), .prose("after")])
    }
    @Test func unterminatedFenceBecomesCode() {
        #expect(MarkdownBlocks.parse("intro\n```python\nx = 1")
                == [.prose("intro"), .code(language: "python", code: "x = 1")])
    }
}
```

- [ ] **Step 2: Run → FAIL** (`MarkdownBlocks` not found). Run `tuist generate --no-open` then the framework test command.

- [ ] **Step 3: Implement `MarkdownBlocks.swift`**:
```swift
import Foundation

/// A parsed block of assistant markdown: prose or a fenced code block.
public enum MarkdownBlock: Equatable, Sendable {
    case prose(String)
    case code(language: String?, code: String)
}

/// Splits text into prose and fenced ``` ``` ``` code blocks. An unterminated fence (as happens
/// mid-stream) is treated as a trailing code block. Pure and fully testable.
public enum MarkdownBlocks {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var prose: [String] = []
        var code: [String] = []
        var inCode = false
        var lang: String?

        func flushProse() {
            let joined = prose.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.prose(joined))
            }
            prose = []
        }
        func flushCode() {
            blocks.append(.code(language: lang, code: code.joined(separator: "\n")))
            code = []; lang = nil
        }

        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode {
                    flushCode(); inCode = false
                } else {
                    flushProse(); inCode = true
                    let tag = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    lang = tag.isEmpty ? nil : tag
                }
            } else if inCode {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if inCode { flushCode() } else { flushProse() }
        return blocks
    }
}
```

- [ ] **Step 4: Run → PASS** (framework test command → `** TEST SUCCEEDED **`).

- [ ] **Step 5: Commit**
```bash
git add Targets/FoundationChatKit
git commit -m "feat(kit): markdown block parser (prose + fenced code)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task L2: `MarkdownText` renderer + assistant bubbles (build)

**Files:**
- Create: `Targets/Ember/Sources/MarkdownText.swift`
- Modify: `Targets/Ember/Sources/MessageBubble.swift`

- [ ] **Step 1: Create `MarkdownText.swift`**:
```swift
import SwiftUI
import FoundationChatKit

/// Renders assistant text as markdown: inline styling via AttributedString, fenced code in a
/// monospaced, scrollable box. Best-effort on partial (streaming) markdown.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlocks.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let s):
                    Text(attributed(s)).textSelection(.enabled)
                case .code(_, let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func attributed(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }
}
```

- [ ] **Step 2: Replace `MessageBubble.swift`** — assistant bubbles render markdown; user/notice stay plain:
```swift
import SwiftUI
import FoundationChatKit

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .systemNotice:
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        case .user:
            row(trailing: true, background: Color.accentColor.opacity(0.18)) {
                Text(message.text.isEmpty ? "…" : message.text).textSelection(.enabled)
            }
        case .assistant:
            row(trailing: false, background: Color.secondary.opacity(0.12)) {
                if message.text.isEmpty { Text("…") } else { MarkdownText(text: message.text) }
            }
        }
    }

    private func row<Content: View>(trailing: Bool, background: Color,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack {
            if trailing { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 6) {
                content()
                if message.isStreaming { ProgressView().controlSize(.small) }
            }
            .padding(10)
            .background(background, in: RoundedRectangle(cornerRadius: 14))
            if !trailing { Spacer(minLength: 48) }
        }
    }
}
```

- [ ] **Step 3: Build both platforms** — `tuist generate --no-open`; macOS + iOS app builds → `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**
```bash
git add Targets/Ember
git commit -m "feat(app): markdown rendering in assistant bubbles

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone M — Calculator polish + run/verify/finalize

### Task M1: Calculator float-format polish (TDD)

**Files:**
- Modify: `Targets/FoundationChatKit/Sources/Tools/CalculatorTool.swift`
- Test: `Targets/FoundationChatKit/Tests/CalculatorToolTests.swift` (extend)

- [ ] **Step 1: Add failing test** (append inside `CalculatorToolTests`):
```swift
    @Test func trimsFloatingPointNoise() {
        #expect(CalculatorTool.format(0.1 + 0.2) == "0.3")
        #expect(CalculatorTool.format(14.0) == "14")
    }
```

- [ ] **Step 2: Run → FAIL** (`0.1+0.2` formats as `0.30000000000000004`). Run the framework test command.

- [ ] **Step 3: Implement** — replace `CalculatorTool.format`:
```swift
    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        // Trim floating-point noise (e.g. 0.1 + 0.2) to a sensible precision.
        let trimmed = (value * 1e10).rounded() / 1e10
        if trimmed == trimmed.rounded(), abs(trimmed) < 1e15 { return String(Int(trimmed)) }
        return String(trimmed)
    }
```

- [ ] **Step 4: Run → PASS** (framework test command → `** TEST SUCCEEDED **`; prior calculator tests still pass: `(12.5/100)*80` → `10`, `2+2` → `4`).

- [ ] **Step 5: Commit**
```bash
git add Targets/FoundationChatKit
git commit -m "fix(kit): trim floating-point noise in calculator output

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task M2: Run, verify, finalize

- [ ] **Step 1: Full test + both builds**
```bash
xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -5
xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=macOS' build 2>&1 | tail -3
xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -3
```
All three must succeed.

- [ ] **Step 2: Run on the iOS simulator + verify the polish**
```bash
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null || true
xcodebuild -workspace Ember.xcworkspace -scheme Ember -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/ember-ios-p4 build 2>&1 | tail -3
APP=$(find /tmp/ember-ios-p4/Build/Products -name "Ember.app" -maxdepth 3 | head -1)
xcrun simctl install booted "$APP"; xcrun simctl launch booted dev.iosunpi.ember; sleep 6
xcrun simctl io booted screenshot /tmp/ember-p4-ios.png
```
Drive the UI (xcodebuildmcp `describe_ui`/`tap`/`type_text`/`screenshot`) to confirm, best-effort: a turn renders **markdown** (ask for a fenced code example), the **Tokens** tab shows **no duplicate Instructions line** and reads **exact** (not "estimated") on 26.4+, **Stop** interrupts a long generation, **rename** via the sidebar context menu sticks, and **search** filters the list. Record observed behavior + screenshot.

- [ ] **Step 3: Final commit + tag**
```bash
git commit --allow-empty -m "chore: Plan 4 complete — hardening & polish

Exact async token counts (+ instructions de-dupe), deep producer cancellation,
live availability reactivity, markdown rendering, conversation rename, search,
and the Plan 3 titling-robustness follow-ups.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git tag plan-4-hardening-complete
```

- [ ] **Step 4: PR** — push and open the PR (base `main` if Plan 3 has merged, else base `plan-3-tools`):
```bash
git push -u origin plan-4-hardening
gh pr create --base main --head plan-4-hardening --title "Plan 4 — Hardening & polish" --body "Exact async token counts + instructions de-dupe, deep producer cancellation, live availability reactivity, markdown rendering, conversation rename, search, and Plan 3 titling-robustness follow-ups. All FoundationChatKit logic TDD; app views build-verified; verified on the iOS 26 simulator."
```

---

## Self-review (author check against spec)

**Spec coverage (spec §):**
- §3.A exact tokens + instructions de-dupe → H2 + H1. ✓
- §3.B deep cancellation → I1 (producer cancel + engine mid-stream test). ✓
- §3.C availability reactivity → J1 (stored availability, refresh on scene active, Retry). ✓
- §3.D markdown → L1 (parser, TDD) + L2 (renderer). ✓
- §3.E rename → K1 (`setTitle(custom:)`) + K2 (`rename`) + K3 (sidebar). ✓
- §3.F search → K1 (`search`) + K2 (`visibleConversations`) + K3 (`.searchable`). ✓
- §3.G #2 re-entrancy → K2 (`isProcessing`) + K3 (composer guard); #3 availability pre-check → J1 (`generateTitle` guard); #5 no-clobber → K1 (`titleIsCustom`) + K2 (send guard). ✓
- Calculator float polish → M1. ✓
- §5 one additive schema field (`titleIsCustom`) → K1. ✓

**Placeholder scan:** none. Every code step shows full code.

**Type consistency:** `exactTokenCount(for:) async -> Int?` identical across protocol (H2-3a), real (H2-3b), mock (H2-3c), engine (H2-3d). `refreshExactBudget()` defined H2 and called in `performTurn`. `availability` becomes stored in J1 and read by `RootView`/tests. `setTitle(_:for:custom:)` (K1) consumed by `rename` (K2) and send no-clobber (K2). `MarkdownBlock`/`MarkdownBlocks.parse` defined L1, consumed by `MarkdownText` (L2). `isProcessing`/`searchText`/`visibleConversations` defined K2, consumed by K3 UI. `CalculatorTool.format` (M1) keeps its signature (reused by `UnitConverterTool`).

**Ordering:** H (calc/budget — no call-site breaks) → I (real-provider stream) → J (availability, both builds) → K (store→coordinator→UI) → L (parser→renderer) → M (polish + run). Each task ends green/committed; the app builds from J onward (UI changes are self-contained).
