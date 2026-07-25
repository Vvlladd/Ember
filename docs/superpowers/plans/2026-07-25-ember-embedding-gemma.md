# EmbeddingGemma Memory Embedder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace NLEmbedding with EmbeddingGemma-300m on Core ML behind the `TextEmbedder` seam — with role-aware embedding, embedder-versioned vectors, chunked migration, NLEmbedding fallback, and an eval gate proving the upgrade.

**Architecture:** The `TextEmbedder` protocol gains an `identity` and a query/document `role`. Vectors persist with an `embedderID` tag; cosine comparison only ever happens within one embedder's vector space; mismatched rows degrade to lexical-only until a chunked background backfill re-embeds them. A new `GemmaTextEmbedder` loads a bundled Core ML conversion of EmbeddingGemma asynchronously (embeds return nil until ready — the existing nil-tolerance + backfill makes this graceful), tokenizes via swift-transformers, applies EmbeddingGemma's task prefixes, and truncates the 768-dim output to 256 dims (Matryoshka) + re-normalizes. The app falls back to `NLTextEmbedder` when the model resource is absent.

**Tech Stack:** Swift Testing, Tuist, Core ML, swift-transformers (`Tokenizers` — the ONE new SPM dependency), SwiftData lightweight migration, python coremltools (dev-only conversion script).

**Spec:** `docs/superpowers/specs/2026-07-25-ember-gemma-embedding-design.md` — read it first.

## Global Constraints

- Branch: `feat/embedding-gemma` off `main`; one PR for the whole plan.
- **Run `tuist generate --no-open` after ANY file add/delete** before xcodebuild.
- Test gate after every task: `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`. SourceKit squiggles are noise; xcodebuild is ground truth.
- App target must compile at every commit: `xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=macOS' build 2>&1 | tail -10`.
- No network at runtime. Model weights are NEVER committed to git (`Targets/Ember/Resources/Models/` is gitignored). The build and all non-gated tests must pass WITHOUT the weights present.
- Output dimension: **256**. Gemma document prefix: `"title: none | text: "`. Query prefix: `"task: search result | query: "`. (Verify against the EmbeddingGemma model card during Task 0; the model card is authoritative — if it differs, fix the constants in ONE place, `GemmaEmbeddingFormat`.)
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

## File Structure

```
scripts/fetch_embeddinggemma.sh                 NEW  dev-only: HF download + conversion driver
scripts/convert_embeddinggemma.py               NEW  dev-only: HF → .mlpackage + tokenizer files + parity check
Targets/FoundationChatKit/Sources/Memory/
  TextEmbedder.swift                            MOD  protocol v2: EmbeddingRole, EmbedderIdentity, role-aware embed
  GemmaEmbeddingFormat.swift                    NEW  pure: prompt prefixes + Matryoshka truncate/normalize
  GemmaTextEmbedder.swift                       NEW  Core ML + tokenizer embedder (async load, sync embed)
  MemoryStore.swift                             MOD  embedderID tagging, space-gated snapshot, chunked backfill
Targets/FoundationChatKit/Sources/Persistence/
  Message.swift, MemoryNote.swift               MOD  additive `embedderID: String?`
Targets/FoundationChatKit/Sources/App/ChatCoordinator.swift  MOD  retriever role .query; backfill stays at init
Targets/FoundationChatKit/Sources/Tools/MemorySearchTool.swift MOD  role .query
Targets/Ember/Sources/EmberApp.swift            MOD  embedder factory with fallback
Targets/FoundationChatKit/Tests/
  MockEmbedder.swift                            MOD  identity + role param (+ legacy sugar overload)
  RoleRecordingEmbedder.swift                   NEW  test helper: records roles passed to embed
  GemmaEmbeddingFormatTests.swift               NEW
  MemoryStoreVersioningTests.swift              NEW
  BackfillMigrationTests.swift                  NEW
  RetrievalEvalHarness.swift + RetrievalEvalTests.swift  NEW  fixtures, recall@k, model-gated NL-vs-Gemma
Tuist/Package.swift                             NEW  swift-transformers dependency
Project.swift                                   MOD  external dep + optional Models resource glob
```

---

### Task 0: Branch, model acquisition scripts, gitignore

Dev-only tooling; no app code. Later tasks 1–3 do NOT depend on the model existing; Tasks 4–6 need the files this produces on the dev machine.

**Files:**
- Create: `scripts/fetch_embeddinggemma.sh`, `scripts/convert_embeddinggemma.py`
- Modify: `.gitignore`

**Interfaces:**
- Produces on disk (gitignored): `Targets/Ember/Resources/Models/EmbeddingGemma.mlpackage` and `Targets/Ember/Resources/Models/tokenizer/` (tokenizer.json + tokenizer_config.json). Tasks 4–6 consume these paths verbatim.

- [ ] **Step 1: Branch**

```bash
git checkout -b feat/embedding-gemma
```

- [ ] **Step 2: gitignore the weights**

Append to `.gitignore`:

```
Targets/Ember/Resources/Models/
```

- [ ] **Step 3: Write the conversion script**

`scripts/convert_embeddinggemma.py` (dev machine only; requires `pip install sentence-transformers coremltools torch numpy`):

```python
#!/usr/bin/env python3
"""Convert google/embeddinggemma-300m to a Core ML .mlpackage + tokenizer files.

Output: Targets/Ember/Resources/Models/EmbeddingGemma.mlpackage
        Targets/Ember/Resources/Models/tokenizer/{tokenizer.json,tokenizer_config.json}
Ends with a parity check: CoreML output vs sentence-transformers output, cosine must be > 0.99.
VERIFY against the model card (https://ai.google.dev/gemma/docs/embeddinggemma) that the
prompt prefixes match GemmaEmbeddingFormat.swift before shipping.
"""
import numpy as np, shutil, torch, coremltools as ct
from pathlib import Path
from sentence_transformers import SentenceTransformer

MODEL_ID = "google/embeddinggemma-300m"
SEQ_LEN = 256          # memory snippets are <=240 chars (~64 tokens); 256 is generous headroom
OUT = Path("Targets/Ember/Resources/Models")

st = SentenceTransformer(MODEL_ID)
st.eval()

class Pooled(torch.nn.Module):
    """input_ids/attention_mask -> mean-pooled, L2-normalized 768-dim sentence vector."""
    def __init__(self, st_model):
        super().__init__()
        self.st = st_model
    def forward(self, input_ids, attention_mask):
        out = self.st({"input_ids": input_ids, "attention_mask": attention_mask})
        return out["sentence_embedding"]

wrapper = Pooled(st)
ids = torch.zeros((1, SEQ_LEN), dtype=torch.int32)
mask = torch.zeros((1, SEQ_LEN), dtype=torch.int32)
traced = torch.jit.trace(wrapper, (ids, mask))

mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input_ids", shape=(1, SEQ_LEN), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, SEQ_LEN), dtype=np.int32)],
    outputs=[ct.TensorType(name="embedding")],
    minimum_deployment_target=ct.target.iOS18,
    compute_precision=ct.precision.FLOAT16,
)
OUT.mkdir(parents=True, exist_ok=True)
mlmodel.save(str(OUT / "EmbeddingGemma.mlpackage"))

tok_dir = OUT / "tokenizer"
tok_dir.mkdir(exist_ok=True)
src = Path(st.tokenizer.name_or_path) if Path(st.tokenizer.name_or_path).is_dir() else None
st.tokenizer.save_pretrained(str(tok_dir))

# Parity check
text = "title: none | text: I'm planning a trip to Lisbon in September"
ref = st.encode([text], convert_to_numpy=True)[0]
enc = st.tokenizer(text, padding="max_length", max_length=SEQ_LEN, truncation=True, return_tensors="np")
pred = ct.models.MLModel(str(OUT / "EmbeddingGemma.mlpackage")).predict({
    "input_ids": enc["input_ids"].astype(np.int32),
    "attention_mask": enc["attention_mask"].astype(np.int32)})["embedding"][0]
cos = float(np.dot(ref, pred) / (np.linalg.norm(ref) * np.linalg.norm(pred)))
print(f"parity cosine = {cos:.4f}")
assert cos > 0.99, "Core ML output diverges from sentence-transformers — conversion is broken"
print("OK")
```

- [ ] **Step 4: Write the fetch driver**

`scripts/fetch_embeddinggemma.sh`:

```bash
#!/usr/bin/env bash
# Dev-only: accepts the Gemma license on HF once (huggingface-cli login), then converts.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/convert_embeddinggemma.py
echo "Model + tokenizer in Targets/Ember/Resources/Models/ (gitignored — never commit)"
```

`chmod +x scripts/fetch_embeddinggemma.sh`

- [ ] **Step 5: Run it and verify parity** (needs HF login + Gemma license acceptance)

Run: `./scripts/fetch_embeddinggemma.sh`
Expected: `parity cosine = 0.99xx` then `OK`. If the trace/convert fails on this coremltools version, fix the wrapper here — the Swift side only depends on the input/output names and shapes above. Also confirm the model card's prompt prefixes match the Global Constraints; if not, update `GemmaEmbeddingFormat` (Task 4) and this script's parity text together.

- [ ] **Step 6: Commit** (scripts + gitignore only — verify `git status` shows no Models/)

```bash
git add scripts/ .gitignore
git commit -m "chore(embedding): EmbeddingGemma fetch+convert scripts (weights gitignored)"
```

---

### Task 1: TextEmbedder v2 — role + identity

**Files:**
- Modify: `Targets/FoundationChatKit/Sources/Memory/TextEmbedder.swift`
- Modify: `Targets/FoundationChatKit/Sources/Memory/MemoryStore.swift` (call sites only), `Targets/FoundationChatKit/Sources/App/ChatCoordinator.swift:214`, `Targets/FoundationChatKit/Sources/Tools/MemorySearchTool.swift:28`
- Modify: `Targets/FoundationChatKit/Tests/MockEmbedder.swift`
- Create: `Targets/FoundationChatKit/Tests/RoleRecordingEmbedder.swift`, `Targets/FoundationChatKit/Tests/TextEmbedderRoleTests.swift`

**Interfaces:**
- Produces: `enum EmbeddingRole { case query, document }`; `struct EmbedderIdentity: Sendable, Equatable { let id: String; let dimension: Int; static let legacyNLEnglish = EmbedderIdentity(id: "nl-sentence-en", dimension: 512) }`; protocol `TextEmbedder { var identity: EmbedderIdentity { get }; func embed(_ text: String, role: EmbeddingRole) -> [Float]? }`. Every later task relies on these exact names.
- Role mapping (spec §1): `MemoryStore.index`/`saveNote`/`saveNoteIfNovel` candidate → `.document`; ChatCoordinator retriever + `MemorySearchTool` → `.query`.

- [ ] **Step 1: Write the failing tests**

`Targets/FoundationChatKit/Tests/RoleRecordingEmbedder.swift`:

```swift
import Foundation
@testable import FoundationChatKit

/// Wraps MockEmbedder and records every role passed to `embed` (lock-guarded — Sendable).
final class RoleRecordingEmbedder: TextEmbedder, @unchecked Sendable {
    private let lock = NSLock()
    private var _roles: [EmbeddingRole] = []
    private let base = MockEmbedder()
    var identity: EmbedderIdentity { base.identity }
    var recordedRoles: [EmbeddingRole] { lock.lock(); defer { lock.unlock() }; return _roles }
    func embed(_ text: String, role: EmbeddingRole) -> [Float]? {
        lock.lock(); _roles.append(role); lock.unlock()
        return base.embed(text, role: role)
    }
}
```

`Targets/FoundationChatKit/Tests/TextEmbedderRoleTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import FoundationChatKit

@MainActor
struct TextEmbedderRoleTests {
    private func makeStore(_ embedder: any TextEmbedder) throws -> MemoryStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Conversation.self, Message.self, MemoryNote.self,
                                           configurations: config)
        return MemoryStore(context: ModelContext(container), embedder: embedder)
    }

    @Test func indexEmbedsAsDocument() throws {
        let recorder = RoleRecordingEmbedder()
        let store = try makeStore(recorder)
        store.index(Message(role: .user, text: "trip to paris", createdAt: Date()))
        #expect(recorder.recordedRoles == [.document])
    }

    @Test func saveNoteEmbedsAsDocument() throws {
        let recorder = RoleRecordingEmbedder()
        let store = try makeStore(recorder)
        store.saveNote("likes swift code")
        #expect(recorder.recordedRoles == [.document])
    }

    @Test func nlEmbedderHasLegacyIdentityForEnglish() {
        #expect(NLTextEmbedder().identity.id == EmbedderIdentity.legacyNLEnglish.id)
    }

    @Test func mockIdentityIsStable() {
        #expect(MockEmbedder().identity == EmbedderIdentity(id: "mock-bag-of-words", dimension: 8))
    }
}
```

- [ ] **Step 2: Regenerate + run to verify it fails**

Run: `tuist generate --no-open && xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40`
Expected: compile FAILURE — `EmbeddingRole`/`EmbedderIdentity`/`identity` don't exist.

- [ ] **Step 3: Implement the seam**

Replace the protocol section of `TextEmbedder.swift` (keep the file header + `NLTextEmbedder` class, edited as shown):

```swift
/// Which side of retrieval a text is embedded for. EmbeddingGemma is trained with different task
/// prefixes for queries vs stored documents; NLEmbedding ignores the distinction.
public enum EmbeddingRole: Sendable { case query, document }

/// Stable identity of an embedder's vector space. Vectors from different identities are never
/// cosine-compared (see MemoryStore) — a swap changes the id and triggers re-embedding.
public struct EmbedderIdentity: Sendable, Equatable {
    public let id: String
    public let dimension: Int
    public init(id: String, dimension: Int) { self.id = id; self.dimension = dimension }
    /// Vectors persisted before versioning existed (embedderID == nil) are NLEmbedding English.
    public static let legacyNLEnglish = EmbedderIdentity(id: "nl-sentence-en", dimension: 512)
}

/// Produces a dense vector for a piece of text. Mock-able so memory logic is testable off-device.
public protocol TextEmbedder: Sendable {
    var identity: EmbedderIdentity { get }
    func embed(_ text: String, role: EmbeddingRole) -> [Float]?
}
```

In `NLTextEmbedder`: add

```swift
    public var identity: EmbedderIdentity {
        language == .english
            ? .legacyNLEnglish
            : EmbedderIdentity(id: "nl-sentence-\(language.rawValue)", dimension: embedding?.dimension ?? 0)
    }
```

and change the method signature to `public func embed(_ text: String, role: EmbeddingRole) -> [Float]?` (body unchanged — the role is deliberately unused).

Call-site updates (exact lines):
- `MemoryStore.swift:25` → `embedder.embed(message.text, role: .document)`
- `MemoryStore.swift:41` → `embedder.embed(trimmed, role: .document)`
- `MemoryStore.swift:83` → `embedder.embed(trimmed, role: .document)`
- `ChatCoordinator.swift:214` → `embedder.embed(query, role: .query)`
- `MemorySearchTool.swift:28` → `embedder.embed(arguments.query, role: .query)`

`MockEmbedder.swift` — conform + keep every existing test call compiling via a test-only sugar overload:

```swift
struct MockEmbedder: TextEmbedder {
    let vocabulary: [String]
    let identity = EmbedderIdentity(id: "mock-bag-of-words", dimension: 8)
    init(vocabulary: [String] = ["swift", "trip", "paris", "budget", "weather", "dog", "music", "code"]) {
        self.vocabulary = vocabulary
    }
    func embed(_ text: String, role: EmbeddingRole) -> [Float]? {
        let words = Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        let v = vocabulary.map { words.contains($0) ? Float(1) : Float(0) }
        return v.allSatisfy { $0 == 0 } ? nil : v
    }
    /// Test sugar so pre-existing `embed("…")` call sites keep compiling; production code has no
    /// role-less overload on purpose (every real call site must state its role).
    func embed(_ text: String) -> [Float]? { embed(text, role: .document) }
}
```

- [ ] **Step 4: Run tests to verify green + app builds**

Run: `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` then `xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=macOS' build 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **` (224 existing + 4 new) and `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Targets/
git commit -m "feat(memory): role-aware TextEmbedder with EmbedderIdentity"
```

---

### Task 2: embedderID persistence + space-gated snapshot

**Files:**
- Modify: `Targets/FoundationChatKit/Sources/Persistence/Message.swift`, `Targets/FoundationChatKit/Sources/Persistence/MemoryNote.swift`
- Modify: `Targets/FoundationChatKit/Sources/Memory/MemoryStore.swift`
- Create: `Targets/FoundationChatKit/Tests/MemoryStoreVersioningTests.swift`

**Interfaces:**
- Consumes: `EmbedderIdentity.legacyNLEnglish`, `embedder.identity` (Task 1).
- Produces: `Message.embedderID: String?`, `MemoryNote.embedderID: String?` (additive, nil = legacy); MemoryStore behavior: writes tag `embedderID`; `snapshot()` returns `[]` vector for rows whose effective embedderID ≠ active; `index` re-embeds stale rows. Task 3's backfill and Task 6's eval rely on exactly this gating.

- [ ] **Step 1: Write the failing tests**

`Targets/FoundationChatKit/Tests/MemoryStoreVersioningTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import FoundationChatKit

/// A second vector space with a DIFFERENT identity — same bag-of-words math, different id.
struct OtherSpaceEmbedder: TextEmbedder {
    let identity = EmbedderIdentity(id: "other-space", dimension: 8)
    private let base = MockEmbedder()
    func embed(_ text: String, role: EmbeddingRole) -> [Float]? { base.embed(text, role: role) }
}

@MainActor
struct MemoryStoreVersioningTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Conversation.self, Message.self, MemoryNote.self,
                                           configurations: config)
        return ModelContext(container)
    }

    @Test func writesTagTheActiveEmbedderID() throws {
        let context = try makeContext()
        let store = MemoryStore(context: context, embedder: MockEmbedder())
        let message = Message(role: .user, text: "trip to paris", createdAt: Date())
        context.insert(message)
        store.index(message)
        #expect(message.embedderID == "mock-bag-of-words")
        store.saveNote("likes swift")
        let note = try #require(try context.fetch(FetchDescriptor<MemoryNote>()).first)
        #expect(note.embedderID == "mock-bag-of-words")
    }

    @Test func mismatchedSpaceVectorIsExcludedFromCosine() throws {
        let context = try makeContext()
        // Written in one space…
        MemoryStore(context: context, embedder: MockEmbedder()).saveNote("trip to paris")
        // …read under another: vector must be treated as absent (empty), not compared.
        let store = MemoryStore(context: context, embedder: OtherSpaceEmbedder())
        let record = try #require(store.snapshot().first)
        #expect(record.vector.isEmpty)
    }

    @Test func matchingSpaceVectorSurvivesSnapshot() throws {
        let context = try makeContext()
        MemoryStore(context: context, embedder: MockEmbedder()).saveNote("trip to paris")
        let store = MemoryStore(context: context, embedder: MockEmbedder())
        let record = try #require(store.snapshot().first)
        #expect(!record.vector.isEmpty)
    }

    @Test func nilEmbedderIDCountsAsLegacyNL() throws {
        let context = try makeContext()
        // Simulate a pre-versioning row: embedding present, embedderID nil.
        let legacy = MemoryNote(text: "trip to paris", createdAt: Date(),
                                embedding: MemoryStore.archive([1, 0, 0, 0, 0, 0, 0, 0]))
        context.insert(legacy)
        try context.save()
        // Under an embedder claiming the legacy identity, the vector is live…
        struct LegacyClaimer: TextEmbedder {
            let identity = EmbedderIdentity.legacyNLEnglish
            func embed(_ text: String, role: EmbeddingRole) -> [Float]? { nil }
        }
        let nlStore = MemoryStore(context: context, embedder: LegacyClaimer())
        #expect(!(try #require(nlStore.snapshot().first)).vector.isEmpty)
        // …under any other embedder it is dead.
        let gemmaStore = MemoryStore(context: context, embedder: MockEmbedder())
        #expect((try #require(gemmaStore.snapshot().first)).vector.isEmpty)
    }

    @Test func indexReembedsStaleMessage() throws {
        let context = try makeContext()
        let message = Message(role: .user, text: "trip to paris", createdAt: Date())
        context.insert(message)
        MemoryStore(context: context, embedder: OtherSpaceEmbedder()).index(message)
        #expect(message.embedderID == "other-space")
        MemoryStore(context: context, embedder: MockEmbedder()).index(message)  // stale → re-embed
        #expect(message.embedderID == "mock-bag-of-words")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `tuist generate --no-open && xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40`
Expected: compile FAILURE — `embedderID` doesn't exist.

- [ ] **Step 3: Implement**

`Message.swift` — add `public var embedderID: String?` after `embedding`, and `embedderID: String? = nil` as the last init parameter (assign in body). Same for `MemoryNote.swift`. Additive optionals = SwiftData lightweight migration; no schema version dance needed.

`MemoryStore.swift`:

```swift
    /// The row's effective vector space: rows written before versioning are NLEmbedding English.
    private func effectiveEmbedderID(_ rowID: String?) -> String {
        rowID ?? EmbedderIdentity.legacyNLEnglish.id
    }

    /// A stored vector participates in cosine only within the ACTIVE embedder's space; a stale
    /// vector behaves exactly like "not embedded" (empty → cosine 0, lexical still applies).
    private func liveVector(_ data: Data?, rowEmbedderID: String?) -> [Float] {
        guard let data, effectiveEmbedderID(rowEmbedderID) == embedder.identity.id else { return [] }
        return Self.unarchive(data)
    }
```

- `index(_:)` — re-embed stale rows and tag:

```swift
    public func index(_ message: Message) {
        guard message.role != .systemNotice else { return }
        let isCurrent = message.embedding != nil
            && effectiveEmbedderID(message.embedderID) == embedder.identity.id
        guard !isCurrent else { return }
        guard let vector = embedder.embed(message.text, role: .document) else { return }
        message.embedding = Self.archive(vector)
        message.embedderID = embedder.identity.id
        try? context.save()
        cachedSnapshot = nil  // a vector was written — invalidate the cache
    }
```

- `saveNote(_:)` — pass `embedderID: vector != nil ? embedder.identity.id : nil` into the `MemoryNote` init (only tag when a vector was actually written).
- `snapshot()` — message records: replace `vector: Self.unarchive(data)` with `vector: liveVector(data, rowEmbedderID: message.embedderID)` and drop the `guard let data` in favor of `guard message.embedding != nil || true` — keep the existing filter (`compactMap` returning nil for rows with `embedding == nil`) unchanged, only the unarchive line changes. Note records: `vector: liveVector(note.embedding, rowEmbedderID: note.embedderID)`.
- `saveNoteIfNovel` needs no change: stale notes now have empty vectors and the cosine loop already skips `note.vector.isEmpty`.

- [ ] **Step 4: Run tests + app build**

Run: both xcodebuild commands from Global Constraints.
Expected: `** TEST SUCCEEDED **`, `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Targets/
git commit -m "feat(memory): embedder-versioned vectors — spaces never cross-compared"
```

---

### Task 3: Chunked migration backfill

**Files:**
- Modify: `Targets/FoundationChatKit/Sources/Memory/MemoryStore.swift` (`backfill`)
- Create: `Targets/FoundationChatKit/Tests/BackfillMigrationTests.swift`
- Verify (no change needed): `ChatCoordinator.swift:48` already calls `memory?.backfill()` at init — with the chunked signature's default it now migrates one chunk per launch.

**Interfaces:**
- Consumes: `effectiveEmbedderID`/tagging semantics (Task 2).
- Produces: `@discardableResult public func backfill(chunkSize: Int = 50) -> Int` — re-embeds up to `chunkSize` stale/missing rows (Messages oldest-first, then MemoryNotes), returns how many it migrated. Idempotent; safe to call every launch.

- [ ] **Step 1: Write the failing tests**

`Targets/FoundationChatKit/Tests/BackfillMigrationTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import FoundationChatKit

@MainActor
struct BackfillMigrationTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Conversation.self, Message.self, MemoryNote.self,
                                           configurations: config)
        return ModelContext(container)
    }

    /// Seed `count` messages embedded in the "other-space" identity.
    private func seedStale(_ context: ModelContext, count: Int) throws {
        let old = MemoryStore(context: context, embedder: OtherSpaceEmbedder())
        for i in 0..<count {
            let m = Message(role: .user, text: "trip \(i) to paris",
                            createdAt: Date(timeIntervalSince1970: Double(i)))
            context.insert(m)
            old.index(m)
        }
        try context.save()
    }

    @Test func backfillMigratesUpToChunkSize() throws {
        let context = try makeContext()
        try seedStale(context, count: 5)
        let store = MemoryStore(context: context, embedder: MockEmbedder())
        #expect(store.backfill(chunkSize: 3) == 3)
        let migrated = try context.fetch(FetchDescriptor<Message>())
            .filter { $0.embedderID == "mock-bag-of-words" }
        #expect(migrated.count == 3)
    }

    @Test func backfillIsIdempotentAndConverges() throws {
        let context = try makeContext()
        try seedStale(context, count: 5)
        let store = MemoryStore(context: context, embedder: MockEmbedder())
        #expect(store.backfill(chunkSize: 3) == 3)
        #expect(store.backfill(chunkSize: 3) == 2)   // remainder
        #expect(store.backfill(chunkSize: 3) == 0)   // converged — nothing left
    }

    @Test func backfillAlsoMigratesNotes() throws {
        let context = try makeContext()
        MemoryStore(context: context, embedder: OtherSpaceEmbedder()).saveNote("likes swift")
        let store = MemoryStore(context: context, embedder: MockEmbedder())
        #expect(store.backfill() == 1)
        let note = try #require(try context.fetch(FetchDescriptor<MemoryNote>()).first)
        #expect(note.embedderID == "mock-bag-of-words")
    }

    @Test func backfillStillEmbedsNeverEmbeddedRows() throws {
        let context = try makeContext()
        let m = Message(role: .user, text: "trip to paris", createdAt: Date())
        context.insert(m)
        try context.save()
        let store = MemoryStore(context: context, embedder: MockEmbedder())
        #expect(store.backfill() == 1)
        #expect(m.embedding != nil && m.embedderID == "mock-bag-of-words")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `tuist generate --no-open && xcodebuild ... test 2>&1 | tail -40` (full command from Global Constraints)
Expected: compile FAILURE — `backfill(chunkSize:)` doesn't exist / return type mismatch.

- [ ] **Step 3: Implement**

Replace `backfill()` in `MemoryStore.swift`:

```swift
    /// Chunked migration + legacy embedding pass. Re-embeds rows that are missing a vector OR whose
    /// vector belongs to a different embedder's space — up to `chunkSize` rows per call (oldest
    /// first, messages then notes), so a large store converges over a few launches without ever
    /// blocking startup. Idempotent: migrated rows are tagged and skipped on the next pass.
    @discardableResult
    public func backfill(chunkSize: Int = 50) -> Int {
        let activeID = embedder.identity.id
        var migrated = 0

        func isStale(_ embedding: Data?, _ rowID: String?) -> Bool {
            embedding == nil || effectiveEmbedderID(rowID) != activeID
        }

        let messages = (try? context.fetch(
            FetchDescriptor<Message>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        for message in messages where migrated < chunkSize {
            guard message.role != .systemNotice, isStale(message.embedding, message.embedderID),
                  let v = embedder.embed(message.text, role: .document) else { continue }
            message.embedding = Self.archive(v)
            message.embedderID = activeID
            migrated += 1
        }

        let notes = (try? context.fetch(
            FetchDescriptor<MemoryNote>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        for note in notes where migrated < chunkSize {
            guard isStale(note.embedding, note.embedderID),
                  let v = embedder.embed(note.text, role: .document) else { continue }
            note.embedding = Self.archive(v)
            note.embedderID = activeID
            migrated += 1
        }

        if migrated > 0 {
            try? context.save()
            cachedSnapshot = nil
            EmberLog.memory.info("backfill: migrated \(migrated, privacy: .public) rows to \(activeID, privacy: .public)")
        }
        return migrated
    }
```

- [ ] **Step 4: Run tests + app build** — both commands, expect green. (Existing `backfill` tests keep passing: the never-embedded case is covered by `isStale`.)

- [ ] **Step 5: Commit**

```bash
git add Targets/
git commit -m "feat(memory): chunked embedder-migration backfill"
```

---

### Task 4: GemmaEmbeddingFormat + GemmaTextEmbedder + swift-transformers dependency

**Files:**
- Create: `Tuist/Package.swift`; Modify: `Project.swift`
- Create: `Targets/FoundationChatKit/Sources/Memory/GemmaEmbeddingFormat.swift`
- Create: `Targets/FoundationChatKit/Sources/Memory/GemmaTextEmbedder.swift`
- Create: `Targets/FoundationChatKit/Tests/GemmaEmbeddingFormatTests.swift`

**Interfaces:**
- Consumes: `TextEmbedder`/`EmbeddingRole`/`EmbedderIdentity` (Task 1); model/tokenizer file layout (Task 0).
- Produces: `enum GemmaEmbeddingFormat { static func prompt(_:role:) -> String; static func truncateAndNormalize(_:to:) -> [Float] }`; `final class GemmaTextEmbedder: TextEmbedder` with `init?(modelURL: URL, tokenizerDirectory: URL)` and `identity == EmbedderIdentity(id: "embeddinggemma-300m-256", dimension: 256)`. Task 5's factory and Task 6's eval use these exact names.

- [ ] **Step 1: Add the dependency**

`Tuist/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

#if TUIST
import ProjectDescription
let packageSettings = PackageSettings(productTypes: [:])
#endif

let package = Package(
    name: "EmberDependencies",
    dependencies: [
        // Tokenizer ONLY (Gemma SentencePiece). Pin exact; verify latest tag when executing.
        .package(url: "https://github.com/huggingface/swift-transformers", from: "0.1.15")
    ]
)
```

In `Project.swift`, FoundationChatKit target dependencies: `dependencies: [.external(name: "Tokenizers")]`. (If `tuist install` reports a different product name for the tokenizers module, use what it reports — check with `tuist graph` — and note it here.)

Run: `tuist install && tuist generate --no-open`
Expected: resolves + generates. Then the standard test command still passes (no source changes yet).

- [ ] **Step 2: Write the failing format tests** (pure logic — no model needed)

`Targets/FoundationChatKit/Tests/GemmaEmbeddingFormatTests.swift`:

```swift
import Foundation
import Testing
@testable import FoundationChatKit

struct GemmaEmbeddingFormatTests {
    @Test func documentPrompt() {
        #expect(GemmaEmbeddingFormat.prompt("I moved to Lisbon", role: .document)
                == "title: none | text: I moved to Lisbon")
    }

    @Test func queryPrompt() {
        #expect(GemmaEmbeddingFormat.prompt("where do I live", role: .query)
                == "task: search result | query: where do I live")
    }

    @Test func truncateKeepsPrefixAndRenormalizes() {
        let v: [Float] = [3, 4, 100, 100]           // untruncated norm dominated by the tail
        let out = GemmaEmbeddingFormat.truncateAndNormalize(v, to: 2)
        #expect(out.count == 2)
        #expect(abs(out[0] - 0.6) < 1e-5)           // 3/5
        #expect(abs(out[1] - 0.8) < 1e-5)           // 4/5
    }

    @Test func zeroVectorDoesNotDivideByZero() {
        #expect(GemmaEmbeddingFormat.truncateAndNormalize([0, 0, 0], to: 2) == [0, 0])
    }
}
```

Run test command → expected: compile FAILURE (`GemmaEmbeddingFormat` missing).

- [ ] **Step 3: Implement the pure format helper**

`Targets/FoundationChatKit/Sources/Memory/GemmaEmbeddingFormat.swift`:

```swift
import Foundation

/// EmbeddingGemma's task-prefix prompt format and Matryoshka output handling. Pure — unit-tested
/// without the model. The prefix strings come from the EmbeddingGemma model card; if the card
/// disagrees, THIS is the single place to fix (and re-run scripts/convert parity with the same text).
public enum GemmaEmbeddingFormat {
    public static func prompt(_ text: String, role: EmbeddingRole) -> String {
        switch role {
        case .document: "title: none | text: \(text)"
        case .query: "task: search result | query: \(text)"
        }
    }

    /// Matryoshka truncation: keep the first `dim` components, then re-normalize to unit length so
    /// cosine over truncated vectors stays calibrated. Zero vectors pass through untouched.
    public static func truncateAndNormalize(_ vector: [Float], to dim: Int) -> [Float] {
        let t = Array(vector.prefix(dim))
        let norm = (t.reduce(Float(0)) { $0 + $1 * $1 }).squareRoot()
        guard norm > 0 else { return t }
        return t.map { $0 / norm }
    }
}
```

Run tests → green.

- [ ] **Step 4: Implement `GemmaTextEmbedder`**

`Targets/FoundationChatKit/Sources/Memory/GemmaTextEmbedder.swift`:

```swift
import CoreML
import Foundation
import Tokenizers
import os

/// EmbeddingGemma-300m over Core ML. Resources load ASYNCHRONOUSLY after init; until they are
/// ready `embed` returns nil — callers already tolerate nil (rows stay unembedded) and the chunked
/// `backfill` re-embeds them on a later pass, so a slow first load degrades gracefully.
///
/// `@unchecked Sendable`: `resources` is written once by the loader task and only read afterwards,
/// always under `lock`.
public final class GemmaTextEmbedder: TextEmbedder, @unchecked Sendable {
    public let identity = EmbedderIdentity(id: "embeddinggemma-300m-256", dimension: 256)

    private struct Resources { let model: MLModel; let tokenizer: any Tokenizer }
    private let lock = NSLock()
    private var resources: Resources?
    private static let sequenceLength = 256   // must match scripts/convert_embeddinggemma.py SEQ_LEN

    /// Fails (returns nil) only when the files are visibly absent; load errors after that are
    /// logged and leave the embedder permanently returning nil (the app-level factory decides
    /// fallback at NEXT launch — within a run, nil-embeds are already the tolerated degraded mode).
    public init?(modelURL: URL, tokenizerDirectory: URL) {
        guard FileManager.default.fileExists(atPath: modelURL.path),
              FileManager.default.fileExists(atPath: tokenizerDirectory.path) else {
            EmberLog.embed.error("GemmaTextEmbedder: model or tokenizer missing — not constructing")
            return nil
        }
        Task.detached(priority: .utility) { [weak self] in
            do {
                let compiled = modelURL.pathExtension == "mlmodelc"
                    ? modelURL
                    : try await MLModel.compileModel(at: modelURL)
                let model = try MLModel(contentsOf: compiled)
                let tokenizer = try await AutoTokenizer.from(modelFolder: tokenizerDirectory)
                self?.install(Resources(model: model, tokenizer: tokenizer))
                EmberLog.embed.info("GemmaTextEmbedder ready (dim=256)")
            } catch {
                EmberLog.embed.error("GemmaTextEmbedder load failed: \(error, privacy: .public)")
            }
        }
    }

    private func install(_ r: Resources) { lock.lock(); resources = r; lock.unlock() }

    public func embed(_ text: String, role: EmbeddingRole) -> [Float]? {
        lock.lock(); let r = resources; lock.unlock()
        guard let r else { return nil }   // still loading (or load failed) — tolerated nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var ids = r.tokenizer.encode(text: GemmaEmbeddingFormat.prompt(trimmed, role: role))
        ids = Array(ids.prefix(Self.sequenceLength))
        do {
            let inputIDs = try MLMultiArray(shape: [1, NSNumber(value: Self.sequenceLength)], dataType: .int32)
            let mask = try MLMultiArray(shape: [1, NSNumber(value: Self.sequenceLength)], dataType: .int32)
            for i in 0..<Self.sequenceLength {
                inputIDs[i] = NSNumber(value: i < ids.count ? Int32(ids[i]) : 0)
                mask[i] = NSNumber(value: i < ids.count ? Int32(1) : 0)
            }
            let out = try r.model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: inputIDs),
                "attention_mask": MLFeatureValue(multiArray: mask),
            ]))
            guard let emb = out.featureValue(for: "embedding")?.multiArrayValue else {
                EmberLog.embed.error("GemmaTextEmbedder: no 'embedding' output")
                return nil
            }
            let full = (0..<emb.count).map { Float(truncating: emb[$0]) }
            return GemmaEmbeddingFormat.truncateAndNormalize(full, to: identity.dimension)
        } catch {
            EmberLog.embed.notice("GemmaTextEmbedder embed failed (len=\(trimmed.count, privacy: .public)): \(error, privacy: .public)")
            return nil
        }
    }
}
```

Verify-then-use while implementing: (a) `AutoTokenizer.from(modelFolder:)` is the swift-transformers folder-loading API — if the current release spells it differently, adapt here only; (b) padding token 0 — confirm against the tokenizer_config from Task 0 and use its `pad_token_id` if different.

- [ ] **Step 5: Run tests + BOTH app builds** (macOS + iOS sim build from CLAUDE.md — new dependency must link on both)

Expected: `** TEST SUCCEEDED **`, both `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Tuist/ Project.swift Targets/
git commit -m "feat(memory): GemmaTextEmbedder — EmbeddingGemma on Core ML behind TextEmbedder"
```

---

### Task 5: Bundle resources + app embedder factory with fallback

**Files:**
- Modify: `Project.swift` (Ember target resources), `Targets/Ember/Sources/EmberApp.swift`

**Interfaces:**
- Consumes: `GemmaTextEmbedder.init?(modelURL:tokenizerDirectory:)` (Task 4); resource layout (Task 0).
- Produces: `EmberApp.makeEmbedder() -> any TextEmbedder` (private static) — Gemma when bundled, else NL.

- [ ] **Step 1: Add the optional resource glob**

`Project.swift`, Ember target: `resources: ["Targets/Ember/Resources/**"]` already globs the whole directory — `Models/` (when present) rides along with no change. Confirm with: `./scripts/fetch_embeddinggemma.sh` output present, then `tuist generate --no-open` and check the generated project lists `EmbeddingGemma.mlpackage` under Ember's resources (Xcode compiles it to `.mlmodelc` in the bundle). Also confirm a `git status` shows nothing new to commit (gitignore working).

- [ ] **Step 2: Wire the factory**

`EmberApp.swift` — replace the `NLTextEmbedder()` line:

```swift
        let memory = MemoryStore(context: context, embedder: Self.makeEmbedder())
```

and add to `EmberApp`:

```swift
    /// EmbeddingGemma when its bundled resources exist (they are gitignored dev assets, so
    /// contributor and CI builds simply lack them); NLEmbedding otherwise. The choice is logged —
    /// it decides which vector space `embedderID` tags for this run.
    private static func makeEmbedder() -> any TextEmbedder {
        let bundle = Bundle.main
        let model = bundle.url(forResource: "EmbeddingGemma", withExtension: "mlmodelc")
            ?? bundle.url(forResource: "EmbeddingGemma", withExtension: "mlpackage")
        let tokenizer = bundle.url(forResource: "tokenizer", withExtension: nil)
        if let model, let tokenizer,
           let gemma = GemmaTextEmbedder(modelURL: model, tokenizerDirectory: tokenizer) {
            return gemma
        }
        return NLTextEmbedder()
    }
```

- [ ] **Step 3: Build both configurations**

Run: app build (macOS) WITHOUT `Models/` present (move it aside) → `** BUILD SUCCEEDED **`, launch path = NL fallback. Restore `Models/`, `tuist generate --no-open`, build again → `** BUILD SUCCEEDED **`. Framework tests unaffected.

- [ ] **Step 4: Manual smoke (dev machine, model present)**

Run the macOS app; expect log line `GemmaTextEmbedder ready (dim=256)` in Console (subsystem `com.ember.FoundationChatKit`, category embed). Send a message; confirm no errors and that a new `Message` row gets `embedderID == "embeddinggemma-300m-256"` (visible via next task's eval, or a temporary print).

- [ ] **Step 5: Commit**

```bash
git add Project.swift Targets/
git commit -m "feat(app): embedder factory — bundled EmbeddingGemma with NLEmbedding fallback"
```

---

### Task 6: Retrieval eval harness + ship gate

**Files:**
- Create: `Targets/FoundationChatKit/Tests/RetrievalEvalHarness.swift`, `Targets/FoundationChatKit/Tests/RetrievalEvalTests.swift`

**Interfaces:**
- Consumes: `MemoryStore.search(_:query:queryVector:topK:threshold:lexicalWeight:excludingMessageIDs:preferNotes:)`, `MemoryRecord`, embedders from Tasks 1/4.
- Produces: `RetrievalEvalCase`, `RetrievalEval.recallAtK(cases:embedder:k:)` — Plan-11+ tuning reuses this harness.

- [ ] **Step 1: Write the harness + deterministic tests**

`Targets/FoundationChatKit/Tests/RetrievalEvalHarness.swift`:

```swift
import Foundation
@testable import FoundationChatKit

/// One golden retrieval case: for `query`, searching `corpus` must surface `expected` in the top k.
/// `expected == nil` means a NEGATIVE case: nothing in the corpus is relevant and no hit should
/// clear the production threshold.
struct RetrievalEvalCase: Sendable {
    let name: String
    let query: String
    let corpus: [String]
    let expected: String?
}

enum RetrievalEval {
    /// Fraction of non-negative cases whose expected text lands in the top `k` — plus a hard pass
    /// bool for negatives. Uses the PRODUCTION search path and defaults (hybrid, threshold 0.35,
    /// lexicalWeight 0.5) so numbers reflect real behavior.
    static func recallAtK(cases: [RetrievalEvalCase], embedder: any TextEmbedder, k: Int)
        -> (recall: Double, negativesClean: Bool) {
        var hits = 0, positives = 0, negativesClean = true
        for c in cases {
            let snapshot = c.corpus.enumerated().map { i, text in
                MemoryRecord(messageID: UUID(), conversationID: UUID(), conversationTitle: "eval",
                             role: .user, text: text,
                             vector: embedder.embed(text, role: .document) ?? [], source: .note)
            }
            let qv = embedder.embed(c.query, role: .query) ?? []
            let results = MemoryStore.search(snapshot, query: c.query, queryVector: qv,
                                             topK: k, threshold: 0.35, lexicalWeight: 0.5,
                                             preferNotes: true)
            if let expected = c.expected {
                positives += 1
                if results.contains(where: { $0.record.text == expected }) { hits += 1 }
            } else if !results.isEmpty {
                negativesClean = false
            }
        }
        return (positives == 0 ? 0 : Double(hits) / Double(positives), negativesClean)
    }

    /// Golden fixtures. The first two encode the documented NLEmbedding failures (lexical-miss and
    /// the question-vs-question trap from the Plan-9 device debugging); keyword cases guard against
    /// regressing what lexical overlap already handles.
    static let fixtures: [RetrievalEvalCase] = [
        .init(name: "lexical-miss: packing→Lisbon trip",
              query: "what should I pack?",
              corpus: ["I'm planning a trip to Lisbon in September",
                       "favorite editor is Xcode", "has a golden retriever named Rex"],
              expected: "I'm planning a trip to Lisbon in September"),
        .init(name: "question-trap: fact must beat near-identical past question",
              query: "Where do I want to travel this summer?",
              corpus: ["Where do I want to travel this year?",
                       "wants to travel to Ghent and Lisbon",
                       "prefers window seats on flights"],
              expected: "wants to travel to Ghent and Lisbon"),
        .init(name: "paraphrase: job",
              query: "what do I do for work?",
              corpus: ["works as an iOS developer at a small startup",
                       "allergic to peanuts", "sister is called Maria"],
              expected: "works as an iOS developer at a small startup"),
        .init(name: "keyword: direct recall still works",
              query: "what's my favorite color?",
              corpus: ["favorite color is teal", "drinks oat-milk lattes",
                       "runs 5k on Tuesdays"],
              expected: "favorite color is teal"),
        .init(name: "negative: nothing relevant",
              query: "what's the capital of Mongolia?",
              corpus: ["favorite color is teal", "has a golden retriever named Rex"],
              expected: nil),
    ]
}
```

`Targets/FoundationChatKit/Tests/RetrievalEvalTests.swift`:

```swift
import Foundation
import Testing
@testable import FoundationChatKit

struct RetrievalEvalTests {
    /// Deterministic harness sanity on MockEmbedder: shared-vocabulary cases must recall; the
    /// harness itself (snapshot building, roles, production thresholds) is what's under test.
    @Test func harnessRecallsKeywordCaseOnMock() {
        let cases = RetrievalEval.fixtures.filter { $0.name.hasPrefix("keyword") }
        let result = RetrievalEval.recallAtK(cases: cases, embedder: MockEmbedder(vocabulary:
            ["favorite", "color", "teal", "lattes", "runs"]), k: 4)
        #expect(result.recall == 1.0)
    }

    // MARK: - Real-model ship gate (runs only where the dev weights exist)

    static var gemma: GemmaTextEmbedder? {
        guard let dir = ProcessInfo.processInfo.environment["EMBER_GEMMA_MODEL_DIR"] else { return nil }
        let base = URL(fileURLWithPath: dir)
        return GemmaTextEmbedder(modelURL: base.appendingPathComponent("EmbeddingGemma.mlpackage"),
                                 tokenizerDirectory: base.appendingPathComponent("tokenizer"))
    }

    /// SHIP GATE (spec §6): EmbeddingGemma must beat NLEmbedding on fixture recall@4 without
    /// regressing keyword cases or firing on the negative case. If this fails, the default embedder
    /// stays NLEmbedding — do not merge a failing gate.
    @Test(.enabled(if: gemma != nil))
    func gemmaBeatsNLOnFixtures() async throws {
        let g = try #require(Self.gemma)
        try await Task.sleep(for: .seconds(15))   // async resource load; generous for CI-less dev runs
        let gemmaScore = RetrievalEval.recallAtK(cases: RetrievalEval.fixtures, embedder: g, k: 4)
        let nlScore = RetrievalEval.recallAtK(cases: RetrievalEval.fixtures,
                                              embedder: NLTextEmbedder(), k: 4)
        #expect(gemmaScore.recall > nlScore.recall)
        #expect(gemmaScore.negativesClean)
        let keyword = RetrievalEval.fixtures.filter { $0.name.hasPrefix("keyword") }
        #expect(RetrievalEval.recallAtK(cases: keyword, embedder: g, k: 4).recall == 1.0)
    }
}
```

- [ ] **Step 2: Run to verify state** — `tuist generate --no-open` + test command. Expected: harness + mock test PASS; the gated test shows SKIPPED without `EMBER_GEMMA_MODEL_DIR`.

- [ ] **Step 3: Run the ship gate on the dev machine**

Run:

```bash
EMBER_GEMMA_MODEL_DIR="$PWD/Targets/Ember/Resources/Models" \
xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40
```

Expected: `gemmaBeatsNLOnFixtures` PASS. If it FAILS: stop, investigate (prefix strings? parity? pad token?), and do NOT proceed to merge — the factory default stays NL until the gate passes. (Note: xcodebuild may need the env passed via a test plan or `-testPlan`; if the env var doesn't reach the test process, use `TEST_RUNNER_EMBER_GEMMA_MODEL_DIR=...` — xcodebuild forwards `TEST_RUNNER_`-prefixed vars.)

- [ ] **Step 4: Commit**

```bash
git add Targets/
git commit -m "test(memory): retrieval eval harness + EmbeddingGemma-vs-NL ship gate"
```

---

### Task 7: Docs + license flow-down

**Files:**
- Modify: `README.md`, `CLAUDE.md`

**Interfaces:** none (docs).

- [ ] **Step 1: Update docs**

- `README.md`: add an "Embeddings" subsection — EmbeddingGemma-300m on Core ML (256-dim Matryoshka), bundled weights via `scripts/fetch_embeddinggemma.sh` (gitignored; contributors without weights automatically run the NLEmbedding fallback), embedder-versioned vectors + chunked migration, and the **Gemma Terms of Use note**: any distributed build containing the weights must include Google's Prohibited Use Policy flow-down in its terms.
- `CLAUDE.md`: update the "On-device / privacy-first ethos" bullet (embeddings: EmbeddingGemma via Core ML when bundled, NLEmbedding fallback; weights never committed) and the roadmap line; add gotcha: "run `scripts/fetch_embeddinggemma.sh` once per machine for real-embedding runs; the eval ship gate needs `TEST_RUNNER_EMBER_GEMMA_MODEL_DIR`".

- [ ] **Step 2: Full verification sweep**

Run all three Global Constraints commands (framework tests, macOS app build, iOS sim app build).
Expected: all green.

- [ ] **Step 3: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: EmbeddingGemma embedder — setup, fallback, license flow-down"
```

---

## Self-Review (done at authoring time)

- **Spec coverage:** seam v2 → Task 1; GemmaTextEmbedder → Task 4; packaging/scripts → Tasks 0+5; versioning+migration → Tasks 2+3; fallback+wiring → Task 5; eval gate → Task 6; licensing → Task 7. Spec's "risks/verify-then-use" items are embedded as inline verify steps (prefixes: Tasks 0/4; conversion parity: Task 0; latency: Task 5 smoke; app size: Task 5 Step 1 observation — flag in PR description).
- **Type consistency:** `EmbedderIdentity(id:dimension:)`, `embed(_:role:)`, `backfill(chunkSize:)`, `GemmaEmbeddingFormat.prompt(_:role:)`, `GemmaTextEmbedder(modelURL:tokenizerDirectory:)` used identically across tasks; `OtherSpaceEmbedder` defined in Task 2's file, reused by Task 3's tests (same test target).
- **Known intentional deviations:** `MockEmbedder` keeps a role-less sugar overload (test-only) so ~30 existing call sites don't churn; production code has no such overload.
