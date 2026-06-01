# Ember — Plan 2 of 2: SwiftUI App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the multiplatform SwiftUI app on top of the Plan 1 `FoundationChatKit` engine — availability gating, a conversation sidebar, streaming chat, the Context/Tokens inspector, a token gauge — and wire the engine to SwiftData so chats persist and resume.

**Architecture:** MVVM. A framework-located `ChatCoordinator` (`@Observable @MainActor`) owns the provider, the `ConversationStore`, the conversation list, and the current `ConversationEngine`; persistence is injected into the engine as closures so each completed turn is durably saved. SwiftUI views bind to the coordinator and the engine. The app deliberately avoids SwiftUI's `@Query`/`.modelContainer` (which uses the crashing `mainContext` on 26.5) and instead uses an explicit `ConversationStore(context: ModelContext(container))`.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, FoundationModels, Tuist, Swift Testing.

---

## Conventions for the executing engineer
- **Branch:** `plan-2-ui` (already created off `plan-1-foundation`).
- **TDD** for Milestones A–B (logic in `FoundationChatKit`). SwiftUI views (C–F) are verified by **build**; Milestone G verifies by **running**.
- **Tuist:** after creating/deleting any file run `tuist generate --no-open` before building/testing.
- **Test (framework):** `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`.
- **Build app (macOS):** `xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=macOS' build 2>&1 | tail -15`.
- **Build app (iOS):** `xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -15`.
- Swift Testing (`import Testing`). Sandbox failures → retry with Bash `dangerouslyDisableSandbox: true`; real failure → BLOCKED with output.
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **Existing public API (Plan 1, do not break):** `ConversationEngine` (`messages`, `isResponding`, `budget`, `lastError`, `send`, `cancel`), `ChatModelProvider`/`ChatSessionHandle`, `FoundationModelProvider`, `ConversationStore` (`allConversations`, `createConversation(now:)`, `appendMessage(role:text:to:now:)`, `updateResumeState(_:transcriptData:modelVersionTag:tokenCount:)`, `delete`, `contextEntries(for:)`), `Conversation`/`Message`, value types (`ChatMessage`, `ContextEntry`, `TokenBudgetSnapshot`/`BudgetLine`/`BudgetZone`, `ModelAvailability`/`ModelUnavailableReason`, `GenerationSettings`, `ChatError`).

---

## File structure
```
Targets/FoundationChatKit/Sources/
  Engine/ConversationEngine.swift        # MODIFY: persistence seam + accessors + entries-resume
  App/ChatCoordinator.swift              # NEW: app brain (list + selection + engine + persistence wiring)
Targets/FoundationChatKit/Tests/
  ConversationEnginePersistenceTests.swift  # NEW
  ChatCoordinatorTests.swift                # NEW
Targets/Ember/Sources/
  EmberApp.swift                         # MODIFY: real ModelContainer + ChatCoordinator + RootView
  RootView.swift                         # NEW: availability gate
  UnavailableView.swift                  # NEW: 4 reasons + Settings link
  ChatScene.swift                        # NEW: NavigationSplitView + toolbar + inspector
  ConversationListView.swift             # NEW: sidebar
  ChatView.swift                         # NEW: messages + composer
  MessageBubble.swift                    # NEW
  ComposerView.swift                     # NEW
  ErrorBanner.swift                      # NEW
  TokenGaugeView.swift                   # NEW: compact toolbar gauge
  InspectorPanel.swift                   # NEW: [Context | Tokens] picker
  ContextInspectorView.swift             # NEW
  TokenMeterView.swift                   # NEW
```

---

## Milestone A — Engine ⇄ persistence seam + resume (TDD)

### Task A1: Extend `ConversationEngine`

**Files:**
- Modify (full replace): `Targets/FoundationChatKit/Sources/Engine/ConversationEngine.swift`
- Test: `Targets/FoundationChatKit/Tests/ConversationEnginePersistenceTests.swift`

- [ ] **Step 1: Write the failing tests**

`ConversationEnginePersistenceTests.swift`:
```swift
import Testing
import Foundation
@testable import FoundationChatKit

@MainActor
final class PersistenceSpy {
    var recordedMessages: [ChatMessage] = []
    var resumeStateCount = 0
    var lastTokenCount = 0
    var persistence: ConversationEngine.ConversationPersistence {
        ConversationEngine.ConversationPersistence(
            recordMessage: { [weak self] in self?.recordedMessages.append($0) },
            recordResumeState: { [weak self] _, tokens in
                self?.resumeStateCount += 1
                self?.lastTokenCount = tokens
            }
        )
    }
}

@MainActor
struct ConversationEnginePersistenceTests {
    @Test func persistsUserThenAssistantThenResumeState() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["Hello!"]
        let spy = PersistenceSpy()
        let engine = ConversationEngine(provider: provider, settings: GenerationSettings(instructions: "sys"),
                                        persistence: spy.persistence, now: { Date(timeIntervalSince1970: 0) })
        await engine.send("hi")
        #expect(spy.recordedMessages.map(\.role) == [.user, .assistant])
        #expect(spy.recordedMessages.map(\.text) == ["hi", "Hello!"])
        #expect(spy.resumeStateCount == 1)
    }

    @Test func restoresFromContextEntries() {
        let provider = MockModelProvider()
        let engine = ConversationEngine(
            provider: provider,
            settings: GenerationSettings(),
            restoringEntries: [ContextEntry(kind: .userPrompt, text: "hi"),
                               ContextEntry(kind: .modelResponse, text: "hello")],
            now: { Date(timeIntervalSince1970: 0) })
        #expect(engine.messages.map(\.role) == [.user, .assistant])
        #expect(engine.messages.map(\.text) == ["hi", "hello"])
    }

    @Test func exposesContextEntriesAndTranscript() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["ok"]
        let engine = ConversationEngine(provider: provider, now: { Date(timeIntervalSince1970: 0) })
        await engine.send("hi")
        #expect(engine.contextEntries.map(\.text) == ["hi", "ok"])
        #expect(engine.encodedTranscript == nil) // mock returns nil
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run `tuist generate --no-open` then the framework test command. Expected: FAIL — `ConversationPersistence`/`restoringEntries`/`contextEntries` not found.

- [ ] **Step 3: Replace `ConversationEngine.swift` with this full content**

```swift
import Foundation
import Observation

/// Owns one conversation's live session and drives the turn lifecycle. MVVM view model:
/// the SwiftUI layer binds to `messages`, `isResponding`, `budget`, `lastError`.
@MainActor
@Observable
public final class ConversationEngine {
    /// Closures the app injects to durably persist a turn as it happens.
    public struct ConversationPersistence {
        public var recordMessage: @MainActor (ChatMessage) -> Void
        public var recordResumeState: @MainActor (_ encodedTranscript: Data?, _ usedTokens: Int) -> Void
        public init(
            recordMessage: @escaping @MainActor (ChatMessage) -> Void,
            recordResumeState: @escaping @MainActor (_ encodedTranscript: Data?, _ usedTokens: Int) -> Void
        ) {
            self.recordMessage = recordMessage
            self.recordResumeState = recordResumeState
        }
    }

    public private(set) var messages: [ChatMessage] = []
    public internal(set) var isResponding: Bool = false
    public private(set) var budget: TokenBudgetSnapshot
    public private(set) var lastError: ChatError?

    /// The exact context window currently held by the model session (drives the inspector).
    public var contextEntries: [ContextEntry] { session.contextEntries }
    /// Encoded transcript for fast/faithful resume (nil if the provider doesn't support it).
    public var encodedTranscript: Data? { session.encodedTranscript() }

    private let provider: any ChatModelProvider
    private var session: any ChatSessionHandle
    private var settings: GenerationSettings
    private let calculator: TokenBudgetCalculator
    private let persistence: ConversationPersistence?
    private let now: () -> Date
    private var turnTask: Task<Void, Never>?

    public init(
        provider: any ChatModelProvider,
        settings: GenerationSettings = GenerationSettings(),
        restoring encodedTranscript: Data? = nil,
        restoringEntries: [ContextEntry]? = nil,
        persistence: ConversationPersistence? = nil,
        calculator: TokenBudgetCalculator = TokenBudgetCalculator(),
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.settings = settings
        self.calculator = calculator
        self.persistence = persistence
        self.now = now
        if let encodedTranscript {
            self.session = provider.makeSession(settings: settings, restoring: encodedTranscript)
        } else if let restoringEntries, !restoringEntries.isEmpty {
            self.session = provider.makeSession(settings: settings, seeding: restoringEntries)
        } else {
            self.session = provider.makeSession(settings: settings, restoring: nil)
        }
        self.budget = TokenBudgetSnapshot(maxTokens: provider.maxContextTokens, usedTokens: 0, isExact: false, lines: [])
        self.messages = ContextProjection.bubbles(from: session.contextEntries, now: now)
        recomputeBudget(inFlight: nil)
    }

    public func send(_ text: String) async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isResponding else { return }
        let task = Task { await self.performTurn(prompt) }
        turnTask = task
        await task.value
    }

    public func cancel() { turnTask?.cancel() }

    private func performTurn(_ prompt: String) async {
        lastError = nil
        isResponding = true
        defer { isResponding = false }

        let userMessage = ChatMessage(role: .user, text: prompt, createdAt: now())
        messages.append(userMessage)
        persistence?.recordMessage(userMessage)

        let assistant = ChatMessage(role: .assistant, text: "", createdAt: now(), isStreaming: true)
        messages.append(assistant)
        let assistantIndex = messages.count - 1

        do {
            for try await snapshot in session.stream(prompt: prompt) {
                if Task.isCancelled { break }
                messages[assistantIndex].text = snapshot
                recomputeBudget(inFlight: snapshot)
            }
            if assistantIndex < messages.count { messages[assistantIndex].isStreaming = false }
            recomputeBudget(inFlight: nil)
            finalizeAssistant(at: assistantIndex)
        } catch is CancellationError {
            if assistantIndex < messages.count { messages[assistantIndex].isStreaming = false }
            finalizeAssistant(at: assistantIndex)
        } catch {
            handle(error, assistantIndex: assistantIndex)
        }
    }

    private func finalizeAssistant(at index: Int) {
        guard index < messages.count, messages[index].role == .assistant else { return }
        let final = messages[index]
        if !final.text.isEmpty { persistence?.recordMessage(final) }
        persistence?.recordResumeState(session.encodedTranscript(), budget.usedTokens)
    }

    private func handle(_ error: Error, assistantIndex: Int) {
        if assistantIndex < messages.count, messages[assistantIndex].role == .assistant,
           messages[assistantIndex].text.isEmpty {
            messages.remove(at: assistantIndex)
        } else if assistantIndex < messages.count {
            messages[assistantIndex].isStreaming = false
        }
        let chatError = (error as? ChatError) ?? .unknown(String(describing: error))
        switch chatError {
        case .contextOverflow:
            recoverFromOverflow()
        default:
            lastError = chatError
        }
    }

    private func recoverFromOverflow() {
        let condensed = OverflowRecovery.condense(session.contextEntries)
        session = provider.makeSession(settings: settings, seeding: condensed)
        let notice = ChatMessage(role: .systemNotice,
                                 text: "Context window was full — older turns were compacted to keep the chat going.",
                                 createdAt: now())
        messages.append(notice)
        persistence?.recordMessage(notice)
        recomputeBudget(inFlight: nil)
        persistence?.recordResumeState(session.encodedTranscript(), budget.usedTokens)
    }

    private func recomputeBudget(inFlight: String?) {
        let providerRef = provider
        budget = calculator.snapshot(
            maxTokens: providerRef.maxContextTokens,
            instructions: settings.instructions,
            entries: session.contextEntries,
            inFlight: inFlight,
            exactCount: { text in providerRef.tokenCount(for: text) }
        )
    }
}
```

- [ ] **Step 4: Run to verify all pass**

Run the framework test command. Expected: `** TEST SUCCEEDED **`. The new tests pass AND all prior engine tests still pass (the new params are defaulted; existing tests pass `persistence: nil`). Total ≈ 38 tests.

- [ ] **Step 5: Commit**

```bash
git add Targets/FoundationChatKit
git commit -m "feat(kit): engine persistence seam, transcript/contextEntries accessors, entries-resume

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone B — `ChatCoordinator` (TDD)

### Task B1: The app brain

**Files:**
- Create: `Targets/FoundationChatKit/Sources/App/ChatCoordinator.swift`
- Test: `Targets/FoundationChatKit/Tests/ChatCoordinatorTests.swift`

- [ ] **Step 1: Write the failing tests**

`ChatCoordinatorTests.swift`:
```swift
import Testing
import Foundation
import SwiftData
@testable import FoundationChatKit

@MainActor
struct ChatCoordinatorTests {
    func make() throws -> (ChatCoordinator, MockModelProvider) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Conversation.self, Message.self, configurations: config)
        let store = ConversationStore(context: ModelContext(container))
        let provider = MockModelProvider()
        let coord = ChatCoordinator(provider: provider, store: store,
                                    settings: GenerationSettings(instructions: "sys"),
                                    modelVersionTag: "v1", now: { Date(timeIntervalSince1970: 0) })
        return (coord, provider)
    }

    @Test func newConversationCreatesSelectsAndBuildsEngine() throws {
        let (coord, _) = try make()
        coord.newConversation()
        #expect(coord.conversations.count == 1)
        #expect(coord.selectedID != nil)
        #expect(coord.engine != nil)
    }

    @Test func sendPersistsMessagesAndTitle() async throws {
        let (coord, provider) = try make()
        provider.session.scriptedSnapshots = ["Hello there friend"]
        coord.newConversation()
        await coord.send("How are you")
        let convo = coord.conversations.first!
        #expect(convo.orderedMessages.map(\.role) == [.user, .assistant])
        #expect(convo.orderedMessages.map(\.text) == ["How are you", "Hello there friend"])
        #expect(convo.title == "How are you")
    }

    @Test func reopeningRestoresPriorMessagesFromStore() async throws {
        let (coord, provider) = try make()
        provider.session.scriptedSnapshots = ["hello"]
        coord.newConversation()
        await coord.send("hi")
        let id = coord.selectedID!
        coord.select(nil)
        #expect(coord.engine == nil)
        provider.session.contextEntries = []   // prove restore comes from the store, not leftover mock state
        coord.select(id)
        #expect(coord.engine?.messages.map(\.text) == ["hi", "hello"])
    }

    @Test func deleteRemovesAndDeselects() throws {
        let (coord, _) = try make()
        coord.newConversation()
        let id = coord.selectedID!
        coord.deleteConversation(id)
        #expect(coord.conversations.isEmpty)
        #expect(coord.engine == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

`tuist generate --no-open`, then the framework test command. Expected: FAIL — `ChatCoordinator` not found.

- [ ] **Step 3: Implement**

`ChatCoordinator.swift`:
```swift
import Foundation
import Observation

/// The app's brain: owns the model provider, the SwiftData store, the conversation list,
/// the current selection, and the live `ConversationEngine`. Persistence is injected into
/// each engine so completed turns are saved durably as they happen.
@MainActor
@Observable
public final class ChatCoordinator {
    public private(set) var conversations: [Conversation] = []
    public private(set) var engine: ConversationEngine?
    public private(set) var selectedID: UUID?

    private let provider: any ChatModelProvider
    private let store: ConversationStore
    private let settings: GenerationSettings
    private let modelVersionTag: String
    private let now: () -> Date

    public init(
        provider: any ChatModelProvider,
        store: ConversationStore,
        settings: GenerationSettings = GenerationSettings(
            instructions: "You are Ember, a helpful, concise on-device assistant. Keep answers short."),
        modelVersionTag: String = ProcessInfo.processInfo.operatingSystemVersionString,
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.store = store
        self.settings = settings
        self.modelVersionTag = modelVersionTag
        self.now = now
        reload()
    }

    public var availability: ModelAvailability { provider.availability }

    public func reload() {
        conversations = (try? store.allConversations()) ?? []
    }

    @discardableResult
    public func newConversation() -> Conversation {
        let convo = store.createConversation(now: now())
        reload()
        select(convo.id)
        return convo
    }

    public func select(_ id: UUID?) {
        selectedID = id
        guard let id, let convo = conversations.first(where: { $0.id == id }) else {
            engine = nil
            return
        }
        engine = makeEngine(for: convo)
    }

    public func deleteConversation(_ id: UUID) {
        guard let convo = conversations.first(where: { $0.id == id }) else { return }
        store.delete(convo)
        if selectedID == id { selectedID = nil; engine = nil }
        reload()
    }

    public func send(_ text: String) async {
        guard let engine else { return }
        await engine.send(text)
        reload()   // title/updatedAt may have changed
    }

    private func makeEngine(for convo: Conversation) -> ConversationEngine {
        let store = self.store
        let tag = self.modelVersionTag
        let persistence = ConversationEngine.ConversationPersistence(
            recordMessage: { message in
                store.appendMessage(role: message.role, text: message.text, to: convo, now: message.createdAt)
            },
            recordResumeState: { data, tokens in
                store.updateResumeState(convo, transcriptData: data, modelVersionTag: tag, tokenCount: tokens)
            }
        )
        let canUseTranscript = convo.transcriptData != nil && convo.modelVersionTag == tag
        return ConversationEngine(
            provider: provider,
            settings: settings,
            restoring: canUseTranscript ? convo.transcriptData : nil,
            restoringEntries: canUseTranscript ? nil : store.contextEntries(for: convo),
            persistence: persistence,
            now: now
        )
    }
}
```

- [ ] **Step 4: Run to verify all pass**

Run the framework test command. Expected: `** TEST SUCCEEDED **` (≈ 42 tests). If SwiftData traps on `mainContext`, the tests already use `ModelContext(container)` — keep it.

- [ ] **Step 5: Commit**

```bash
git add Targets/FoundationChatKit
git commit -m "feat(kit): add ChatCoordinator (list, selection, engine, persistence wiring)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone C — App shell + availability gate (build-verified)

### Task C1: EmberApp + RootView + UnavailableView

**Files:**
- Modify (full replace): `Targets/Ember/Sources/EmberApp.swift`
- Create: `Targets/Ember/Sources/RootView.swift`, `Targets/Ember/Sources/UnavailableView.swift`

> SwiftUI views aren't unit-tested here; the verification is a clean **build**. The app uses an explicit `ModelContext(container)` (NOT `@Query`/`.modelContainer`) to avoid the macOS 26.5 cross-module `mainContext` trap.

- [ ] **Step 1: Replace `EmberApp.swift`**

```swift
import SwiftUI
import SwiftData
import FoundationChatKit

@main
struct EmberApp: App {
    @State private var coordinator: ChatCoordinator

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: Conversation.self, Message.self)
        } catch {
            fatalError("Could not create the Ember data store: \(error)")
        }
        let store = ConversationStore(context: ModelContext(container))
        _coordinator = State(initialValue: ChatCoordinator(provider: FoundationModelProvider(), store: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView(coordinator: coordinator)
        }
    }
}
```

- [ ] **Step 2: Create `RootView.swift`**

```swift
import SwiftUI
import FoundationChatKit

struct RootView: View {
    let coordinator: ChatCoordinator

    var body: some View {
        switch coordinator.availability {
        case .available:
            ChatScene(coordinator: coordinator)
        case .unavailable(let reason):
            UnavailableView(reason: reason)
        }
    }
}
```

- [ ] **Step 3: Create `UnavailableView.swift`**

```swift
import SwiftUI
import FoundationChatKit
#if canImport(UIKit)
import UIKit
#endif

struct UnavailableView: View {
    let reason: ModelUnavailableReason

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(message)
        } actions: {
            if reason == .appleIntelligenceNotEnabled {
                Button("Open Settings", action: openSettings)
            }
        }
        .padding()
    }

    private var title: String {
        switch reason {
        case .deviceNotEligible: "Apple Intelligence Not Supported"
        case .appleIntelligenceNotEnabled: "Turn On Apple Intelligence"
        case .modelNotReady: "Preparing the Model"
        case .unknown: "Model Unavailable"
        }
    }
    private var message: String {
        switch reason {
        case .deviceNotEligible: "Ember needs an Apple-Intelligence-capable device to run the on-device model."
        case .appleIntelligenceNotEnabled: "Enable Apple Intelligence in Settings to start chatting on-device."
        case .modelNotReady: "The on-device model is downloading or not ready yet. Try again shortly."
        case .unknown: "The on-device model is unavailable right now."
        }
    }
    private var icon: String {
        switch reason {
        case .deviceNotEligible: "exclamationmark.triangle"
        case .appleIntelligenceNotEnabled: "sparkles"
        case .modelNotReady: "arrow.down.circle"
        case .unknown: "questionmark.circle"
        }
    }
    private func openSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #elseif canImport(AppKit)
        if let url = URL(string: "x-apple.systempreferences:") { NSWorkspace.shared.open(url) }
        #endif
    }
}
```

- [ ] **Step 4: Build both platforms**

`tuist generate --no-open`. Then build the app for macOS and iOS (commands in Conventions). Expected: `** BUILD SUCCEEDED **` on both. (`ChatScene` doesn't exist yet — add a temporary stub so it compiles: create `Targets/Ember/Sources/ChatScene.swift` with `import SwiftUI; import FoundationChatKit; struct ChatScene: View { let coordinator: ChatCoordinator; var body: some View { Text("chat") } }` — it will be replaced in Milestone D. Regenerate and build.)

- [ ] **Step 5: Commit**

```bash
git add Targets/Ember
git commit -m "feat(app): app shell, availability gate, unavailable screens

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone D — Navigation + sidebar (build-verified)

### Task D1: ChatScene + ConversationListView

**Files:**
- Modify (full replace): `Targets/Ember/Sources/ChatScene.swift`
- Create: `Targets/Ember/Sources/ConversationListView.swift`

- [ ] **Step 1: Replace `ChatScene.swift`**

```swift
import SwiftUI
import FoundationChatKit

struct ChatScene: View {
    let coordinator: ChatCoordinator
    @State private var showInspector = false

    var body: some View {
        NavigationSplitView {
            ConversationListView(coordinator: coordinator)
        } detail: {
            Group {
                if let engine = coordinator.engine {
                    ChatView(engine: engine, coordinator: coordinator)
                } else {
                    ContentUnavailableView("No Conversation",
                                           systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Select a chat or start a new one."))
                }
            }
            .toolbar {
                if let engine = coordinator.engine {
                    ToolbarItem(placement: .principal) {
                        TokenGaugeView(budget: engine.budget)
                    }
                    ToolbarItem {
                        Button { showInspector.toggle() } label: {
                            Image(systemName: "sidebar.trailing")
                        }
                        .help("Show context & tokens")
                    }
                }
            }
            .inspector(isPresented: $showInspector) {
                if let engine = coordinator.engine {
                    InspectorPanel(engine: engine)
                } else {
                    Text("No conversation").foregroundStyle(.secondary)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Create `ConversationListView.swift`**

```swift
import SwiftUI
import FoundationChatKit

struct ConversationListView: View {
    let coordinator: ChatCoordinator

    var body: some View {
        List(selection: Binding(get: { coordinator.selectedID },
                                set: { coordinator.select($0) })) {
            ForEach(coordinator.conversations, id: \.id) { convo in
                VStack(alignment: .leading, spacing: 2) {
                    Text(convo.title).lineLimit(1)
                    Text(convo.updatedAt, style: .relative)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(convo.id)
                .swipeActions {
                    Button(role: .destructive) {
                        coordinator.deleteConversation(convo.id)
                    } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
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
        .overlay {
            if coordinator.conversations.isEmpty {
                ContentUnavailableView("No Chats", systemImage: "bubble.left",
                                       description: Text("Tap compose to start."))
            }
        }
    }
}
```

- [ ] **Step 3: Build both platforms**

`tuist generate --no-open`, build macOS + iOS. (`ChatView`, `TokenGaugeView`, `InspectorPanel` don't exist yet — add minimal temporary stubs so it compiles: `struct ChatView: View { let engine: ConversationEngine; let coordinator: ChatCoordinator; var body: some View { Text("chat") } }`, `struct TokenGaugeView: View { let budget: TokenBudgetSnapshot; var body: some View { Text("tok") } }`, `struct InspectorPanel: View { let engine: ConversationEngine; var body: some View { Text("inspector") } }` each in its own file. They'll be replaced in E/F.) Regenerate, build both → `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Targets/Ember
git commit -m "feat(app): navigation split view + conversation sidebar

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone E — Chat surface (build-verified)

### Task E1: ChatView + MessageBubble + ComposerView + ErrorBanner

**Files:**
- Modify (full replace): `Targets/Ember/Sources/ChatView.swift`
- Create: `Targets/Ember/Sources/MessageBubble.swift`, `ComposerView.swift`, `ErrorBanner.swift`

- [ ] **Step 1: Replace `ChatView.swift`**

```swift
import SwiftUI
import FoundationChatKit

struct ChatView: View {
    let engine: ConversationEngine
    let coordinator: ChatCoordinator

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(engine.messages) { message in
                            MessageBubble(message: message).id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: engine.messages.last?.text) {
                    if let last = engine.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            if let error = engine.lastError {
                ErrorBanner(error: error)
            }
            Divider()
            ComposerView(engine: engine, coordinator: coordinator)
        }
    }
}
```

- [ ] **Step 2: Create `MessageBubble.swift`**

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
            row(trailing: true, background: Color.accentColor.opacity(0.18))
        case .assistant:
            row(trailing: false, background: Color.secondary.opacity(0.12))
        }
    }

    private func row(trailing: Bool, background: Color) -> some View {
        HStack {
            if trailing { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 6) {
                Text(.init(message.text.isEmpty ? "…" : message.text))
                    .textSelection(.enabled)
                if message.isStreaming {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(10)
            .background(background, in: RoundedRectangle(cornerRadius: 14))
            if !trailing { Spacer(minLength: 48) }
        }
    }
}
```

- [ ] **Step 3: Create `ComposerView.swift`**

```swift
import SwiftUI
import FoundationChatKit

struct ComposerView: View {
    let engine: ConversationEngine
    let coordinator: ChatCoordinator
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Ember…", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
                .disabled(engine.isResponding)
            if engine.isResponding {
                Button(role: .destructive, action: engine.cancel) {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .help("Stop")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding()
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        Task { await coordinator.send(text) }
    }
}
```

- [ ] **Step 4: Create `ErrorBanner.swift`**

```swift
import SwiftUI
import FoundationChatKit

struct ErrorBanner: View {
    let error: ChatError

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.orange.opacity(0.12))
    }

    private var message: String {
        switch error {
        case .guardrailViolation: "That request can't be handled. Try rephrasing."
        case .rateLimited: "The model is busy. Try again in a moment."
        case .refusal(let r): r ?? "The model declined to answer that."
        case .modelUnavailable: "The on-device model is unavailable."
        case .decodingFailure: "The response couldn't be read. Try again."
        case .cancelled: "Stopped."
        case .contextOverflow: "Context was full and has been compacted."
        case .unknown(let m): "Something went wrong: \(m)"
        }
    }
}
```

- [ ] **Step 5: Build both platforms**

`tuist generate --no-open`, build macOS + iOS → `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Targets/Ember
git commit -m "feat(app): streaming chat view, message bubbles, composer, error banner

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone F — Inspector + token gauge (build-verified)

### Task F1: TokenGaugeView + InspectorPanel + ContextInspectorView + TokenMeterView

**Files:**
- Modify (full replace): `Targets/Ember/Sources/TokenGaugeView.swift`, `Targets/Ember/Sources/InspectorPanel.swift`
- Create: `Targets/Ember/Sources/ContextInspectorView.swift`, `Targets/Ember/Sources/TokenMeterView.swift`

- [ ] **Step 1: Replace `TokenGaugeView.swift`**

```swift
import SwiftUI
import FoundationChatKit

struct TokenGaugeView: View {
    let budget: TokenBudgetSnapshot

    var body: some View {
        HStack(spacing: 6) {
            Gauge(value: budget.fraction) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(color)
                .frame(width: 90)
            Text("\(budget.usedTokens)/\(budget.maxTokens)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help("\(budget.remaining) tokens remaining" + (budget.isExact ? "" : " (estimated)"))
    }

    private var color: Color {
        switch budget.zone { case .green: .green; case .amber: .orange; case .red: .red }
    }
}
```

- [ ] **Step 2: Replace `InspectorPanel.swift`**

```swift
import SwiftUI
import FoundationChatKit

struct InspectorPanel: View {
    let engine: ConversationEngine
    @State private var tab: Tab = .context

    enum Tab: String, CaseIterable, Identifiable {
        case context = "Context", tokens = "Tokens"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()
            Divider()
            switch tab {
            case .context: ContextInspectorView(entries: engine.contextEntries)
            case .tokens: TokenMeterView(budget: engine.budget)
            }
        }
    }
}
```

- [ ] **Step 3: Create `ContextInspectorView.swift`**

```swift
import SwiftUI
import FoundationChatKit

struct ContextInspectorView: View {
    let entries: [ContextEntry]

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView("Empty Context", systemImage: "tray",
                description: Text("This shows exactly what the model sees. Send a message to populate it."))
        } else {
            List(entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(label(entry.kind))
                            .font(.caption.bold())
                            .foregroundStyle(color(entry.kind))
                        if !entry.isInWindow {
                            Text("out of window")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(entry.text)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func label(_ k: ContextEntryKind) -> String {
        switch k {
        case .instructions: "INSTRUCTIONS"
        case .userPrompt: "USER"
        case .modelResponse: "ASSISTANT"
        case .toolCall: "TOOL CALL"
        case .toolOutput: "TOOL OUTPUT"
        }
    }
    private func color(_ k: ContextEntryKind) -> Color {
        switch k {
        case .instructions: .purple
        case .userPrompt: .blue
        case .modelResponse: .green
        case .toolCall, .toolOutput: .orange
        }
    }
}
```

- [ ] **Step 4: Create `TokenMeterView.swift`**

```swift
import SwiftUI
import FoundationChatKit

struct TokenMeterView: View {
    let budget: TokenBudgetSnapshot

    var body: some View {
        List {
            Section {
                Gauge(value: budget.fraction) {
                    Text("Context window")
                } currentValueLabel: {
                    Text("\(budget.usedTokens) / \(budget.maxTokens)").monospacedDigit()
                }
                .tint(color)
                Text("\(budget.remaining) tokens remaining" + (budget.isExact ? "" : " · estimated"))
                    .font(.caption).foregroundStyle(.secondary)
                if budget.zone != .green {
                    Label(zoneMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(budget.zone == .red ? .red : .orange)
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

    private var zoneMessage: String {
        budget.zone == .red
            ? "Approaching the limit — older turns compact automatically."
            : "Context is filling up."
    }
    private var color: Color {
        switch budget.zone { case .green: .green; case .amber: .orange; case .red: .red }
    }
}
```

- [ ] **Step 5: Build both platforms**

`tuist generate --no-open`, build macOS + iOS → `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Targets/Ember
git commit -m "feat(app): token gauge + Context/Tokens inspector

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone G — Run verification + finalize

### Task G1: Launch and screenshot

- [ ] **Step 1: Build + run on macOS, take a screenshot**

```bash
xcodebuild -workspace Ember.xcworkspace -scheme Ember -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/ember-dd build 2>&1 | tail -5
APP=$(find /tmp/ember-dd/Build/Products -name "Ember.app" -maxdepth 3 | head -1)
open "$APP"
sleep 6
screencapture -x /tmp/ember-macos.png
```
Verify: the app launches showing the sidebar + "No Chats" empty state (or, if `.unavailable`, the unavailable screen — both are valid). Open `/tmp/ember-macos.png` to confirm it rendered. If it crashes on launch (e.g. the SwiftData `mainContext` trap resurfaces despite `ModelContext(container)`), capture the crash and report BLOCKED.

- [ ] **Step 2: Build + run on the iOS simulator, take a screenshot**

```bash
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null || true
xcodebuild -workspace Ember.xcworkspace -scheme Ember -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/ember-ios build 2>&1 | tail -5
APP=$(find /tmp/ember-ios/Build/Products -name "Ember.app" -maxdepth 3 | head -1)
xcrun simctl install booted "$APP"
xcrun simctl launch booted dev.iosunpi.ember
sleep 6
xcrun simctl io booted screenshot /tmp/ember-ios.png
```
Verify the screenshot shows the app UI. (On the simulator the model is typically `.unavailable` — the unavailable screen is the expected, valid result there.)

- [ ] **Step 3: Final commit + tag**

```bash
git commit --allow-empty -m "chore: Plan 2 complete — multiplatform SwiftUI app on FoundationChatKit

Availability-gated chat, conversation sidebar, streaming bubbles, Context/Tokens
inspector, token gauge; engine wired to SwiftData for persistence + resume.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git tag plan-2-ui-complete
```

---

## Deferred (not in Plan 2 — optional follow-ups)
- **Async exact token counts** (limitation from Plan 1): add `func exactTokenCount(for:) async -> Int?` to the provider + an async `refreshExactBudget()` on the engine, called after each turn so the meter is exact on 26.4+ (currently estimated, honestly labeled).
- **Deep producer cancellation** of on-device generation (today `cancel()` stops the consumer/UI).
- **Live availability reactivity** (RootView evaluates availability at launch; modelNotReady→available mid-session isn't auto-refreshed).
- **Markdown polish / streamed code blocks**, conversation rename, search.

---

## Self-review (author check against spec)
**Spec coverage (design doc §):**
- §7 adaptive sidebar + chat + `[Context|Tokens]` inspector + toolbar gauge → C/D/E/F ✓
- §7 four unavailable screens + Settings link → C1 (`UnavailableView`) ✓
- §5 SwiftData dual-truth + resume (transcript else messages) → A1 (`restoringEntries`) + B1 (`makeEngine` resume logic) ✓
- §6 token gauge + breakdown + zones + approaching-limit banner → F1 (`TokenGaugeView`, `TokenMeterView`) ✓
- §2.5 Context tab = exact `session.transcript` → A1 (`contextEntries` accessor) + F1 (`ContextInspectorView`) ✓
- §8 turn lifecycle incl. persistence on completion → A1 (`finalizeAssistant` persistence) + B1 ✓
- §9 errors (guardrail/refusal/rateLimited/overflow) surfaced → E1 (`ErrorBanner`) ✓
- Plan-1 carry-over must-dos #1 (engine⇄store) ✓ A1+B1, #2 ([ContextEntry] resume) ✓ A1+B1, #3 (verify app SwiftData path) ✓ C1 uses `ModelContext(container)` + G1 runtime check. Carry-over #4 (async exact tokens), #5 (mid-stream cancel test), #6 (ChatError.cancelled) → **Deferred** (listed above), not gaps.

**Placeholder scan:** No TBD/TODO. Temporary compile stubs in C1/D1 are explicit and replaced in the same milestone chain (D/E/F).

**Type consistency:** Views use the real public API — `engine.{messages,isResponding,budget,lastError,contextEntries,cancel}`, `coordinator.{conversations,selectedID,engine,availability,newConversation,select,deleteConversation,send}`, `budget.{fraction,usedTokens,maxTokens,remaining,isExact,zone,lines}`, `BudgetLine.{id,label,tokens}`, `ContextEntry.{id,kind,text,isInWindow}`, `Conversation.{id,title,updatedAt,orderedMessages}`. `ConversationEngine.ConversationPersistence` signature matches between A1 (definition) and B1 (use).
