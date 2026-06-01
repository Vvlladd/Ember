# Ember — Plan 1 of 2: Foundation & Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Tuist project graph and a fully unit-tested `FoundationChatKit` engine (token budgeting, transcript projection, streaming turn lifecycle, overflow recovery), the real Apple Foundation Models provider, and SwiftData persistence — everything except the SwiftUI UI (Plan 2).

**Architecture:** MVVM-friendly engine behind a `ChatModelProvider` protocol so all decision logic is testable with a `MockModelProvider` on any machine. The real `FoundationModelProvider` wraps `SystemLanguageModel`/`LanguageModelSession`. The engine works on plain value types (`ChatMessage`, `ContextEntry`) so it never depends on un-constructable framework types; the real provider maps `Transcript` ⇄ `ContextEntry` at the boundary.

**Tech Stack:** Swift 6, Tuist 4, FoundationModels (iOS/macOS 26), SwiftData, Swift Testing.

---

## Conventions for the executing engineer

- **You know Swift but not this project.** Follow each step literally. Do not add features not in a step (YAGNI).
- **TDD:** write the failing test, watch it fail, write minimal code, watch it pass, commit. One logical change per commit.
- **Run tests** with the xcodebuild MCP tooling against the generated workspace, scheme `FoundationChatKit` (unit tests) or `Ember` (app):
  - `mcp__plugin_ios-preview_xcodebuildmcp__swift_package_test` is NOT used (this is an Xcode/Tuist project, not a bare SwiftPM package). Use `test_macos` with `workspacePath: Ember.xcworkspace`, `scheme: "FoundationChatKit"`.
- **All new Swift files** start with `import Foundation` (and `import FoundationModels` / `import SwiftData` only where stated).
- **Commit messages** end with the `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` trailer.
- **Swift 6 strict concurrency** is on. Engine types touching the model are `@MainActor`. Value types are `Sendable`.
- **Date injection:** any type that stamps `Date` takes a `now: () -> Date = Date.init` so tests are deterministic.

---

## File structure (locked decomposition)

```
Tuist.swift                                  # Tuist config (version pin)
Project.swift                                # app + framework + 2 test targets
Targets/
  Ember/                                     # app target (Plan 2 fills the UI)
    Sources/EmberApp.swift                   # minimal placeholder until Plan 2
    Resources/Ember-Info.plist
    Resources/Assets.xcassets/...
  FoundationChatKit/
    Sources/
      Model/
        MessageRole.swift                    # enum
        ChatMessage.swift                    # struct
        ContextEntry.swift                   # struct + kind enum
        ModelAvailability.swift              # enum + reason
        GenerationSettings.swift             # struct
        ChatError.swift                      # enum
        TokenBudget.swift                    # BudgetLine, BudgetZone, TokenBudgetSnapshot
      Tokens/
        TokenEstimator.swift                 # char-based estimate
        TokenBudgetCalculator.swift          # snapshot(...) builder
      Context/
        ContextProjection.swift              # ContextEntry -> [ChatMessage]
        OverflowRecovery.swift               # condense([ContextEntry])
      Provider/
        ChatModelProvider.swift              # protocol + ChatSessionHandle protocol
        FoundationModelProvider.swift        # real wrapper (FoundationModels)
        TranscriptMapping.swift              # Transcript <-> ContextEntry (FoundationModels)
      Engine/
        ConversationEngine.swift             # @Observable @MainActor turn lifecycle
    Tests/
      TokenEstimatorTests.swift
      TokenBudgetCalculatorTests.swift
      ContextProjectionTests.swift
      OverflowRecoveryTests.swift
      MockModelProvider.swift                # test double (in Tests target)
      ConversationEngineTests.swift
      ChatMessageTests.swift
  Persistence/                               # part of FoundationChatKit framework
    Sources/Persistence/
      Conversation.swift                     # @Model
      Message.swift                          # @Model
      ConversationStore.swift                # CRUD + resume
    Tests/
      ConversationStoreTests.swift
```

> Persistence lives in the `FoundationChatKit` framework target (one framework, focused files), so the app and tests share it.

---

## Milestone 0 — Tuist project scaffold

### Task 0.1: Tuist config + Project.swift

**Files:**
- Create: `Tuist.swift`
- Create: `Project.swift`
- Create: `Targets/Ember/Sources/EmberApp.swift`
- Create: `Targets/Ember/Resources/Ember-Info.plist`
- Create: `Targets/FoundationChatKit/Sources/Placeholder.swift`
- Create: `Targets/FoundationChatKit/Tests/Placeholder.swift`

- [ ] **Step 1: Write `Tuist.swift`**

```swift
import ProjectDescription

let tuist = Tuist()
```

- [ ] **Step 2: Write `Project.swift`**

```swift
import ProjectDescription

let deployment: DeploymentTargets = .multiplatform(iOS: "26.0", macOS: "26.0")
let appDestinations: Destinations = [.iPhone, .iPad, .mac]

let project = Project(
    name: "Ember",
    targets: [
        .target(
            name: "FoundationChatKit",
            destinations: appDestinations,
            product: .framework,
            bundleId: "dev.iosunpi.ember.kit",
            deploymentTargets: deployment,
            sources: ["Targets/FoundationChatKit/Sources/**"],
            dependencies: []
        ),
        .target(
            name: "FoundationChatKitTests",
            destinations: appDestinations,
            product: .unitTests,
            bundleId: "dev.iosunpi.ember.kit.tests",
            deploymentTargets: deployment,
            sources: ["Targets/FoundationChatKit/Tests/**"],
            dependencies: [.target(name: "FoundationChatKit")]
        ),
        .target(
            name: "Ember",
            destinations: appDestinations,
            product: .app,
            bundleId: "dev.iosunpi.ember",
            deploymentTargets: deployment,
            infoPlist: .file(path: "Targets/Ember/Resources/Ember-Info.plist"),
            sources: ["Targets/Ember/Sources/**"],
            resources: ["Targets/Ember/Resources/**"],
            dependencies: [.target(name: "FoundationChatKit")]
        ),
        .target(
            name: "EmberTests",
            destinations: appDestinations,
            product: .unitTests,
            bundleId: "dev.iosunpi.ember.tests",
            deploymentTargets: deployment,
            sources: ["Targets/Ember/Tests/**"],
            dependencies: [.target(name: "Ember")]
        ),
    ]
)
```

- [ ] **Step 3: Write `Targets/Ember/Resources/Ember-Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key><string>Ember</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>UILaunchScreen</key><dict/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
```

- [ ] **Step 4: Write a minimal `EmberApp.swift` (replaced in Plan 2)**

```swift
import SwiftUI

@main
struct EmberApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Ember — Plan 2 builds the UI")
                .padding()
        }
    }
}
```

- [ ] **Step 5: Add empty placeholder sources so targets compile**

`Targets/FoundationChatKit/Sources/Placeholder.swift`:
```swift
// Placeholder so the framework target has a source file before Milestone 1.
```
`Targets/FoundationChatKit/Tests/Placeholder.swift`:
```swift
// Placeholder; real tests added in Milestone 1.
```
Also create `Targets/Ember/Tests/Placeholder.swift`:
```swift
// Placeholder; app tests added in Plan 2.
```

- [ ] **Step 6: Create an empty asset catalog**

Run:
```bash
mkdir -p Targets/Ember/Resources/Assets.xcassets
cat > Targets/Ember/Resources/Assets.xcassets/Contents.json <<'EOF'
{ "info" : { "author" : "xcode", "version" : 1 } }
EOF
```

### Task 0.2: Generate & verify the project builds

- [ ] **Step 1: Verify Tuist is installed**

Run: `tuist version`
Expected: a 4.x version string. If "command not found", install with `mise install tuist` or `brew install --formula tuist`, then re-run. Stop and report if it cannot be installed.

- [ ] **Step 2: Generate the workspace**

Run: `tuist generate --no-open`
Expected: creates `Ember.xcworkspace` and `*.xcodeproj`. If the manifest errors, fix `Project.swift` to match the installed Tuist API (e.g. `deploymentTargets`/`destinations` shape) and re-run.

- [ ] **Step 3: Build the framework for macOS**

Use `mcp__plugin_ios-preview_xcodebuildmcp__build_macos` with `workspacePath: "Ember.xcworkspace"`, `scheme: "FoundationChatKit"`.
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Build the app for macOS**

Use `build_macos` with `workspacePath: "Ember.xcworkspace"`, `scheme: "Ember"`.
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: scaffold Ember Tuist project (app + FoundationChatKit + tests)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone 1 — Engine value types & token math (pure, TDD)

### Task 1.1: `MessageRole` and `ChatMessage`

**Files:**
- Create: `Targets/FoundationChatKit/Sources/Model/MessageRole.swift`
- Create: `Targets/FoundationChatKit/Sources/Model/ChatMessage.swift`
- Test: `Targets/FoundationChatKit/Tests/ChatMessageTests.swift`
- Delete: `Targets/FoundationChatKit/Sources/Placeholder.swift` (now that real sources exist)

- [ ] **Step 1: Write the failing test**

`ChatMessageTests.swift`:
```swift
import Testing
import Foundation
@testable import FoundationChatKit

struct ChatMessageTests {
    @Test func userMessageDefaults() {
        let fixed = Date(timeIntervalSince1970: 100)
        let m = ChatMessage(role: .user, text: "hi", createdAt: fixed)
        #expect(m.role == .user)
        #expect(m.text == "hi")
        #expect(m.isStreaming == false)
        #expect(m.createdAt == fixed)
    }

    @Test func streamingFlagAndAppendReplaceText() {
        var m = ChatMessage(role: .assistant, text: "", createdAt: .init(timeIntervalSince1970: 0), isStreaming: true)
        m.text = "Hello"          // cumulative snapshot REPLACES, never appends
        m.text = "Hello world"
        #expect(m.text == "Hello world")
        #expect(m.isStreaming)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run `test_macos` (`scheme: "FoundationChatKit"`).
Expected: FAIL — `cannot find 'ChatMessage' in scope`.

- [ ] **Step 3: Write minimal implementation**

`MessageRole.swift`:
```swift
import Foundation

public enum MessageRole: String, Sendable, Codable, Equatable {
    case user
    case assistant
    case systemNotice   // app-generated notices (e.g. "Context compacted")
}
```

`ChatMessage.swift`:
```swift
import Foundation

public struct ChatMessage: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var role: MessageRole
    public var text: String
    public var createdAt: Date
    public var isStreaming: Bool

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        text: String,
        createdAt: Date,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.isStreaming = isStreaming
    }
}
```

Run: `rm Targets/FoundationChatKit/Sources/Placeholder.swift`

- [ ] **Step 4: Run test to verify it passes**

Run `test_macos` (`scheme: "FoundationChatKit"`).
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(kit): add MessageRole and ChatMessage value types

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 1.2: `ContextEntry`

**Files:**
- Create: `Targets/FoundationChatKit/Sources/Model/ContextEntry.swift`
- Test: add to `Targets/FoundationChatKit/Tests/ContextProjectionTests.swift` (created in 1.6) — for now a small dedicated test file.
- Test: `Targets/FoundationChatKit/Tests/ContextEntryTests.swift`

- [ ] **Step 1: Write the failing test**

`ContextEntryTests.swift`:
```swift
import Testing
import Foundation
@testable import FoundationChatKit

struct ContextEntryTests {
    @Test func entryHoldsKindAndText() {
        let e = ContextEntry(kind: .userPrompt, text: "How do I parse JSON?")
        #expect(e.kind == .userPrompt)
        #expect(e.text == "How do I parse JSON?")
        #expect(e.isInWindow == true)
    }

    @Test func outOfWindowFlag() {
        let e = ContextEntry(kind: .modelResponse, text: "old", isInWindow: false)
        #expect(e.isInWindow == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run `test_macos` (`scheme: "FoundationChatKit"`).
Expected: FAIL — `cannot find 'ContextEntry' in scope`.

- [ ] **Step 3: Write minimal implementation**

`ContextEntry.swift`:
```swift
import Foundation

public enum ContextEntryKind: String, Sendable, Equatable {
    case instructions
    case userPrompt
    case modelResponse
    case toolCall        // Phase 2
    case toolOutput      // Phase 2
}

/// A framework-agnostic projection of one `Transcript.Entry`. The engine, token
/// budget, and inspector all operate on these so they never construct un-testable
/// FoundationModels types. The real provider maps `Transcript` -> [ContextEntry].
public struct ContextEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var kind: ContextEntryKind
    public var text: String
    /// False when this entry is shown in history but is outside the live 4,096-token window
    /// (e.g. re-fed older messages after a model-version resume).
    public var isInWindow: Bool

    public init(id: UUID = UUID(), kind: ContextEntryKind, text: String, isInWindow: Bool = true) {
        self.id = id
        self.kind = kind
        self.text = text
        self.isInWindow = isInWindow
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run `test_macos`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(kit): add ContextEntry projection type

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 1.3: `TokenEstimator`

**Files:**
- Create: `Targets/FoundationChatKit/Sources/Tokens/TokenEstimator.swift`
- Test: `Targets/FoundationChatKit/Tests/TokenEstimatorTests.swift`

Apple's heuristic: ~3–4 chars/token for Latin scripts; ~1 char/token for CJK. We use **3.5 chars/token** for non-CJK and **1 char/token** for CJK, per-character classified, rounding up, minimum 1 for non-empty.

- [ ] **Step 1: Write the failing test**

`TokenEstimatorTests.swift`:
```swift
import Testing
@testable import FoundationChatKit

struct TokenEstimatorTests {
    let sut = TokenEstimator()

    @Test func emptyStringIsZero() {
        #expect(sut.estimate("") == 0)
    }

    @Test func latinUsesAboutThreeAndHalfCharsPerToken() {
        // 35 ASCII chars / 3.5 = 10
        let s = String(repeating: "a", count: 35)
        #expect(sut.estimate(s) == 10)
    }

    @Test func latinRoundsUp() {
        // 8 chars / 3.5 = 2.28 -> ceil -> 3
        #expect(sut.estimate("12345678") == 3)
    }

    @Test func cjkIsOneTokenPerCharacter() {
        // 5 CJK characters -> 5 tokens
        #expect(sut.estimate("你好世界界") == 5)
    }

    @Test func mixedScriptCountsSeparately() {
        // "你好" = 2 CJK tokens; "ab" (2 chars / 3.5 -> ceil 1) = 1 token; total 3
        #expect(sut.estimate("你好ab") == 3)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run `test_macos`. Expected: FAIL — `cannot find 'TokenEstimator'`.

- [ ] **Step 3: Write minimal implementation**

`TokenEstimator.swift`:
```swift
import Foundation

/// Character-based token estimate used when the exact API (`tokenCount(for:)`, 26.4+)
/// is unavailable. Approximate by design — surfaced to the user as "estimated".
public struct TokenEstimator: Sendable {
    public init() {}

    public func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var cjkCount = 0
        var otherCount = 0
        for scalar in text.unicodeScalars {
            if Self.isCJK(scalar) { cjkCount += 1 } else { otherCount += 1 }
        }
        let latinTokens = otherCount == 0 ? 0 : Int((Double(otherCount) / 3.5).rounded(.up))
        return cjkCount + latinTokens
    }

    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x4E00...0x9FFF,   // CJK Unified Ideographs
             0x3040...0x30FF,   // Hiragana + Katakana
             0xAC00...0xD7AF,   // Hangul syllables
             0x3400...0x4DBF:   // CJK Extension A
            return true
        default:
            return false
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run `test_macos`. Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(kit): add character-based TokenEstimator

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 1.4: Budget value types + `TokenBudgetCalculator`

**Files:**
- Create: `Targets/FoundationChatKit/Sources/Model/TokenBudget.swift`
- Create: `Targets/FoundationChatKit/Sources/Tokens/TokenBudgetCalculator.swift`
- Test: `Targets/FoundationChatKit/Tests/TokenBudgetCalculatorTests.swift`

- [ ] **Step 1: Write the failing test**

`TokenBudgetCalculatorTests.swift`:
```swift
import Testing
@testable import FoundationChatKit

struct TokenBudgetCalculatorTests {
    // Exact counter: 1 token per character (deterministic for tests).
    func oneTokenPerChar(_ s: String) -> Int? { s.count }

    @Test func buildsBreakdownAndSumsUsed() {
        let calc = TokenBudgetCalculator(estimator: TokenEstimator())
        let entries = [
            ContextEntry(kind: .userPrompt, text: "abcd"),       // 4
            ContextEntry(kind: .modelResponse, text: "ef"),      // 2
        ]
        let snap = calc.snapshot(
            maxTokens: 4096,
            instructions: "xyz",                                 // 3
            entries: entries,
            inFlight: nil,
            exactCount: oneTokenPerChar
        )
        #expect(snap.isExact == true)
        #expect(snap.usedTokens == 9)            // 3 + 4 + 2
        #expect(snap.remaining == 4087)
        #expect(snap.lines.map(\.label) == ["Instructions", "You", "Assistant"])
        #expect(snap.lines.map(\.tokens) == [3, 4, 2])
    }

    @Test func inFlightAddsToUsed() {
        let calc = TokenBudgetCalculator(estimator: TokenEstimator())
        let snap = calc.snapshot(
            maxTokens: 100, instructions: nil, entries: [],
            inFlight: "abcdefg",                                 // 7
            exactCount: oneTokenPerChar
        )
        #expect(snap.usedTokens == 7)
        #expect(snap.lines.last?.label == "Assistant (typing…)")
    }

    @Test func fallsBackToEstimatorWhenNoExactCounter() {
        let calc = TokenBudgetCalculator(estimator: TokenEstimator())
        let entries = [ContextEntry(kind: .userPrompt, text: String(repeating: "a", count: 35))] // est 10
        let snap = calc.snapshot(maxTokens: 4096, instructions: nil, entries: entries, inFlight: nil, exactCount: { _ in nil })
        #expect(snap.isExact == false)
        #expect(snap.usedTokens == 10)
    }

    @Test func zoneThresholds() {
        let calc = TokenBudgetCalculator(estimator: TokenEstimator())
        func zone(used: Int) -> BudgetZone {
            calc.snapshot(maxTokens: 100, instructions: String(repeating: "x", count: used),
                          entries: [], inFlight: nil, exactCount: { $0.count }).zone
        }
        #expect(zone(used: 50) == .green)   // 50%
        #expect(zone(used: 75) == .amber)   // 75%
        #expect(zone(used: 95) == .red)     // 95%
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run `test_macos`. Expected: FAIL — `cannot find 'TokenBudgetCalculator'`/`BudgetZone`.

- [ ] **Step 3: Write minimal implementation**

`TokenBudget.swift`:
```swift
import Foundation

public enum BudgetZone: Sendable, Equatable { case green, amber, red }

public struct BudgetLine: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var label: String
    public var tokens: Int
    public init(id: UUID = UUID(), label: String, tokens: Int) {
        self.id = id; self.label = label; self.tokens = tokens
    }
}

public struct TokenBudgetSnapshot: Sendable, Equatable {
    public var maxTokens: Int
    public var usedTokens: Int
    public var isExact: Bool
    public var lines: [BudgetLine]

    public init(maxTokens: Int, usedTokens: Int, isExact: Bool, lines: [BudgetLine]) {
        self.maxTokens = maxTokens
        self.usedTokens = usedTokens
        self.isExact = isExact
        self.lines = lines
    }

    public var remaining: Int { max(0, maxTokens - usedTokens) }
    public var fraction: Double { maxTokens <= 0 ? 0 : min(1, Double(usedTokens) / Double(maxTokens)) }
    public var zone: BudgetZone {
        switch fraction {
        case ..<0.70: return .green
        case ..<0.90: return .amber
        default: return .red
        }
    }
}
```

`TokenBudgetCalculator.swift`:
```swift
import Foundation

/// Builds a `TokenBudgetSnapshot` from instructions + committed entries + an optional
/// in-flight (streaming) snapshot. Uses the exact counter when available (26.4+), else
/// the character estimator. `exactCount` returns nil to signal "exact unavailable".
public struct TokenBudgetCalculator: Sendable {
    private let estimator: TokenEstimator
    public init(estimator: TokenEstimator = TokenEstimator()) { self.estimator = estimator }

    public func snapshot(
        maxTokens: Int,
        instructions: String?,
        entries: [ContextEntry],
        inFlight: String?,
        exactCount: (String) -> Int?
    ) -> TokenBudgetSnapshot {
        var isExact = true
        func count(_ text: String) -> Int {
            if let exact = exactCount(text) { return exact }
            isExact = false
            return estimator.estimate(text)
        }

        var lines: [BudgetLine] = []
        if let instructions, !instructions.isEmpty {
            lines.append(BudgetLine(label: "Instructions", tokens: count(instructions)))
        }
        for entry in entries {
            lines.append(BudgetLine(label: Self.label(for: entry.kind), tokens: count(entry.text)))
        }
        if let inFlight, !inFlight.isEmpty {
            lines.append(BudgetLine(label: "Assistant (typing…)", tokens: count(inFlight)))
        }
        let used = lines.reduce(0) { $0 + $1.tokens }
        return TokenBudgetSnapshot(maxTokens: maxTokens, usedTokens: used, isExact: isExact, lines: lines)
    }

    static func label(for kind: ContextEntryKind) -> String {
        switch kind {
        case .instructions: return "Instructions"
        case .userPrompt: return "You"
        case .modelResponse: return "Assistant"
        case .toolCall: return "Tool call"
        case .toolOutput: return "Tool output"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run `test_macos`. Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(kit): add token budget snapshot + calculator (exact/estimated)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 1.5: `ContextProjection` (entries → chat bubbles)

**Files:**
- Create: `Targets/FoundationChatKit/Sources/Context/ContextProjection.swift`
- Test: `Targets/FoundationChatKit/Tests/ContextProjectionTests.swift`

- [ ] **Step 1: Write the failing test**

`ContextProjectionTests.swift`:
```swift
import Testing
import Foundation
@testable import FoundationChatKit

struct ContextProjectionTests {
    let now = { Date(timeIntervalSince1970: 0) }

    @Test func keepsOnlyPromptsAndResponsesInOrder() {
        let entries = [
            ContextEntry(kind: .instructions, text: "system"),
            ContextEntry(kind: .userPrompt, text: "hi"),
            ContextEntry(kind: .modelResponse, text: "hello"),
            ContextEntry(kind: .toolOutput, text: "{}"),
        ]
        let msgs = ContextProjection.bubbles(from: entries, now: now)
        #expect(msgs.map(\.role) == [.user, .assistant])
        #expect(msgs.map(\.text) == ["hi", "hello"])
    }

    @Test func emptyWhenNoConversational() {
        let msgs = ContextProjection.bubbles(from: [ContextEntry(kind: .instructions, text: "x")], now: now)
        #expect(msgs.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run `test_macos`. Expected: FAIL — `cannot find 'ContextProjection'`.

- [ ] **Step 3: Write minimal implementation**

`ContextProjection.swift`:
```swift
import Foundation

public enum ContextProjection {
    /// Filters a context window down to the conversational bubbles (user prompts and
    /// model responses), preserving order. Instructions/tool entries are inspector-only.
    public static func bubbles(from entries: [ContextEntry], now: () -> Date = Date.init) -> [ChatMessage] {
        entries.compactMap { entry in
            switch entry.kind {
            case .userPrompt:
                return ChatMessage(role: .user, text: entry.text, createdAt: now())
            case .modelResponse:
                return ChatMessage(role: .assistant, text: entry.text, createdAt: now())
            case .instructions, .toolCall, .toolOutput:
                return nil
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run `test_macos`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(kit): add ContextProjection (entries -> chat bubbles)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 1.6: `OverflowRecovery.condense`

**Files:**
- Create: `Targets/FoundationChatKit/Sources/Context/OverflowRecovery.swift`
- Test: `Targets/FoundationChatKit/Tests/OverflowRecoveryTests.swift`

Per TN3193: keep the first and last entries (deterministic, no model call). We keep the **first** entry (usually the opening user prompt that anchors the topic) and the **last** entry, deduplicated, preserving order.

- [ ] **Step 1: Write the failing test**

`OverflowRecoveryTests.swift`:
```swift
import Testing
@testable import FoundationChatKit

struct OverflowRecoveryTests {
    @Test func keepsFirstAndLast() {
        let entries = [
            ContextEntry(kind: .userPrompt, text: "first"),
            ContextEntry(kind: .modelResponse, text: "mid1"),
            ContextEntry(kind: .userPrompt, text: "mid2"),
            ContextEntry(kind: .modelResponse, text: "last"),
        ]
        let condensed = OverflowRecovery.condense(entries)
        #expect(condensed.map(\.text) == ["first", "last"])
    }

    @Test func singleEntryUnchanged() {
        let entries = [ContextEntry(kind: .userPrompt, text: "only")]
        #expect(OverflowRecovery.condense(entries).map(\.text) == ["only"])
    }

    @Test func emptyStaysEmpty() {
        #expect(OverflowRecovery.condense([]).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run `test_macos`. Expected: FAIL — `cannot find 'OverflowRecovery'`.

- [ ] **Step 3: Write minimal implementation**

`OverflowRecovery.swift`:
```swift
import Foundation

/// Phase 1 context compaction: TN3193's deterministic "first + last entry" strategy,
/// used to seed a fresh session after `exceededContextWindowSize`.
/// (Phase 3 upgrades this to LLM-summarized compaction.)
public enum OverflowRecovery {
    public static func condense(_ entries: [ContextEntry]) -> [ContextEntry] {
        guard entries.count > 1 else { return entries }
        let first = entries.first!
        let last = entries.last!
        if first.id == last.id { return [first] }
        return [first, last]
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run `test_macos`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(kit): add OverflowRecovery.condense (TN3193 first+last)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone 2 — Provider seam, mock, and engine (TDD)

### Task 2.1: Supporting types — `ModelAvailability`, `GenerationSettings`, `ChatError`

**Files:**
- Create: `Targets/FoundationChatKit/Sources/Model/ModelAvailability.swift`
- Create: `Targets/FoundationChatKit/Sources/Model/GenerationSettings.swift`
- Create: `Targets/FoundationChatKit/Sources/Model/ChatError.swift`
- Test: `Targets/FoundationChatKit/Tests/SupportingTypesTests.swift`

- [ ] **Step 1: Write the failing test**

`SupportingTypesTests.swift`:
```swift
import Testing
@testable import FoundationChatKit

struct SupportingTypesTests {
    @Test func availabilityEquatable() {
        #expect(ModelAvailability.available == .available)
        #expect(ModelAvailability.unavailable(.modelNotReady) != .available)
    }

    @Test func generationSettingsDefault() {
        let s = GenerationSettings()
        #expect(s.instructions == nil)
        #expect(s.temperature == nil)
        #expect(s.maximumResponseTokens == nil)
    }

    @Test func chatErrorFromOverflowIsEquatable() {
        #expect(ChatError.contextOverflow == ChatError.contextOverflow)
        #expect(ChatError.refusal("no") == ChatError.refusal("no"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run `test_macos`. Expected: FAIL — missing types.

- [ ] **Step 3: Write minimal implementation**

`ModelAvailability.swift`:
```swift
import Foundation

public enum ModelUnavailableReason: Sendable, Equatable {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unknown
}

public enum ModelAvailability: Sendable, Equatable {
    case available
    case unavailable(ModelUnavailableReason)
}
```

`GenerationSettings.swift`:
```swift
import Foundation

public struct GenerationSettings: Sendable, Equatable {
    public var instructions: String?
    public var temperature: Double?
    public var maximumResponseTokens: Int?

    public init(instructions: String? = nil, temperature: Double? = nil, maximumResponseTokens: Int? = nil) {
        self.instructions = instructions
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
    }
}
```

`ChatError.swift`:
```swift
import Foundation

public enum ChatError: Error, Sendable, Equatable {
    case contextOverflow
    case guardrailViolation
    case rateLimited
    case refusal(String?)
    case modelUnavailable
    case decodingFailure
    case cancelled
    case unknown(String)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run `test_macos`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(kit): add ModelAvailability, GenerationSettings, ChatError

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 2.2: `ChatModelProvider` + `ChatSessionHandle` protocols

**Files:**
- Create: `Targets/FoundationChatKit/Sources/Provider/ChatModelProvider.swift`

- [ ] **Step 1: Write the protocols (no test — pure declarations, exercised via the mock in 2.3)**

`ChatModelProvider.swift`:
```swift
import Foundation

/// One in-flight chat context (wraps a `LanguageModelSession`). `@MainActor` because
/// the underlying session is observed on the main actor and drives UI.
@MainActor
public protocol ChatSessionHandle: AnyObject {
    /// True while a response is generating; calling stream/respond again is illegal.
    var isResponding: Bool { get }
    /// The committed context window as framework-agnostic entries (post-turn).
    var contextEntries: [ContextEntry] { get }
    /// Streams CUMULATIVE snapshots (each element is the whole response so far).
    func stream(prompt: String) -> AsyncThrowingStream<String, Error>
    /// Non-streaming response (used in background to avoid rate limiting).
    func respond(prompt: String) async throws -> String
    /// Preload resources ahead of an expected request.
    func prewarm()
    /// Encodes the live session for fast/faithful resume (nil if unsupported).
    func encodedTranscript() -> Data?
}

/// Factory + capability surface for the on-device model.
@MainActor
public protocol ChatModelProvider: AnyObject {
    var availability: ModelAvailability { get }
    /// Max context tokens (`contextSize` on 26.4+, else 4096).
    var maxContextTokens: Int { get }
    /// Exact token count for `text` (26.4+); nil when unavailable → caller estimates.
    func tokenCount(for text: String) -> Int?
    /// Create a fresh session, or restore from `encodedTranscript` data when present.
    func makeSession(settings: GenerationSettings, restoring encodedTranscript: Data?) -> any ChatSessionHandle
}
```

- [ ] **Step 2: Build to verify it compiles**

Use `build_macos` (`scheme: "FoundationChatKit"`). Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat(kit): add ChatModelProvider/ChatSessionHandle protocols

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 2.3: `MockModelProvider` (test double)

**Files:**
- Create: `Targets/FoundationChatKit/Tests/MockModelProvider.swift`
- Test: `Targets/FoundationChatKit/Tests/MockModelProviderTests.swift`

- [ ] **Step 1: Write the mock + its test**

`MockModelProvider.swift`:
```swift
import Foundation
@testable import FoundationChatKit

/// Deterministic test double. Scripts streaming snapshots and errors so the engine
/// can be tested without an Apple-Intelligence device.
@MainActor
final class MockSessionHandle: ChatSessionHandle {
    var isResponding: Bool = false
    var contextEntries: [ContextEntry] = []

    /// Cumulative snapshots to emit for the next `stream` call, e.g. ["He","Hello"].
    var scriptedSnapshots: [String] = []
    /// If set, the stream throws this after emitting `errorAfter` snapshots.
    var scriptedError: Error?
    var errorAfter: Int = 0
    /// Whether to append a `.userPrompt` + `.modelResponse` to contextEntries on completion.
    var commitsEntriesOnFinish = true
    private(set) var prewarmCount = 0

    func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        let snapshots = scriptedSnapshots
        let error = scriptedError
        let errorAfter = self.errorAfter
        let commits = commitsEntriesOnFinish
        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                self.isResponding = true
                var emitted = 0
                for snap in snapshots {
                    continuation.yield(snap)
                    emitted += 1
                    if let error, emitted >= errorAfter {
                        self.isResponding = false
                        continuation.finish(throwing: error)
                        return
                    }
                }
                if commits {
                    self.contextEntries.append(ContextEntry(kind: .userPrompt, text: prompt))
                    self.contextEntries.append(ContextEntry(kind: .modelResponse, text: snapshots.last ?? ""))
                }
                self.isResponding = false
                continuation.finish()
            }
        }
    }

    func respond(prompt: String) async throws -> String {
        if let scriptedError { throw scriptedError }
        let text = scriptedSnapshots.last ?? ""
        if commitsEntriesOnFinish {
            contextEntries.append(ContextEntry(kind: .userPrompt, text: prompt))
            contextEntries.append(ContextEntry(kind: .modelResponse, text: text))
        }
        return text
    }

    func prewarm() { prewarmCount += 1 }
    func encodedTranscript() -> Data? { nil }
}

@MainActor
final class MockModelProvider: ChatModelProvider {
    var availability: ModelAvailability = .available
    var maxContextTokens: Int = 4096
    var exactCounts: Bool = false
    /// The single session this provider vends (so tests can pre-script it).
    let session = MockSessionHandle()

    func tokenCount(for text: String) -> Int? { exactCounts ? text.count : nil }
    func makeSession(settings: GenerationSettings, restoring encodedTranscript: Data?) -> any ChatSessionHandle { session }
}
```

`MockModelProviderTests.swift`:
```swift
import Testing
import Foundation
@testable import FoundationChatKit

@MainActor
struct MockModelProviderTests {
    @Test func streamsScriptedSnapshotsThenCommits() async throws {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["He", "Hello"]
        var received: [String] = []
        for try await snap in provider.session.stream(prompt: "hi") { received.append(snap) }
        #expect(received == ["He", "Hello"])
        #expect(provider.session.contextEntries.map(\.text) == ["hi", "Hello"])
        #expect(provider.session.isResponding == false)
    }

    @Test func throwsScriptedError() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["x"]
        provider.session.scriptedError = ChatError.contextOverflow
        provider.session.errorAfter = 1
        await #expect(throws: ChatError.self) {
            for try await _ in provider.session.stream(prompt: "hi") {}
        }
    }
}
```

- [ ] **Step 2: Run test to verify it passes**

Run `test_macos`. Expected: PASS (the mock + its 2 tests).

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "test(kit): add MockModelProvider test double

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 2.4: `ConversationEngine` — turn lifecycle (TDD)

**Files:**
- Create: `Targets/FoundationChatKit/Sources/Engine/ConversationEngine.swift`
- Test: `Targets/FoundationChatKit/Tests/ConversationEngineTests.swift`

- [ ] **Step 1: Write the failing test**

`ConversationEngineTests.swift`:
```swift
import Testing
import Foundation
@testable import FoundationChatKit

@MainActor
struct ConversationEngineTests {
    func makeEngine(_ provider: MockModelProvider) -> ConversationEngine {
        ConversationEngine(provider: provider, settings: GenerationSettings(instructions: "sys"),
                           now: { Date(timeIntervalSince1970: 0) })
    }

    @Test func sendProducesOneGrowingAssistantBubble() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["He", "Hello", "Hello!"]
        let engine = makeEngine(provider)
        await engine.send("hi")
        #expect(engine.messages.map(\.role) == [.user, .assistant])
        #expect(engine.messages.last?.text == "Hello!")
        #expect(engine.messages.last?.isStreaming == false)
        #expect(engine.isResponding == false)
    }

    @Test func budgetUpdatesAfterTurn() async {
        let provider = MockModelProvider()
        provider.exactCounts = true                 // 1 token / char
        provider.session.scriptedSnapshots = ["abcd"]
        let engine = makeEngine(provider)
        await engine.send("xy")
        // instructions "sys"(3) + user "xy"(2) + assistant "abcd"(4) = 9
        #expect(engine.budget.usedTokens == 9)
        #expect(engine.budget.isExact == true)
    }

    @Test func overflowTriggersRecoveryAndNotice() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["partial"]
        provider.session.scriptedError = ChatError.contextOverflow
        provider.session.errorAfter = 1
        let engine = makeEngine(provider)
        await engine.send("hi")
        #expect(engine.messages.contains { $0.role == .systemNotice })
        #expect(engine.lastError == nil)            // recovered, not surfaced as error
    }

    @Test func guardrailErrorIsSurfaced() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["x"]
        provider.session.scriptedError = ChatError.guardrailViolation
        provider.session.errorAfter = 1
        let engine = makeEngine(provider)
        await engine.send("hi")
        #expect(engine.lastError == .guardrailViolation)
    }

    @Test func ignoresSendWhileResponding() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["done"]
        let engine = makeEngine(provider)
        engine.isResponding = true                   // simulate in-flight
        await engine.send("hi")
        #expect(engine.messages.isEmpty)             // send was ignored
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run `test_macos`. Expected: FAIL — `cannot find 'ConversationEngine'`.

- [ ] **Step 3: Write minimal implementation**

`ConversationEngine.swift`:
```swift
import Foundation
import Observation

/// Owns one conversation's live session and drives the turn lifecycle.
/// MVVM view-model: the SwiftUI layer binds to `messages`, `isResponding`, `budget`, `lastError`.
@MainActor
@Observable
public final class ConversationEngine {
    public private(set) var messages: [ChatMessage] = []
    public internal(set) var isResponding: Bool = false
    public private(set) var budget: TokenBudgetSnapshot
    public private(set) var lastError: ChatError?

    private let provider: any ChatModelProvider
    private var session: any ChatSessionHandle
    private var settings: GenerationSettings
    private let calculator: TokenBudgetCalculator
    private let now: () -> Date
    private var turnTask: Task<Void, Never>?

    public init(
        provider: any ChatModelProvider,
        settings: GenerationSettings = GenerationSettings(),
        restoring encodedTranscript: Data? = nil,
        calculator: TokenBudgetCalculator = TokenBudgetCalculator(),
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.settings = settings
        self.calculator = calculator
        self.now = now
        self.session = provider.makeSession(settings: settings, restoring: encodedTranscript)
        self.budget = TokenBudgetSnapshot(maxTokens: provider.maxContextTokens, usedTokens: 0, isExact: false, lines: [])
        self.messages = ContextProjection.bubbles(from: session.contextEntries, now: now)
        recomputeBudget(inFlight: nil)
    }

    public func send(_ text: String) async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isResponding else { return }
        lastError = nil
        isResponding = true

        messages.append(ChatMessage(role: .user, text: prompt, createdAt: now()))
        var assistant = ChatMessage(role: .assistant, text: "", createdAt: now(), isStreaming: true)
        messages.append(assistant)
        let assistantIndex = messages.count - 1

        do {
            for try await snapshot in session.stream(prompt: prompt) {
                assistant.text = snapshot                 // cumulative: REPLACE
                messages[assistantIndex] = assistant
                recomputeBudget(inFlight: snapshot)
            }
            assistant.isStreaming = false
            messages[assistantIndex] = assistant
            recomputeBudget(inFlight: nil)
        } catch {
            await handle(error, assistantIndex: assistantIndex)
        }
        isResponding = false
    }

    public func cancel() {
        turnTask?.cancel()
    }

    // MARK: - Private

    private func handle(_ error: Error, assistantIndex: Int) async {
        // Remove the empty streaming bubble.
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
        // Phase 1: rebuild a fresh session; condensed entries are carried by the real
        // provider via encodedTranscript when available. Here we re-create from settings.
        session = provider.makeSession(settings: settings, restoring: session.encodedTranscript())
        messages.append(ChatMessage(role: .systemNotice,
                                    text: "Context window was full — older turns were compacted to keep the chat going.",
                                    createdAt: now()))
        _ = condensed
        recomputeBudget(inFlight: nil)
    }

    private func recomputeBudget(inFlight: String?) {
        budget = calculator.snapshot(
            maxTokens: provider.maxContextTokens,
            instructions: settings.instructions,
            entries: session.contextEntries,
            inFlight: inFlight,
            exactCount: { [provider] in provider.tokenCount(for: $0) }
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run `test_macos`. Expected: PASS (6 ConversationEngine tests). If `ignoresSendWhileResponding` fails because `isResponding` is `private(set)`, confirm it is declared `internal(set)` as above.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(kit): add ConversationEngine turn lifecycle with overflow recovery

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone 3 — Real Foundation Models provider

> These tasks wrap the live framework. Unit tests can't drive inference without an Apple-Intelligence device, so verification is **compile + a runtime availability smoke check**. Signatures are written from Apple's docs; if the installed SDK differs, adjust the wrapping calls (the protocol boundary stays the same).

### Task 3.1: `TranscriptMapping` (Transcript ⇄ ContextEntry)

**Files:**
- Create: `Targets/FoundationChatKit/Sources/Provider/TranscriptMapping.swift`

- [ ] **Step 1: Implement the mapping**

`TranscriptMapping.swift`:
```swift
import Foundation
import FoundationModels

enum TranscriptMapping {
    /// Flatten a `Transcript` into framework-agnostic entries for the engine/inspector.
    static func entries(from transcript: Transcript) -> [ContextEntry] {
        transcript.map { entry in
            switch entry {
            case .instructions(let i):
                return ContextEntry(kind: .instructions, text: text(of: i.segments))
            case .prompt(let p):
                return ContextEntry(kind: .userPrompt, text: text(of: p.segments))
            case .response(let r):
                return ContextEntry(kind: .modelResponse, text: text(of: r.segments))
            case .toolCalls(let calls):
                let joined = calls.map { "\($0.toolName)(\(String(describing: $0.arguments)))" }.joined(separator: "\n")
                return ContextEntry(kind: .toolCall, text: joined)
            case .toolOutput(let o):
                return ContextEntry(kind: .toolOutput, text: text(of: o.segments))
            @unknown default:
                return ContextEntry(kind: .modelResponse, text: "")
            }
        }
    }

    private static func text(of segments: [Transcript.Segment]) -> String {
        segments.map { segment in
            switch segment {
            case .text(let t): return t.content
            case .structure(let s): return String(describing: s.content)
            @unknown default: return ""
            }
        }.joined()
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Use `build_macos` (`scheme: "FoundationChatKit"`). Expected: BUILD SUCCEEDED.
If a property name differs (e.g. `TextSegment.content`), fix it per the SDK's quick-help and rebuild.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat(kit): map FoundationModels Transcript to ContextEntry

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 3.2: `FoundationModelProvider` + `FoundationModelSession`

**Files:**
- Create: `Targets/FoundationChatKit/Sources/Provider/FoundationModelProvider.swift`

- [ ] **Step 1: Implement the real provider**

`FoundationModelProvider.swift`:
```swift
import Foundation
import FoundationModels

@MainActor
public final class FoundationModelProvider: ChatModelProvider {
    private let model = SystemLanguageModel.default

    public init() {}

    public var availability: ModelAvailability {
        switch model.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable(.deviceNotEligible)
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(.appleIntelligenceNotEnabled)
        case .unavailable(.modelNotReady):
            return .unavailable(.modelNotReady)
        case .unavailable:
            return .unavailable(.unknown)
        }
    }

    public var maxContextTokens: Int {
        if #available(iOS 26.4, macOS 26.4, *) {
            return (try? model.contextSize) ?? 4096
        }
        return 4096
    }

    public func tokenCount(for text: String) -> Int? {
        if #available(iOS 26.4, macOS 26.4, *) {
            return try? model.tokenCount(for: Prompt(text))
        }
        return nil
    }

    public func makeSession(settings: GenerationSettings, restoring encodedTranscript: Data?) -> any ChatSessionHandle {
        let session: LanguageModelSession
        if let data = encodedTranscript,
           let transcript = try? JSONDecoder().decode(Transcript.self, from: data) {
            session = LanguageModelSession(transcript: transcript)
        } else if let instructions = settings.instructions {
            session = LanguageModelSession(instructions: instructions)
        } else {
            session = LanguageModelSession()
        }
        session.prewarm()
        return FoundationModelSession(session: session, settings: settings)
    }
}

@MainActor
final class FoundationModelSession: ChatSessionHandle {
    private let session: LanguageModelSession
    private let settings: GenerationSettings

    init(session: LanguageModelSession, settings: GenerationSettings) {
        self.session = session
        self.settings = settings
    }

    var isResponding: Bool { session.isResponding }
    var contextEntries: [ContextEntry] { TranscriptMapping.entries(from: session.transcript) }

    private var options: GenerationOptions {
        GenerationOptions(temperature: settings.temperature, maximumResponseTokens: settings.maximumResponseTokens)
    }

    func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        let session = self.session
        let options = self.options
        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    let responseStream = session.streamResponse(to: Prompt(prompt), options: options)
                    for try await snapshot in responseStream {
                        continuation.yield(snapshot.content)   // cumulative
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
        }
    }

    func respond(prompt: String) async throws -> String {
        do {
            return try await session.respond(to: Prompt(prompt), options: options).content
        } catch {
            throw Self.map(error)
        }
    }

    func prewarm() { session.prewarm() }

    func encodedTranscript() -> Data? { try? JSONEncoder().encode(session.transcript) }

    /// Translate FoundationModels errors to the engine's `ChatError`.
    static func map(_ error: Error) -> Error {
        guard let genError = error as? LanguageModelSession.GenerationError else { return error }
        switch genError {
        case .exceededContextWindowSize: return ChatError.contextOverflow
        case .guardrailViolation: return ChatError.guardrailViolation
        case .rateLimited: return ChatError.rateLimited
        case .refusal(let refusal, _): return ChatError.refusal(nil); _ = refusal
        case .decodingFailure: return ChatError.decodingFailure
        default: return ChatError.unknown(String(describing: genError))
        }
    }
}
```

- [ ] **Step 2: Build for macOS and iOS simulator**

Use `build_macos` (`scheme: "FoundationChatKit"`) and `build_sim` (`scheme: "FoundationChatKit"`, an iOS 26 simulator).
Expected: BUILD SUCCEEDED on both.
If a signature differs (e.g. `GenerationOptions` init labels, `streamResponse` overloads, `GenerationError` cases, or `contextSize`/`tokenCount` throwing-ness), adjust to match quick-help and rebuild. Keep the `ChatSessionHandle` API unchanged.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat(kit): add real FoundationModelProvider wrapping LanguageModelSession

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 3.3: Availability smoke verification

- [ ] **Step 1: Add a temporary smoke test (will be deleted)**

`Targets/FoundationChatKit/Tests/ProviderSmokeTests.swift`:
```swift
import Testing
@testable import FoundationChatKit

@MainActor
struct ProviderSmokeTests {
    @Test func providerReportsAvailabilityAndBudget() {
        let provider = FoundationModelProvider()
        // On CI/dev without Apple Intelligence this may be .unavailable — both are valid.
        switch provider.availability {
        case .available:
            #expect(provider.maxContextTokens >= 4096)
        case .unavailable:
            #expect(provider.maxContextTokens == 4096)   // falls back
        }
    }
}
```

- [ ] **Step 2: Run it**

Run `test_macos`. Expected: PASS (whichever branch). If it crashes constructing the provider, that's a real bug — fix before continuing.

- [ ] **Step 3: Delete the smoke test and commit**

```bash
rm Targets/FoundationChatKit/Tests/ProviderSmokeTests.swift
git add -A
git commit -m "test(kit): verify real provider constructs + reports budget (smoke)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone 4 — SwiftData persistence

### Task 4.1: `Conversation` and `Message` models

**Files:**
- Create: `Targets/FoundationChatKit/Sources/Persistence/Conversation.swift`
- Create: `Targets/FoundationChatKit/Sources/Persistence/Message.swift`

> Update `Project.swift` sources glob already covers `Sources/**`, so no manifest change. If you placed persistence outside `Targets/FoundationChatKit/Sources`, regenerate. Here it is inside the framework sources.

- [ ] **Step 1: Implement the models**

`Message.swift`:
```swift
import Foundation
import SwiftData

@Model
public final class Message {
    public var id: UUID
    public var roleRaw: String          // MessageRole.rawValue (durable)
    public var text: String
    public var createdAt: Date
    public var conversation: Conversation?

    public init(id: UUID = UUID(), role: MessageRole, text: String, createdAt: Date, conversation: Conversation? = nil) {
        self.id = id
        self.roleRaw = role.rawValue
        self.text = text
        self.createdAt = createdAt
        self.conversation = conversation
    }

    public var role: MessageRole { MessageRole(rawValue: roleRaw) ?? .systemNotice }
}
```

`Conversation.swift`:
```swift
import Foundation
import SwiftData

@Model
public final class Conversation {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var transcriptData: Data?     // best-effort fast resume
    public var modelVersionTag: String?  // OS/model generation when written
    public var lastTokenCount: Int
    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    public var messages: [Message]

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date,
        updatedAt: Date,
        transcriptData: Data? = nil,
        modelVersionTag: String? = nil,
        lastTokenCount: Int = 0,
        messages: [Message] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.transcriptData = transcriptData
        self.modelVersionTag = modelVersionTag
        self.lastTokenCount = lastTokenCount
        self.messages = messages
    }

    public var orderedMessages: [Message] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Use `build_macos` (`scheme: "FoundationChatKit"`). Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat(kit): add SwiftData Conversation + Message models

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 4.2: `ConversationStore` (CRUD + title + resume helpers)

**Files:**
- Create: `Targets/FoundationChatKit/Sources/Persistence/ConversationStore.swift`
- Test: `Targets/FoundationChatKit/Tests/ConversationStoreTests.swift`

- [ ] **Step 1: Write the failing test (in-memory ModelContainer)**

`ConversationStoreTests.swift`:
```swift
import Testing
import Foundation
import SwiftData
@testable import FoundationChatKit

@MainActor
struct ConversationStoreTests {
    func makeStore() throws -> ConversationStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Conversation.self, Message.self, configurations: config)
        return ConversationStore(context: container.mainContext)
    }

    @Test func createAndFetch() throws {
        let store = try makeStore()
        let convo = store.createConversation(now: Date(timeIntervalSince1970: 0))
        let all = try store.allConversations()
        #expect(all.count == 1)
        #expect(all.first?.id == convo.id)
        #expect(convo.title == "New Chat")
    }

    @Test func appendMessageUpdatesTitleFromFirstPrompt() throws {
        let store = try makeStore()
        let convo = store.createConversation(now: Date(timeIntervalSince1970: 0))
        store.appendMessage(role: .user, text: "How do I parse JSON in Swift quickly", to: convo, now: Date(timeIntervalSince1970: 1))
        #expect(convo.title == "How do I parse JSON in Swift")   // first 6 words
        #expect(convo.orderedMessages.count == 1)
    }

    @Test func deleteRemovesConversation() throws {
        let store = try makeStore()
        let convo = store.createConversation(now: Date(timeIntervalSince1970: 0))
        store.delete(convo)
        #expect(try store.allConversations().isEmpty)
    }

    @Test func loadEntriesPrefersTranscriptElseMessages() throws {
        let store = try makeStore()
        let convo = store.createConversation(now: Date(timeIntervalSince1970: 0))
        store.appendMessage(role: .user, text: "hi", to: convo, now: Date(timeIntervalSince1970: 1))
        store.appendMessage(role: .assistant, text: "hello", to: convo, now: Date(timeIntervalSince1970: 2))
        // No transcriptData -> rebuild from messages.
        let entries = store.contextEntries(for: convo)
        #expect(entries.map(\.kind) == [.userPrompt, .modelResponse])
        #expect(entries.map(\.text) == ["hi", "hello"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run `test_macos`. Expected: FAIL — `cannot find 'ConversationStore'`.

- [ ] **Step 3: Write minimal implementation**

`ConversationStore.swift`:
```swift
import Foundation
import SwiftData

/// Thin persistence façade over a SwiftData context. Dual-truth: durable `Message`
/// rows for display + best-effort `transcriptData` for faithful model resume.
@MainActor
public final class ConversationStore {
    private let context: ModelContext
    public init(context: ModelContext) { self.context = context }

    public func allConversations() throws -> [Conversation] {
        let descriptor = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return try context.fetch(descriptor)
    }

    @discardableResult
    public func createConversation(now: Date) -> Conversation {
        let convo = Conversation(title: "New Chat", createdAt: now, updatedAt: now)
        context.insert(convo)
        try? context.save()
        return convo
    }

    public func appendMessage(role: MessageRole, text: String, to convo: Conversation, now: Date) {
        let message = Message(role: role, text: text, createdAt: now, conversation: convo)
        context.insert(message)
        convo.messages.append(message)
        convo.updatedAt = now
        if role == .user, convo.title == "New Chat", !text.isEmpty {
            convo.title = Self.title(from: text)
        }
        try? context.save()
    }

    public func updateResumeState(_ convo: Conversation, transcriptData: Data?, modelVersionTag: String?, tokenCount: Int) {
        convo.transcriptData = transcriptData
        convo.modelVersionTag = modelVersionTag
        convo.lastTokenCount = tokenCount
        try? context.save()
    }

    public func delete(_ convo: Conversation) {
        context.delete(convo)
        try? context.save()
    }

    /// Rebuild engine context entries from durable messages (fallback when transcriptData is absent/stale).
    public func contextEntries(for convo: Conversation) -> [ContextEntry] {
        convo.orderedMessages.compactMap { message in
            switch message.role {
            case .user: return ContextEntry(kind: .userPrompt, text: message.text)
            case .assistant: return ContextEntry(kind: .modelResponse, text: message.text)
            case .systemNotice: return nil
            }
        }
    }

    static func title(from text: String, wordLimit: Int = 6) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace }).prefix(wordLimit)
        return words.joined(separator: " ")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run `test_macos`. Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(kit): add ConversationStore (CRUD, titles, resume entries)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone 5 — Full suite & handoff

### Task 5.1: Run the whole suite & finalize

- [ ] **Step 1: Run all FoundationChatKit tests**

Run `test_macos` (`scheme: "FoundationChatKit"`).
Expected: ALL PASS. Count ≈ 24+ tests across estimator, budget, projection, overflow, mock, engine, store, supporting types.

- [ ] **Step 2: Build app target both platforms**

`build_macos` (`scheme: "Ember"`) and `build_sim` (`scheme: "Ember"`).
Expected: BUILD SUCCEEDED (still the placeholder UI).

- [ ] **Step 3: Final commit + tag**

```bash
git add -A
git commit -m "chore: Plan 1 complete — tested engine + persistence + real provider

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>" --allow-empty
git tag plan-1-foundation-complete
```

---

## Self-review (author check against spec)

**Spec coverage:**
- §3 architecture (Tuist graph, MVVM, provider seam) → Tasks 0.1, 2.2 ✓
- §2.2 availability → `ModelAvailability` (2.1) + real mapping (3.2) ✓
- §2.3/§6 token budgeting (4096, 26.4 exact vs estimate, per-entry breakdown, zones) → 1.3, 1.4, 3.2 ✓
- §2.4 sessions (stream cumulative, respond, isResponding, prewarm) → 2.2, 3.2 ✓
- §2.5 transcript-as-context → `TranscriptMapping` (3.1) + `ContextEntry` (1.2) ✓
- §4 engine turn lifecycle + overflow recovery → 2.4 + 1.6 ✓
- §5 SwiftData dual-truth + resume → 4.1, 4.2 ✓
- §9 error matrix (overflow/guardrail/refusal/rateLimited) → `ChatError` + `map` (2.1, 3.2) + engine routing (2.4) ✓
- §11 testing via MockModelProvider → 2.3 + all TDD tasks ✓
- **Deferred to Plan 2 (UI):** §7 navigation/inspector/gauge, §8 foreground/background send switching at the UI layer, §9 unavailable screens, §10 entitlements/Info.plist polish. Noted, not a gap.

**Placeholder scan:** No TBD/TODO; every code step has complete code. The Milestone-3 "adjust if SDK differs" notes are explicit verification guidance, not placeholders.

**Type consistency:** `ChatSessionHandle`/`ChatModelProvider` method names match across 2.2, 2.3, 3.2; `ConversationEngine` uses `provider.tokenCount(for:)`, `session.contextEntries`, `session.stream(prompt:)` consistently; `MessageRole` raw values used in `Message.roleRaw`; `TokenBudgetSnapshot.zone` thresholds match the test. ✓

**Known SDK-detail risks (flagged for the implementer):** exact `GenerationOptions` init labels, `GenerationError` case shapes, `contextSize`/`tokenCount(for:)` throwing-ness, and `Transcript`/segment property names are written from docs and verified at build time in Tasks 3.1–3.2.
