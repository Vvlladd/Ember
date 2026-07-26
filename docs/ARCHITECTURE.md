# Ember — Architecture

Three views of the system, from app-level down to classes. Editable Excalidraw sources live in [`docs/diagrams/`](diagrams/) (open with [excalidraw.com](https://excalidraw.com) or the VS Code extension); the Mermaid versions below render on GitHub. The memory/RAG pipeline has its own diagram in the [README](../README.md#how-memory-works).

## 1. High-level architecture

Source: [`diagrams/ember-app-architecture.excalidraw`](diagrams/ember-app-architecture.excalidraw)

Two Tuist targets. All decision logic lives in **FoundationChatKit** behind protocol seams, testable with mocks on any machine (258 tests, no Apple-Intelligence device needed). The app target is thin SwiftUI binding.

```mermaid
flowchart TD
    subgraph APP["Ember (SwiftUI app — thin binding)"]
        UI["RootView · ChatScene · ConversationListView<br/>ChatView / MessageBubble / ComposerView<br/>ContextInspectorView + TokenMeterView · ErrorBanner"]
    end

    subgraph KIT["FoundationChatKit (framework — all logic)"]
        CO["ChatCoordinator (app brain)<br/>builds engines · post-turn: index → drain saveMemory →<br/>auto-extract (grounded) → title"]
        EN["ConversationEngine (@Observable, per conversation)<br/>performTurn: retrieve → inject → stream<br/>compactIfNeeded · recoverFromOverflow · refreshExactBudget"]
        MEM["Memory (RAG)<br/>MemoryStore · TextEmbedder seam<br/>MemoryExtractor + grounding · MemoryContextBlock"]
        TOK["Tokens<br/>TokenEstimator · TokenBudgetCalculator<br/>TokenBreakdown · TokenMeterColor"]
        CTX["Context-window mgmt<br/>ContextCompactor · ConversationSummary<br/>OverflowRecovery · transcript projection"]
        TL["Tools (3–5 max)<br/>dateTime · calculator · unitConverter<br/>searchMemory · saveMemory→buffer"]
        SEAM["Provider seam<br/>ChatModelProvider / ChatSessionHandle<br/>title / summarizeStructured / extractMemories<br/>(nil = unavailable)"]
        DB[("SwiftData (dual-truth)<br/>Conversation · Message(+embedderID) · MemoryNote<br/>durable rows + best-effort encoded Transcript")]
    end

    subgraph PROV["Providers"]
        FM["FoundationModelProvider (real)<br/>LanguageModelSession · Transcript codec<br/>error mapping → ChatError"]
        MK["MockModelProvider + MockEmbedder (tests)"]
    end

    SYS["System frameworks (all on-device, no network)<br/>FoundationModels (~3B, 4096 tokens) · NaturalLanguage · Core ML · SwiftData"]

    UI --> CO
    CO --> EN
    CO --> MEM
    CO --> DB
    EN --> TOK
    EN --> CTX
    EN --> SEAM
    EN --> TL
    MEM --> DB
    SEAM --> FM
    SEAM -.-> MK
    FM --> SYS
    MEM --> SYS
```

Key patterns: MVVM + `@Observable`; dependency injection via protocols; capability methods return `nil` when the model is unavailable so every feature degrades instead of failing; the embedder is swappable behind `TextEmbedder` (EmbeddingGemma on Core ML when bundled, NLEmbedding fallback otherwise) with `embedderID`-versioned vectors so vector spaces never mix.

## 2. Context-window management

Source: [`diagrams/ember-context-window.excalidraw`](diagrams/ember-context-window.excalidraw)

Everything competes for **4,096 tokens** (`SystemLanguageModel.contextSize`): instructions, tool definitions, the injected `⟦memory⟧` block, conversation history, and the streaming reply. Ember plans against it with a two-tier counting strategy and compacts before it overflows.

```mermaid
flowchart TD
    subgraph COUNT["Token counting (two tiers)"]
        EST["LIVE estimate (sync)<br/>TokenEstimator: ceil(chars / 3.5) + 1/CJK scalar<br/>drives the gauge while typing"]
        EXA["EXACT refresh (async, 26.4+)<br/>SystemLanguageModel.tokenCount per line, cached<br/>after each turn + on resume"]
        BRK["TokenBudgetCalculator.snapshot / breakdown<br/>one budget line per entry + per tool schema digest<br/>buckets: Instructions / Tools / Memory / History<br/>+ 'Reserved for reply: 512'"]
        MET["TokenMeterView — 4-tier color vs 4096"]
        EST --> BRK
        EXA -. replaces estimates .-> BRK
        BRK --> MET
    end

    subgraph TURN["Turn lifecycle"]
        P0["user hits send"] --> P1{"PROACTIVE check:<br/>used + estimate(prompt) + 512 reserve<br/>&gt; maxContextTokens?"}
        P1 -- no --> P2["retrieve memory → inject ⟦memory⟧<br/>(≤3 hits × 240 chars, dedup-collapsed)"]
        P2 --> P3["stream reply via ChatSessionHandle"]
        P3 --> P4["post-turn: exact-count refresh<br/>index · extract · title"]
        P1 -- yes --> C0
        P3 -- "ChatError.contextOverflow (REACTIVE)" --> C0
    end

    subgraph COMPACT["Compaction"]
        C0["ContextCompactor.compact"] --> C1["keep 4 most recent entries VERBATIM<br/>render older to text, dropping stale ⟦memory⟧ blocks"]
        C1 --> C2["provider.summarizeStructured →<br/>@Generable ConversationSummary<br/>(summary + ≤5 topics + ≤5 preferences)"]
        C2 --> C3["preferences → saveNoteIfNovel<br/>(survive compaction as durable notes)"]
        C2 -- "model unavailable" --> C4["OverflowRecovery.condense:<br/>keep first + last entries"]
        C3 --> C5["FRESH session: makeSession(seeding:)<br/>recap folded into instructions + verbatim tail<br/>tools re-registered on every construction path"]
        C4 --> C5
        C5 --> P2
    end

    UTIL["Utility generations are capped too — UtilityGenerationOptions:<br/>greedy · temp 0 · maxResponseTokens: title 24 / extraction 256 / summary 320"]
```

Rules of thumb encoded here: tools cost context (3–5 max, short `@Guide` texts — each definition is a visible budget line); the memory block is budget-accounted as its own line and never double-counted after the transcript split; compaction is **proactive first** (trigger math before sending) with the reactive overflow path as backstop; and the structured summary doubles as a preference harvest so durable facts survive the recap.

## 3. Low-level architecture (classes & seams)

```mermaid
classDiagram
    class ChatCoordinator {
        +availability: ModelAvailability
        +send(text, in: Conversation)
        -makeEngine(for:) ConversationEngine
        -postTurn: index / drain buffer / extract / title
    }
    class ConversationEngine {
        <<@Observable @MainActor>>
        +messages: [ChatMessage]
        +tokenBudget / tokenBreakdown
        +performTurn(prompt)
        -compactIfNeeded(prompt)
        -recoverFromOverflow() async
        -refreshExactBudget() async
    }
    class ChatModelProvider {
        <<protocol>>
        +availability
        +maxContextTokens: Int
        +makeSession(settings, tools, restoring/seeding)
        +generateTitle(forFirstExchange) String?
        +summarizeStructured(text) ConversationSummary?
        +extractMemories(userText) [String]?
        +tokenCount / exactTokenCount
    }
    class ChatSessionHandle {
        <<protocol>>
        +stream(prompt) AsyncThrowingStream
        +contextEntries: [ContextEntry]
        +encodedTranscript() Data?
    }
    class FoundationModelProvider {
        LanguageModelSession + Transcript codec
        TranscriptMapping: split ⟦memory⟧ → .retrievedMemory
        error map → ChatError (+transient retry)
    }
    class MemoryStore {
        <<@MainActor>>
        +index(Message)  USER-only, .document
        +saveNote / saveNoteIfNovel
        +backfill(chunkSize=50) awaits ready()
        +snapshot() [MemoryRecord]  space-gated
        +search(hybrid, preferNotes)$ 
    }
    class TextEmbedder {
        <<protocol>>
        +identity: EmbedderIdentity
        +embed(text, role) [Float]?
        +ready() async
    }
    class GemmaTextEmbedder {
        Core ML .mlmodelc + swift-transformers tokenizer
        256-dim Matryoshka · query/document prefixes
        async load · nil until ready
    }
    class NLTextEmbedder {
        NLEmbedding sentence vectors (512d, .english)
        permanent fallback
    }
    class MemoryExtractor {
        guided gen, USER text only
        durableFacts(from, groundedIn)
        proper-noun grounding guard
    }
    class MemoryContextBlock {
        wrap/augment/split (⟦memory⟧ markers)
        selectDistinct via DedupText
        "the user said/asked" framing
    }
    class TokenBudgetCalculator {
        +snapshot(lines) TokenBudget
        +breakdown(from, replyReserve) TokenBreakdown
    }
    class ContextCompactor {
        +compact(entries, provider, onPreference)
        keep-4 · structured recap · pref harvest
    }

    ChatCoordinator --> ConversationEngine : builds per conversation
    ChatCoordinator --> MemoryStore : post-turn writes
    ChatCoordinator --> ChatModelProvider
    ConversationEngine --> ChatSessionHandle : streams
    ConversationEngine --> TokenBudgetCalculator
    ConversationEngine --> ContextCompactor
    ConversationEngine --> MemoryContextBlock : inject
    ChatModelProvider <|.. FoundationModelProvider
    MemoryStore --> TextEmbedder
    TextEmbedder <|.. GemmaTextEmbedder
    TextEmbedder <|.. NLTextEmbedder
    MemoryExtractor <-- FoundationModelProvider : extractMemories
    ContextCompactor --> ChatModelProvider : summarizeStructured
```

Load-bearing invariants (each one is test-pinned):

- **Vector spaces never mix** — every cosine comparison is gated on `embedderID` matching the active `EmbedderIdentity`; stale rows behave as unembedded (lexical-only) until the chunked backfill re-embeds them.
- **The memory block round-trips** — `MemoryContextBlock.split(augment(p, hits)).userText == p`; the transcript split turns the injected block into a `.retrievedMemory` entry so it is displayed and budget-counted exactly once.
- **Extraction is grounded** — facts contain no proper noun the user didn't type (case/diacritic-folded), and the extractor never sees assistant text.
- **Every session-construction path re-registers tools** (initial, restore, overflow-seeded) — miss one and tools silently vanish.
- **Capability methods return `nil` on unavailability** — the app degrades (no title, no extraction, no compaction summary) instead of erroring.
