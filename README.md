# 🔥 Ember

**A privacy-first, fully on-device AI chat app built on Apple's Foundation Models framework — with the model's working memory made visible.**

Ember runs entirely on-device (no servers, no network, no API keys). It feels like Claude/Codex — a conversation sidebar, streaming message bubbles, a clean composer — but adds a distinctive **transparency layer**: because the on-device model has a hard **4,096-token context window**, Ember makes that working memory *inspectable*. A **Context** view shows the exact prompt the model sees (instructions, tools, tool calls/outputs, retrieved memories); a **Tokens** gauge shows how much of the window is used, broken down line by line.

- **Platforms:** iOS 26 · iPadOS 26 · macOS 26 (Apple-Intelligence-capable devices)
- **Stack:** SwiftUI · MVVM + `@Observable` · SwiftData · FoundationModels · NaturalLanguage · Tuist · Swift Testing
- **No external runtime dependencies. No network entitlement.**

| Streaming chat + token gauge | Conversation memory (RAG) | Token budget inspector |
|---|---|---|
| ![Chat](docs/screenshots/chat.png) | ![Memory recall](docs/screenshots/memory-recall.png) | ![Token inspector](docs/screenshots/token-inspector.png) |

---

## ✨ Features

**Chat & UX**
- Streaming responses (cumulative snapshots → a single growing bubble), Stop to cancel, `isResponding` send-guard.
- Adaptive `NavigationSplitView` (sidebar + chat) with a right-hand `[Context | Tokens]` inspector and a toolbar token gauge.
- Markdown rendering in assistant bubbles (prose + fenced code blocks), via native `AttributedString`.
- Availability gating with a tailored screen per unavailable reason (device not eligible / Apple Intelligence off / model not ready), live re-checks, and a Settings deep-link.
- Persisted multi-conversation history (SwiftData), rename, and full-text search across titles + messages.

**Transparency**
- **Context inspector** renders the *literal* `session.transcript` — instructions, user/assistant turns, and every `TOOL CALL` / `TOOL OUTPUT` with formatted JSON args.
- **Tokens** tab: live gauge, per-line breakdown (instructions, each tool definition, each turn, tool usage), green/amber/red zones, "reserved for reply", and honest **exact (26.4+) vs estimated** labeling.

**On-device intelligence**
- **Tool calling** — three pure, on-device tools (`currentDateTime`, `calculator`, `unitConverter`) built on the FoundationModels `Tool` protocol with `@Generable`/`@Guide` arguments. No network, no permissions.
- **Guided generation** — model-generated conversation titles (`respond(to:generating:)`), with a deterministic fallback.
- **Conversation memory (RAG)** — a `searchMemory` tool lets the model recall relevant snippets from *past conversations* via on-device `NLEmbedding` semantic search (brute-force cosine top-k). Every recall is visible in the inspector.
- **Advanced budgeting** — model-summarized context compaction (with a deterministic keep-first-last fallback) and reserve-for-reply: Ember compacts *proactively* before a turn would overflow, so replies always have headroom.

---

## 🧱 Architecture

Two Tuist targets. **All decision logic lives in the framework, behind a protocol seam**, so it's unit-testable with a mock on any machine — no Apple-Intelligence device required. The app target is a thin SwiftUI binding layer.

```
┌──────────────────────── Ember (app, SwiftUI) ─────────────────────────┐
│  RootView (availability gate)                                          │
│   ├─ UnavailableView(reason)                                           │
│   └─ ChatScene ── NavigationSplitView ─┬─ ConversationListView (search,│
│                                        │   rename, new chat)           │
│                                        ├─ ChatView (MarkdownText        │
│                                        │   bubbles + ComposerView)      │
│                                        └─ .inspector → [Context|Tokens] │
└───────────────────────────────────────┬───────────────────────────────┘
                                         │ depends on
┌──────────────── FoundationChatKit (framework, no UI) ──────────────────┐
│  ChatCoordinator (@Observable @MainActor)  ── owns store + engine       │
│  ConversationEngine (@Observable)          turn lifecycle, budgeting    │
│  ChatModelProvider / ChatSessionHandle  ┐  the seam                     │
│     ├─ FoundationModelProvider (real)   ┘  wraps SystemLanguageModel    │
│     └─ MockModelProvider (tests)                                        │
│  Tools: Calculator/DateTime/UnitConverter/MemorySearch · Toolbox        │
│  Memory: TextEmbedder (NLEmbedding) · MemoryStore · ContextCompactor    │
│  Tokens: TokenEstimator · TokenBudgetCalculator · TokenBudget           │
│  Context: ContextProjection · OverflowRecovery                          │
│  Persistence: Conversation · Message · ConversationStore (SwiftData)    │
└──────────────────────── depends only on: Apple frameworks ─────────────┘
```

**Key patterns:** MVVM + `@Observable`; dependency injection via protocols; **dual-truth persistence** (durable `Message` rows are the display source of truth; an encoded `Transcript` is a best-effort fast-resume cache); tools are pure `Sendable` `Tool` conformances; memory search runs over an immutable per-session snapshot so the tool stays pure.

---

## 📁 Project structure

```
AppleFoundationModels/
├── Project.swift            # Tuist project (targets, destinations, bundle ids)
├── Tuist.swift
├── CLAUDE.md                # Claude Code project guide (build/conventions/skills index)
├── README.md
├── Targets/
│   ├── FoundationChatKit/   # framework: all logic + tests (Sources/, Tests/)
│   └── Ember/               # SwiftUI app (Sources/, Resources/)
├── docs/
│   ├── superpowers/
│   │   ├── specs/           # one design spec per phase
│   │   └── plans/           # one task-by-task implementation plan per phase
│   └── screenshots/
└── .claude/
    └── skills/              # reusable iOS/SwiftUI/Foundation-Models skills
```

---

## 🛠 Requirements

- **macOS 26 (Tahoe)** + **Xcode 26.x** (built against the 26.4 SDK so `contextSize`/`tokenCount(for:)` resolve).
- **[Tuist](https://docs.tuist.dev)** (`tuist generate` to produce the Xcode project).
- To run the real on-device model: an **Apple-Intelligence-capable device** (or the iOS 26 simulator, where the model is available) with **Apple Intelligence enabled**. The app degrades gracefully to a tailored "unavailable" screen otherwise.

## ▶️ Build & run

```bash
git clone https://github.com/Vvlladd/Ember.git
cd Ember
tuist generate            # creates Ember.xcworkspace
open Ember.xcworkspace    # ⌘R the "Ember" scheme (macOS or an iOS 26 simulator)
```

Or from the command line:

```bash
xcodebuild -workspace Ember.xcworkspace -scheme Ember \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## ✅ Testing

All logic is TDD-covered in the framework (118 tests across 29 suites):

```bash
xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit \
  -destination 'platform=macOS' test 2>&1 | tail -20    # ** TEST SUCCEEDED **
```

The `MockModelProvider`/`MockEmbedder` doubles mean the entire engine, tools, memory, budgeting, and compaction logic run green without an Apple-Intelligence device.

---

## 🗺 Roadmap status — **Phases 1–3 complete**

| Phase | Theme | Status |
|------|-------|--------|
| **1** | Streaming chat · availability gating · token gauge · Context inspector · persisted history · overflow recovery | ✅ Built |
| **2** | Tool calling (`Tool` + `@Generable`/`@Guide`) · guided/structured generation | ✅ Built |
| **3** | RAG (on-device conversation memory) · advanced budgeting (model-summarized compaction, reserve-for-reply) | ✅ Built |

Each phase was developed spec-first (see `docs/superpowers/`) and verified end-to-end on the iOS 26 simulator — including a real on-device tool call (`calculator` → 8,673,516) and cross-conversation memory recall (`searchMemory` → "Lisbon").

Possible future work (beyond the current roadmap): attachments/images, iCloud/CloudKit sync, multilingual embeddings, and richer compaction strategies.

---

## 🤖 Working in this repo with Claude Code

- **`CLAUDE.md`** documents build/test commands, architecture, and conventions.
- **`.claude/skills/`** holds reusable skills (Foundation Models, SwiftUI, Swift Concurrency, Liquid Glass, performance audit, simulator debugging, GitHub issue flow, App Store changelog). Claude Code auto-discovers them; `CLAUDE.md` indexes when each applies.
- Specs and task-by-task plans for every phase live in `docs/superpowers/`.

---

*Built with [Tuist](https://docs.tuist.dev) and Apple's [Foundation Models](https://developer.apple.com/documentation/foundationmodels) framework. On-device, private, and transparent by design.*
