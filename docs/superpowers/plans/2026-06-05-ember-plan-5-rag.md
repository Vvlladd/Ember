# Ember — Plan 5: Conversation-Memory RAG Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On-device long-term memory — the model recalls relevant snippets from past conversations via a `searchMemory` tool backed by `NLEmbedding` semantic search, surfaced in the Context inspector.

**Architecture:** A `TextEmbedder` seam (real `NLTextEmbedder` + deterministic `MockEmbedder`) feeds a `MemoryStore` that embeds messages on save (+ backfill) and serves brute-force cosine top-k. A pure, `Sendable` `MemorySearchTool` (Plan 3 `Tool`) runs retrieval over an immutable per-session snapshot. One additive schema field (`Message.embedding`).

**Tech Stack:** Swift 6, FoundationModels, **NaturalLanguage**, SwiftData, Tuist, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-06-05-ember-conversation-memory-rag-design.md`

---

## Conventions for the executing engineer
- **Branch:** `plan-5-rag` (already created off `plan-4-hardening`; the spec is already committed here).
- **TDD** for all `FoundationChatKit` logic (N, O, P, Q). App wiring (EmberApp) is verified by **build**; R verifies by **running**.
- **Tuist:** after creating/deleting any file run `tuist generate --no-open` before building/testing.
- **Framework test:** `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`.
- **Build app (macOS):** `xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=macOS' build 2>&1 | tail -10`.
- **Build app (iOS):** `xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -10`.
- Swift Testing (`import Testing`); `@testable import FoundationChatKit`. Sandbox failure → retry Bash with `dangerouslyDisableSandbox: true`. SourceKit "No such module"/"cannot find type" are false — trust xcodebuild.
- FoundationModels/NaturalLanguage grounding: if a symbol doesn't resolve, verify via `fetchAppleDocumentation` (e.g. `/documentation/naturallanguage/nlembedding/vector(for:)`).
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **Current API (do not break):** `Tool`/`@Generable` (Plan 3); `Toolbox.defaultTools()`; `ChatCoordinator.init(provider:store:settings:modelVersionTag:now:)`; `ConversationStore(context:)`; `Message(id:role:text:createdAt:conversation:)`; `MessageRole` (`.user`/`.assistant`/`.systemNotice`).

---

## File structure
```
FoundationChatKit/Sources/
  Memory/Vector.swift            # NEW pure cosine
  Memory/TextEmbedder.swift      # NEW protocol + NLTextEmbedder
  Memory/MemoryRecord.swift      # NEW MemoryRecord + MemoryHit
  Memory/MemoryStore.swift       # NEW @MainActor index/backfill/snapshot + static search
  Tools/MemorySearchTool.swift   # NEW Tool over a Sendable snapshot
  Persistence/Message.swift      # MODIFY + embedding: Data?
  App/ChatCoordinator.swift      # MODIFY memory: param, backfill, index-on-send, register tool
FoundationChatKit/Tests/
  VectorTests.swift  MockEmbedder.swift  MockEmbedderTests.swift
  MemoryStoreTests.swift  MemorySearchToolTests.swift  (extend) ChatCoordinatorTests.swift
Ember/Sources/
  EmberApp.swift                 # MODIFY construct MemoryStore on the shared context
```

---

## Milestone N — Embedding seam + cosine

### Task N1: `Vector.cosineSimilarity` (pure)

**Files:**
- Create: `Targets/FoundationChatKit/Sources/Memory/Vector.swift`
- Test: `Targets/FoundationChatKit/Tests/VectorTests.swift`

- [ ] **Step 1: Write the failing test** — `VectorTests.swift`:
```swift
import Testing
@testable import FoundationChatKit

struct VectorTests {
    @Test func identicalIsOne() { #expect(abs(Vector.cosineSimilarity([1, 2, 3], [1, 2, 3]) - 1) < 1e-5) }
    @Test func orthogonalIsZero() { #expect(abs(Vector.cosineSimilarity([1, 0], [0, 1])) < 1e-5) }
    @Test func emptyIsZero() { #expect(Vector.cosineSimilarity([], []) == 0) }
    @Test func mismatchedLengthIsZero() { #expect(Vector.cosineSimilarity([1, 2], [1, 2, 3]) == 0) }
    @Test func zeroVectorIsZero() { #expect(Vector.cosineSimilarity([0, 0], [1, 1]) == 0) }
}
```

- [ ] **Step 2: Run → FAIL** — `tuist generate --no-open`, framework test command. Expected: `Vector` not found.

- [ ] **Step 3: Implement `Vector.swift`**:
```swift
import Foundation

public enum Vector {
    /// Cosine similarity in [-1, 1]; returns 0 for empty, zero-magnitude, or length-mismatched inputs.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}
```

- [ ] **Step 4: Run → PASS** — framework test command → `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**
```bash
git add Targets/FoundationChatKit
git commit -m "feat(kit): pure cosine similarity for memory retrieval

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task N2: `TextEmbedder` protocol + `NLTextEmbedder` + `MockEmbedder`

**Files:**
- Create: `Targets/FoundationChatKit/Sources/Memory/TextEmbedder.swift`
- Create: `Targets/FoundationChatKit/Tests/MockEmbedder.swift`, `Targets/FoundationChatKit/Tests/MockEmbedderTests.swift`

> `NLTextEmbedder` uses `NLEmbedding` (real on-device model) so it's build-verified; `MockEmbedder` is the tested double. Verify `NLEmbedding.sentenceEmbedding(for:)` / `.vector(for:)` via `fetchAppleDocumentation /documentation/naturallanguage/nlembedding` if needed — `vector(for:)` returns `[Double]?`.

- [ ] **Step 1: Write the failing test** — `MockEmbedder.swift` (test double) and `MockEmbedderTests.swift`:

`MockEmbedder.swift`:
```swift
import Foundation
@testable import FoundationChatKit

/// Deterministic bag-of-words embedder for tests: a vector over a fixed vocabulary so texts that
/// share words score higher in cosine. No NaturalLanguage dependency.
struct MockEmbedder: TextEmbedder {
    let vocabulary: [String]
    init(vocabulary: [String] = ["swift", "trip", "paris", "budget", "weather", "dog", "music", "code"]) {
        self.vocabulary = vocabulary
    }
    func embed(_ text: String) -> [Float]? {
        let words = Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        let v = vocabulary.map { words.contains($0) ? Float(1) : Float(0) }
        return v.allSatisfy { $0 == 0 } ? nil : v
    }
}
```
`MockEmbedderTests.swift`:
```swift
import Testing
@testable import FoundationChatKit

struct MockEmbedderTests {
    @Test func overlappingScoresHigherThanUnrelated() {
        let e = MockEmbedder()
        let q = e.embed("planning a trip to paris")!
        let related = e.embed("paris trip ideas")!
        let unrelated = e.embed("debugging swift code")!
        #expect(Vector.cosineSimilarity(q, related) > Vector.cosineSimilarity(q, unrelated))
    }
    @Test func noKnownWordsIsNil() { #expect(MockEmbedder().embed("zzz qqq") == nil) }
}
```

- [ ] **Step 2: Run → FAIL** — `tuist generate --no-open`, framework test command. Expected: `TextEmbedder` not found.

- [ ] **Step 3: Implement `TextEmbedder.swift`**:
```swift
import Foundation
import NaturalLanguage

/// Produces a dense vector for a piece of text. Mock-able so memory logic is testable off-device.
public protocol TextEmbedder: Sendable {
    func embed(_ text: String) -> [Float]?
}

/// Real on-device embedder over `NLEmbedding` sentence vectors (no asset download required).
public struct NLTextEmbedder: TextEmbedder {
    private let language: NLLanguage
    public init(language: NLLanguage = .english) { self.language = language }

    public func embed(_ text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let embedding = NLEmbedding.sentenceEmbedding(for: language),
              let vector = embedding.vector(for: trimmed) else { return nil }
        return vector.map { Float($0) }
    }
}
```

- [ ] **Step 4: Run → PASS** — framework test command → `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**
```bash
git add Targets/FoundationChatKit
git commit -m "feat(kit): TextEmbedder seam (NLEmbedding real + mock)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone O — MemoryStore + schema

### Task O1: `Message.embedding` + `MemoryRecord`/`MemoryHit`

**Files:**
- Modify: `Targets/FoundationChatKit/Sources/Persistence/Message.swift`
- Create: `Targets/FoundationChatKit/Sources/Memory/MemoryRecord.swift`
- Test: `Targets/FoundationChatKit/Tests/MemoryStoreTests.swift` (new — start it here)

- [ ] **Step 1: Write the failing test** — `MemoryStoreTests.swift`:
```swift
import Testing
import Foundation
import SwiftData
@testable import FoundationChatKit

@MainActor
struct MemoryStoreTests {
    @Test func messageStoresEmbedding() {
        let m = Message(role: .user, text: "hi", createdAt: Date(timeIntervalSince1970: 0),
                        embedding: Data([1, 2, 3]))
        #expect(m.embedding == Data([1, 2, 3]))
    }
    @Test func memoryRecordInit() {
        let r = MemoryRecord(messageID: UUID(), conversationID: UUID(), conversationTitle: "T",
                             role: .user, text: "x", vector: [1, 2])
        #expect(r.vector == [1, 2])
        #expect(MemoryHit(record: r, score: 0.5).score == 0.5)
    }
}
```

- [ ] **Step 2: Run → FAIL** — `tuist generate --no-open`, framework test command. Expected: `Message` has no `embedding` param / `MemoryRecord` not found.

- [ ] **Step 3a: Add `Message.embedding`** — in `Message.swift`, add the stored property after `conversation`:
```swift
    public var embedding: Data?
```
Add the init parameter (after `conversation: Conversation? = nil`):
```swift
        embedding: Data? = nil,
```
and assign in the body (after `self.conversation = conversation`):
```swift
        self.embedding = embedding
```

- [ ] **Step 3b: Create `MemoryRecord.swift`**:
```swift
import Foundation

/// An immutable, Sendable snapshot of one embedded message — used for off-actor cosine search.
public struct MemoryRecord: Sendable, Equatable {
    public let messageID: UUID
    public let conversationID: UUID
    public let conversationTitle: String
    public let role: MessageRole
    public let text: String
    public let vector: [Float]
    public init(messageID: UUID, conversationID: UUID, conversationTitle: String,
                role: MessageRole, text: String, vector: [Float]) {
        self.messageID = messageID
        self.conversationID = conversationID
        self.conversationTitle = conversationTitle
        self.role = role
        self.text = text
        self.vector = vector
    }
}

/// A scored search result.
public struct MemoryHit: Sendable, Equatable {
    public let record: MemoryRecord
    public let score: Float
    public init(record: MemoryRecord, score: Float) {
        self.record = record
        self.score = score
    }
}
```

- [ ] **Step 4: Run → PASS** — framework test command → `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**
```bash
git add Targets/FoundationChatKit
git commit -m "feat(kit): Message.embedding field + MemoryRecord/MemoryHit

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task O2: `MemoryStore` (index, backfill, snapshot, search)

**Files:**
- Create: `Targets/FoundationChatKit/Sources/Memory/MemoryStore.swift`
- Test: `Targets/FoundationChatKit/Tests/MemoryStoreTests.swift` (extend)

- [ ] **Step 1: Add the failing tests** (append inside `MemoryStoreTests`):
```swift
    private func makeStore() throws -> (MemoryStore, ConversationStore) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Conversation.self, Message.self, configurations: config)
        let context = ModelContext(container)
        return (MemoryStore(context: context, embedder: MockEmbedder()),
                ConversationStore(context: context))
    }

    @Test func indexSetsEmbedding() throws {
        let (mem, store) = try makeStore()
        let c = store.createConversation(now: Date(timeIntervalSince1970: 0))
        store.appendMessage(role: .user, text: "trip to paris", to: c, now: Date(timeIntervalSince1970: 0))
        let m = c.orderedMessages.first!
        #expect(m.embedding == nil)
        mem.index(m)
        #expect(m.embedding != nil)
    }
    @Test func backfillEmbedsAllAndSnapshots() throws {
        let (mem, store) = try makeStore()
        let c = store.createConversation(now: Date(timeIntervalSince1970: 0))
        store.appendMessage(role: .user, text: "trip to paris", to: c, now: Date(timeIntervalSince1970: 0))
        store.appendMessage(role: .assistant, text: "paris is great", to: c, now: Date(timeIntervalSince1970: 1))
        mem.backfill()
        #expect(c.orderedMessages.allSatisfy { $0.embedding != nil })
        #expect(mem.snapshot().count == 2)
    }
    @Test func searchRanksAndExcludes() throws {
        let (mem, store) = try makeStore()
        let c = store.createConversation(now: Date(timeIntervalSince1970: 0))
        store.appendMessage(role: .user, text: "trip to paris", to: c, now: Date(timeIntervalSince1970: 0))
        store.appendMessage(role: .user, text: "debugging swift code", to: c, now: Date(timeIntervalSince1970: 1))
        mem.backfill()
        let snap = mem.snapshot()
        let q = MockEmbedder().embed("paris trip")!
        let hits = MemoryStore.search(snap, queryVector: q, topK: 3, threshold: 0.1)
        #expect(hits.first?.record.text == "trip to paris")
        let excluded = Set(snap.filter { $0.text == "trip to paris" }.map(\.messageID))
        let hits2 = MemoryStore.search(snap, queryVector: q, topK: 3, threshold: 0.1, excludingMessageIDs: excluded)
        #expect(!hits2.contains { $0.record.text == "trip to paris" })
    }
```

- [ ] **Step 2: Run → FAIL** — `tuist generate --no-open`, framework test command. Expected: `MemoryStore` not found.

- [ ] **Step 3: Implement `MemoryStore.swift`**:
```swift
import Foundation
import SwiftData

/// Embeds messages on save (and via one-time backfill) and serves brute-force cosine retrieval.
@MainActor
public final class MemoryStore {
    private let context: ModelContext
    public let embedder: any TextEmbedder

    public init(context: ModelContext, embedder: any TextEmbedder) {
        self.context = context
        self.embedder = embedder
    }

    /// Embed and persist a vector for `message` if it lacks one (skips system notices / empty text).
    public func index(_ message: Message) {
        guard message.embedding == nil, message.role != .systemNotice else { return }
        guard let vector = embedder.embed(message.text) else { return }
        message.embedding = Self.archive(vector)
        try? context.save()
    }

    /// One-time embedding of all persisted messages lacking a vector.
    public func backfill() {
        let all = (try? context.fetch(FetchDescriptor<Message>())) ?? []
        for message in all where message.embedding == nil { index(message) }
    }

    /// Immutable snapshot of every embedded message for off-actor cosine search.
    public func snapshot() -> [MemoryRecord] {
        let all = (try? context.fetch(FetchDescriptor<Message>())) ?? []
        return all.compactMap { message in
            guard let data = message.embedding, message.role != .systemNotice else { return nil }
            return MemoryRecord(
                messageID: message.id,
                conversationID: message.conversation?.id ?? UUID(),
                conversationTitle: message.conversation?.title ?? "Untitled",
                role: message.role,
                text: message.text,
                vector: Self.unarchive(data)
            )
        }
    }

    /// Pure brute-force cosine top-k over a snapshot; drops excluded ids and scores below `threshold`.
    public static func search(_ snapshot: [MemoryRecord], queryVector: [Float],
                              topK: Int = 3, threshold: Float = 0.2,
                              excludingMessageIDs excluded: Set<UUID> = []) -> [MemoryHit] {
        snapshot
            .filter { !excluded.contains($0.messageID) }
            .map { MemoryHit(record: $0, score: Vector.cosineSimilarity(queryVector, $0.vector)) }
            .filter { $0.score >= threshold }
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .map { $0 }
    }

    static func archive(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }
    static func unarchive(_ d: Data) -> [Float] {
        let count = d.count / MemoryLayout<Float>.stride
        return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(count)) }
    }
}
```

- [ ] **Step 4: Run → PASS** — framework test command → `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**
```bash
git add Targets/FoundationChatKit
git commit -m "feat(kit): MemoryStore (index, backfill, snapshot, cosine search)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone P — MemorySearchTool

### Task P1: `MemorySearchTool`

**Files:**
- Create: `Targets/FoundationChatKit/Sources/Tools/MemorySearchTool.swift`
- Test: `Targets/FoundationChatKit/Tests/MemorySearchToolTests.swift`

- [ ] **Step 1: Write the failing test** — `MemorySearchToolTests.swift`:
```swift
import Testing
import Foundation
@testable import FoundationChatKit

@MainActor
struct MemorySearchToolTests {
    private func snapshot() -> [MemoryRecord] {
        let e = MockEmbedder()
        return [
            MemoryRecord(messageID: UUID(), conversationID: UUID(), conversationTitle: "Trip",
                         role: .user, text: "trip to paris", vector: e.embed("trip to paris")!),
            MemoryRecord(messageID: UUID(), conversationID: UUID(), conversationTitle: "Code",
                         role: .assistant, text: "debugging swift code", vector: e.embed("debugging swift code")!),
        ]
    }
    @Test func returnsRankedSnippet() async throws {
        let tool = MemorySearchTool(embedder: MockEmbedder(), snapshot: snapshot())
        let result = try await tool.call(arguments: .init(query: "paris trip"))
        #expect(result.contains("trip to paris"))
        #expect(result.contains("Trip"))
    }
    @Test func noMatchReturnsFallback() async throws {
        let tool = MemorySearchTool(embedder: MockEmbedder(), snapshot: snapshot())
        let result = try await tool.call(arguments: .init(query: "music dog weather"))
        #expect(result == "No relevant earlier context found.")
    }
    @Test func excludedNotReturned() async throws {
        let snap = snapshot()
        let tool = MemorySearchTool(embedder: MockEmbedder(), snapshot: snap,
                                    excludedIDs: Set([snap[0].messageID]))
        let result = try await tool.call(arguments: .init(query: "paris trip"))
        #expect(!result.contains("trip to paris"))
    }
}
```

- [ ] **Step 2: Run → FAIL** — `tuist generate --no-open`, framework test command. Expected: `MemorySearchTool` not found.

- [ ] **Step 3: Implement `MemorySearchTool.swift`**:
```swift
import Foundation
import FoundationModels

/// A tool the model calls to recall relevant context from past conversations. Pure and Sendable:
/// it searches an immutable snapshot handed in at construction, so it needs no actor hop.
public struct MemorySearchTool: Tool {
    public let name = "searchMemory"
    public let description = "Search the user's past conversations for context relevant to the query."

    @Generable
    public struct Arguments {
        @Guide(description: "What to recall, as a short search query")
        public var query: String
        public init(query: String) { self.query = query }
    }

    private let embedder: any TextEmbedder
    private let snapshot: [MemoryRecord]
    private let excludedIDs: Set<UUID>

    public init(embedder: any TextEmbedder, snapshot: [MemoryRecord], excludedIDs: Set<UUID> = []) {
        self.embedder = embedder
        self.snapshot = snapshot
        self.excludedIDs = excludedIDs
    }

    public func call(arguments: Arguments) async throws -> String {
        guard let queryVector = embedder.embed(arguments.query) else {
            return "No relevant earlier context found."
        }
        let hits = MemoryStore.search(snapshot, queryVector: queryVector, excludingMessageIDs: excludedIDs)
        guard !hits.isEmpty else { return "No relevant earlier context found." }
        return hits.map { hit in
            let who = hit.record.role == .user ? "You" : "Assistant"
            return "From '\(hit.record.conversationTitle)' — \(who): \(hit.record.text)"
        }.joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Run → PASS** — framework test command → `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**
```bash
git add Targets/FoundationChatKit
git commit -m "feat(kit): MemorySearchTool (semantic recall over a session snapshot)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone Q — Coordinator + app wiring

### Task Q1: Wire memory into `ChatCoordinator` + `EmberApp`

**Files:**
- Modify: `Targets/FoundationChatKit/Sources/App/ChatCoordinator.swift`
- Modify: `Targets/Ember/Sources/EmberApp.swift`
- Test: `Targets/FoundationChatKit/Tests/ChatCoordinatorTests.swift` (extend)

- [ ] **Step 1: Write the failing tests** (append inside `ChatCoordinatorTests`; add a memory-aware helper alongside the existing `make()`):
```swift
    @MainActor
    private func makeWithMemory() throws -> (ChatCoordinator, MockModelProvider, MemoryStore) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Conversation.self, Message.self, configurations: config)
        let context = ModelContext(container)
        let store = ConversationStore(context: context)
        let memory = MemoryStore(context: context, embedder: MockEmbedder())
        let provider = MockModelProvider()
        let coord = ChatCoordinator(provider: provider, store: store,
                                    settings: GenerationSettings(instructions: "sys"),
                                    memory: memory, modelVersionTag: "v1",
                                    now: { Date(timeIntervalSince1970: 0) })
        return (coord, provider, memory)
    }

    @Test func registersMemorySearchTool() throws {
        let (coord, provider, _) = try makeWithMemory()
        coord.newConversation()
        #expect(provider.recordedTools.contains { $0.name == "searchMemory" })
    }
    @Test func sendIndexesMessages() async throws {
        let (coord, provider, memory) = try makeWithMemory()
        provider.session.scriptedSnapshots = ["ok"]
        coord.newConversation()
        await coord.send("trip to paris")
        #expect(memory.snapshot().contains { $0.text == "trip to paris" })
    }
```
> Note: the existing `make()` helper and its tests are unchanged (they pass no `memory`, so `searchMemory` isn't registered there — only the 3 base tools).

- [ ] **Step 2: Run → FAIL** — `tuist generate --no-open`, framework test command. Expected: `ChatCoordinator.init` has no `memory:` parameter.

- [ ] **Step 3a: `ChatCoordinator`** — add a stored property after `now`:
```swift
    private let memory: MemoryStore?
```
Add a `memory` parameter to `init` (place it after `modelVersionTag` default, before `now`):
```swift
        modelVersionTag: String = ProcessInfo.processInfo.operatingSystemVersionString,
        memory: MemoryStore? = nil,
        now: @escaping () -> Date = Date.init
```
In the init body, assign it and backfill (after `self.availability = provider.availability`, before `reload()`):
```swift
        self.memory = memory
        memory?.backfill()
```
In `send(_:)`, after the final `reload()`, index the conversation's messages:
```swift
        reload()
        if let memory {
            for message in convo.orderedMessages { memory.index(message) }
        }
```
In `makeEngine(for:)`, build the tool list with the memory tool when memory is present. Replace the `tools: Toolbox.defaultTools(),` argument by first computing the tools above the `return`:
```swift
        var tools = Toolbox.defaultTools()
        if let memory {
            let excluded = Set(convo.orderedMessages.map(\.id))
            tools.append(MemorySearchTool(embedder: memory.embedder,
                                          snapshot: memory.snapshot(),
                                          excludedIDs: excluded))
        }
        return ConversationEngine(
            provider: provider,
            settings: settings,
            restoring: canUseTranscript ? convo.transcriptData : nil,
            restoringEntries: canUseTranscript ? nil : store.contextEntries(for: convo),
            tools: tools,
            persistence: persistence,
            now: now
        )
```

- [ ] **Step 3b: `EmberApp`** — share one `ModelContext` between the two stores and pass the memory store. Replace the body of `init()` after the `container` is created:
```swift
        let context = ModelContext(container)
        let store = ConversationStore(context: context)
        let memory = MemoryStore(context: context, embedder: NLTextEmbedder())
        _coordinator = State(initialValue: ChatCoordinator(provider: FoundationModelProvider(),
                                                           store: store, memory: memory))
```

- [ ] **Step 4: Run → PASS + build both apps** — framework test command → `** TEST SUCCEEDED **`; macOS + iOS app builds → `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**
```bash
git add Targets/FoundationChatKit Targets/Ember
git commit -m "feat: wire conversation memory into coordinator + app (searchMemory tool)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone R — Run verification + finalize

### Task R1: Run, exercise memory recall, finalize

- [ ] **Step 1: Full test + both builds**
```bash
xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -5
xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=macOS' build 2>&1 | tail -3
xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -3
```
All three must succeed.

- [ ] **Step 2: Run on the iOS simulator + exercise recall**
```bash
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null || true
xcodebuild -workspace Ember.xcworkspace -scheme Ember -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/ember-ios-p5 build 2>&1 | tail -3
APP=$(find /tmp/ember-ios-p5/Build/Products -name "Ember.app" -maxdepth 3 | head -1)
xcrun simctl install booted "$APP"; xcrun simctl launch booted dev.iosunpi.ember; sleep 6
xcrun simctl io booted screenshot /tmp/ember-p5-ios.png
```
Drive the UI (xcodebuildmcp `describe_ui`/`tap`/`type_text`/`screenshot`): in one chat, state a memorable fact (e.g. "Remember my favorite city is Lisbon."). Start a **new** chat and ask "What's my favorite city?". Best-effort (model permitting), confirm the model calls `searchMemory` (a `TOOL CALL searchMemory({...})` + `TOOL OUTPUT` appear in the Context inspector) and answers "Lisbon". Record observed behavior + screenshot. If the model doesn't call the tool, note it (tool selection is model-dependent) — the unit tests + build are the guaranteed verification.

- [ ] **Step 3: Final commit + tag**
```bash
git commit --allow-empty -m "chore: Plan 5 complete — conversation-memory RAG

On-device long-term memory: NLEmbedding sentence vectors behind a TextEmbedder
seam; MemoryStore (index-on-save + backfill + cosine top-k); a searchMemory tool
the model calls to recall across conversations, surfaced in the inspector. One
additive schema field (Message.embedding). No network added.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git tag plan-5-rag-complete
```

- [ ] **Step 4: PR** — push and open the PR (base `plan-4-hardening` while #3/#4 are unmerged; retarget to `main` after they merge):
```bash
git push -u origin plan-5-rag
gh pr create --base plan-4-hardening --head plan-5-rag --title "Plan 5 — Conversation-memory RAG" --body "On-device long-term memory via a searchMemory tool over NLEmbedding semantic search (MemoryStore + cosine top-k); one additive schema field (Message.embedding). All FoundationChatKit logic TDD; app build-verified; verified on the iOS 26 sim. Stacked on #4."
```

---

## Self-review (author check against spec)

**Spec coverage (spec §):**
- §2 NLEmbedding (not contextual) → N2 (`NLTextEmbedder`). ✓
- §3 `TextEmbedder` seam + mock → N2; `MemoryRecord`/`MemoryHit` → O1; `MemoryStore` index/backfill/snapshot/search → O2; `MemorySearchTool` (pure, Sendable, snapshot) → P1; coordinator wiring (backfill, index-on-send, register tool per open) → Q1. ✓
- §4 `Message.embedding` additive field → O1. ✓
- §5 retrieval (cosine, exclude, threshold, topK, format) → O2 (`search`) + P1 (`call`). ✓
- §6 surfacing reuses Plan 3 (tool-call/output rows + `Tool: searchMemory` budget line) → automatic; no UI task needed. ✓
- §7 testing → VectorTests, MockEmbedderTests, MemoryStoreTests, MemorySearchToolTests, ChatCoordinatorTests (extended). ✓
- §1 no network/entitlement → no `Project.swift`/entitlement edits. ✓

**Placeholder scan:** none. Every code step shows full code.

**Type consistency:** `TextEmbedder.embed(_:) -> [Float]?` identical across protocol (N2), `NLTextEmbedder` (N2), `MockEmbedder` (N2), `MemoryStore.index` (O2), `MemorySearchTool` (P1). `MemoryRecord`/`MemoryHit` defined O1, consumed O2 + P1. `MemoryStore.search(_:queryVector:topK:threshold:excludingMessageIDs:)` defined O2, called by P1. `MemorySearchTool.init(embedder:snapshot:excludedIDs:)` identical in P1 tests, P1 impl, and Q1 (`makeEngine`). `ChatCoordinator.init(...memory:...)` identical in Q1 impl, `makeWithMemory` (Q1), and `EmberApp` (Q1). `MemoryStore.init(context:embedder:)` identical across O2 tests, Q1 helper, and `EmberApp`.

**Ordering:** N (pure + seam) → O (schema + store) → P (tool) → Q (wiring, both builds) → R (run). Each task ends green/committed; defaulted `memory:` keeps existing call sites compiling until Q wires the app.
