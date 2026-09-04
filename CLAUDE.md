# Ember — AI coding-agent project guide

Ember is a **privacy-first, fully on-device AI chat app** for iOS / iPadOS / macOS 26, built on Apple's **Foundation Models** framework. It looks like Claude/Codex (conversation sidebar, streaming bubbles, composer) and adds a **transparency layer**: a Context inspector showing exactly what the model sees, and a token gauge against the 4,096-token window.

This file tells Claude Code, Codex, and other coding agents how to work in this repo. Keep it accurate when things change. `AGENTS.md` is a symlink to this file so the guidance stays in sync.

---

## Build, test & run (ground truth)

Tooling: **Tuist** (project generation) + **Swift Testing** + **xcodebuild**. The `.xcodeproj`/`.xcworkspace` are generated and git-ignored.

```bash
# After creating/deleting ANY source file, regenerate before building/testing:
tuist generate --no-open

# Framework unit tests (all logic lives here; this is the primary gate):
xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40   # -> ** TEST SUCCEEDED **

# EmberScope's own suite (independent framework, its own scheme):
xcodebuild -workspace Ember.xcworkspace -scheme EmberScope -destination 'platform=macOS' test 2>&1 | tail -20

# Build the app:
xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=macOS' build 2>&1 | tail -10
xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -10

# The EmberScope example host — keep it building:
xcodebuild -workspace Ember.xcworkspace -scheme EmberScopeExample -destination 'platform=macOS' build 2>&1 | tail -10

# Release too — it is the only build that proves the #if DEBUG gating still compiles:
xcodebuild -workspace Ember.xcworkspace -scheme Ember -configuration Release -destination 'platform=macOS' build 2>&1 | tail -10
```

- **SourceKit/editor diagnostics are unreliable here** ("No such module 'Testing'", "cannot find type …") — there is no module graph in the editor. **Ground truth is the xcodebuild run.** Trust it, not the squiggles.
- If a Bash command fails with a sandbox/permission error (not a real compile/test failure), retry it with `dangerouslyDisableSandbox: true`.
- To run/observe the app on the simulator, prefer the **`ios-debugger-agent`** skill (XcodeBuildMCP).

## Architecture

Four Tuist targets; **all decision logic is in the framework, behind a protocol seam, so it is unit-testable with a mock on any machine** (no Apple-Intelligence device required). The app target is thin SwiftUI binding.

- **`FoundationChatKit`** (framework, no UI) — `ConversationEngine` (`@Observable @MainActor` per-conversation view model), `ChatModelProvider`/`ChatSessionHandle` seam (`FoundationModelProvider` real + `MockModelProvider` test double), token budgeting, transcript projection, tools, conversation-memory RAG, overflow/compaction, SwiftData persistence (`Conversation`/`Message`/`ConversationStore`), and the app brain `ChatCoordinator`.
- **`EmberScope`** (framework, netfox-style inspector for Foundation Models) — `InspectedSession`/`InspectedTool` wrappers around `LanguageModelSession`, `ScopeRecorder` (lock-protected ring buffer + `ScopeSink`s) folded by the main-actor `ScopeStore`, and the SwiftUI console `EmberScopeView`. **Depends on nothing else in the repo**; `FoundationChatKit` and `Ember` both depend on it. `FoundationModelProvider` builds chat sessions with `EmberScope.session(label: "chat")` and the utility sessions use labels `title` / `summary` / `summary.structured` / `extract`. Its own README is `Targets/EmberScope/README.md`.
- **`Ember`** (SwiftUI app) — `RootView` (availability gate) → `ChatScene` (`NavigationSplitView` + toolbar gauge + `.inspector`), `ConversationListView`, `ChatView`/`MessageBubble`/`ComposerView`, `ContextInspectorView` + `TokenMeterView`.
- **`EmberScopeExample`** (SwiftUI app, `Targets/EmberScopeExample/Sources`) — the netfox-style example host for EmberScope: `ExampleApp` (the whole integration — `start()`, `.emberScope()`, `EmberScopeCommands`, the macOS window), `ChatModel` (one `InspectedSession`, no persistence), three self-contained tools, `CityFacts`, and a `Scenario` menu that drives every inspector path. **Depends on `EmberScope` alone** — see the gotcha below. Documented in `Targets/EmberScope/README.md` § Example app.

**Patterns:** MVVM + `@Observable`; dependency injection via protocols; **dual-truth persistence** (durable `Message` rows + best-effort encoded `Transcript`); tools conform to FoundationModels `Tool` with `@Generable`/`@Guide`.

## Conventions & hard-won gotchas

- **Run `tuist generate --no-open` after any file add/delete** before xcodebuild (Tuist resolves source globs at generation time).
- **SwiftData:** use an explicit `ConversationStore(context: ModelContext(container))` — NOT `@Query`/`.modelContainer` (cross-module `@Model` + `mainContext` traps on macOS 26.x). Share **one** `ModelContext` between `ConversationStore` and `MemoryStore`.
- **Exact token counts are async-only:** `SystemLanguageModel.tokenCount(for:)` is `async throws`; the live/typing path uses the char estimator, and the engine refreshes to exact counts after a turn and on resume. `contextSize` is non-throwing.
- **Tools cost context** — keep to **3–5 tools**, short `@Guide` descriptions; tool definitions are counted as budget lines.
- **On-device / privacy-first ethos:** **no network capability or entitlement.** Embeddings use **EmbeddingGemma-300m on Core ML** (256-dim, behind `TextEmbedder`) when its weights are bundled, else `NLEmbedding` (system framework). Gemma weights are dev-fetched per machine and **never committed** to the repo. Keep it on-device. *Caveat to state honestly:* the tokenizer comes from `swift-transformers`, which only vends one umbrella `Transformers` library product — so it transitively links a **dormant Hugging Face Hub client**. No runtime code path reaches it (only `AutoTokenizer.from(modelFolder:)`, a local-disk load) and the app has no network entitlement, but the code is linked in.
- **Keep the app target compiling at every commit** — e.g. adding a `ChatError` case requires updating `ErrorBanner`'s exhaustive switch in the same change.
- **EmberScope must never import `FoundationChatKit`** — the dependency runs the other way, which is what keeps the library liftable into another project. `ScopeConfiguration.isEnabled` defaults to the library's own `DEBUG`, and when it is off **every wrapper records nothing and allocates no per-request state** — preserve that in any new wrapper method. No disk, no network: the ring buffer is the only storage. `EmberScope.note(…)` carries counts and kinds, **never user text** — note text is the one string `captureContent: false` does NOT redact (notes are developer annotations). Every **app-side** EmberScope surface is behind `#if DEBUG`, so a Release build of Ember has none of it; the framework itself stays linked and inert (the provider creates sessions through it unconditionally). The EmberScope target builds warnings-as-errors under `SWIFT_STRICT_CONCURRENCY = complete`. Do **not** add a nested `Package.swift` — Tuist would treat it as a project manifest; the manifest for standalone extraction lives in `Targets/EmberScope/README.md`. Presentation (`EmberScope.present()`, shake, ⌘⇧E) gates on `configuration.isEnabled` only — never on the recording toggle, so a paused inspector stays openable. `ScopeStore.refresh()` is `async` (the fold runs off the main actor behind a generation guard); error chains are stored root first; `streamResponse`/`collect()` return `sending` values like the SDK. The full list of rulings, deferred items and follow-ups is the **Decision log** in the EmberScope spec (`docs/superpowers/specs/2026-09-02-emberscope-foundation-models-inspector-design.md`) — extend it when you change a decision.
- **Foundation Models SDK gotchas found while building EmberScope:** `Prompt` and `Instructions` expose **no public text accessor**, so a `Prompt`-typed call has no readable prompt text until the request completes and it is recovered from the transcript — prefer the `String` overloads when the text should be captured up front. `GenerationSchema` does **not** encode deterministically, so `ToolInfo` encodes schema JSON with `.sortedKeys`. Any new `InspectedSession` wrapper must mirror the SDK's isolation exactly — `nonisolated(nonsending)` on the async entry points, `next(isolation:)` on the iterator — or the wrapper hops actors where the SDK does not.
- **Strict concurrency in `EmberScope`** (the target sets `SWIFT_STRICT_CONCURRENCY=complete` so Swift-6 hosts can adopt it): `Mutex` is `~Copyable`, so a closure must capture the **owning class**, never the mutex itself (see `RequestFinalizer`); and give a `@Sendable` default parameter a **closure literal** (`= { Date() }`) rather than a bare function reference, which warns.
- **The example app must never import `FoundationChatKit`** — `EmberScopeExample` depends on `EmberScope` alone, and that dependency shape is the point: it is the proof the library drops into any Foundation Models host. Its tools are deliberate self-contained copies of Ember's, not shared code. Keep it building on both platforms in every commit that touches `EmberScope`'s public API.
- **Tuist scheme autogeneration groups by name suffix, and "Example" is a RUN suffix** (alongside "App" and "Demo"), so `EmberScopeExample` was silently folded into the `EmberScope` scheme as its run target instead of getting one of its own. `Project.swift` therefore states `automaticSchemesOptions` explicitly — Tuist 4.154.3's defaults (`build: ["Implementation", "Interface", "Mocks", "Testing"]`, `test: ["Tests", "IntegrationTests", "UITests", "SnapshotTests"]`, `run: ["App", "Demo", "Example"]`) with `"Example"` — and nothing else — dropped from `run`. So a new target whose name ends in `App` or `Demo` becomes the RUN target of the same-prefix scheme; one ending in `Tests`, `IntegrationTests`, `UITests` or `SnapshotTests` is grouped as a TEST target, and `Implementation`, `Interface`, `Mocks` or `Testing` as a BUILD target. Any of those and it gets no scheme of its own — check `Ember.xcodeproj/xcshareddata/xcschemes/` after generating.
- **EmbeddingGemma setup:** run `scripts/fetch_embeddinggemma.sh` once per machine to exercise the real embedder (weights land in gitignored `Targets/Ember/Resources/Models/`); without it the app/tests run on the `NLEmbedding` fallback. The `gemmaBeatsNLOnFixtures` ship-gate test only runs when the test process sees `EMBER_GEMMA_MODEL_DIR` pointing at that Models dir — from **xcodebuild** set it as `TEST_RUNNER_EMBER_GEMMA_MODEL_DIR=…` (xcodebuild forwards only `TEST_RUNNER_`-prefixed vars into the test runner, stripping the prefix); from **Xcode's scheme editor** add it as plain `EMBER_GEMMA_MODEL_DIR`. Without it the test SKIPs.
- **TDD, granular commits.** If an AI assistant materially co-authors a change, use that assistant's applicable co-author trailer and disclose the assistance in the pull request.

## Project skills — invoke via the Skill tool when relevant

Reusable skills live in **`.claude/skills/`** and **`.agents/skills/`** (imported from `unPiRoomPlan`). Treat these as the house style for iOS/SwiftUI/Foundation Models work and **invoke the matching skill before doing that kind of task**:

| Skill | Use it when… |
|---|---|
| **`foundation-models-best-practices`** | Designing/implementing/reviewing Foundation Models usage — model selection, prompts, guardrails, async integration, performance, privacy. *(Most relevant to this repo.)* |
| **`swiftui-expert-skill`** | Writing/reviewing/refactoring SwiftUI — state management, view composition, performance, modern APIs, Liquid Glass. |
| **`swift-concurrency`** | Guidance on async/await, actors, tasks, `@MainActor`/`Sendable`, Swift 6 migration, data-race/architecture questions. |
| **`swift-concurrency-expert`** | Reviewing/remediating Swift Concurrency or fixing concurrency compiler errors in a file/feature (Swift 6.2+). |
| **`swiftui-liquid-glass`** | Adopting/reviewing the iOS 26+ Liquid Glass API in SwiftUI. |
| **`swiftui-performance-audit`** | Diagnosing slow rendering, janky scrolling, excessive view updates, layout thrash. |
| **`ios-debugger-agent`** | Building/running/launching/debugging the app on a booted simulator and inspecting UI/logs (XcodeBuildMCP). |
| **`gh-issue-fix-flow`** | Taking a GitHub issue number end-to-end: inspect via `gh`, fix, build/test, commit-closing, push. |
| **`app-store-changelog`** | Generating user-facing release notes / "What's New" from git history since the last tag. |

> Project skills are auto-discovered by the active coding agent; this table is the index of when each applies.

## Where things live

- **Specs:** `docs/superpowers/specs/` · **Plans:** `docs/superpowers/plans/` (one spec + one task-by-task plan per phase; grounded in Apple docs).
- **Roadmap status:** Phases 1–7 are **built** (streaming chat + gauge + inspector + history → tool calling + guided generation → conversation-memory RAG + advanced budgeting → **automatic retrieve-before-generate + embedder/snapshot caching + model-decided `saveMemory`** → **Plan 9 automatic post-turn fact extraction → deduped curated `MemoryNote`s (`saveNoteIfNovel`, gated by `autoExtractMemories`)** → **recall & reliability hardening: notes-ranked-above-snippets retrieval (`search(preferNotes:)`, default `topK` 1→4) so durable facts aren't buried by near-identical past questions; tighter extraction (`MemoryExtractor.durableFacts`) + de-dup; transient `com.apple.tokengeneration` errors mapped to retryable `ChatError.generationInterrupted` and retried once; `EmberLog` os.Logger diagnostics**) → **EmbeddingGemma embedder: EmbeddingGemma-300m on Core ML (256-dim, role-aware) behind `TextEmbedder`, dev-fetched weights (never committed) with automatic `NLEmbedding` fallback when unbundled, embedder-versioned vectors + chunked migration, and a real-model ship gate (`gemmaBeatsNLOnFixtures`)**. Plan 8 (hybrid lexical+semantic retrieval) shipped as part of Plan 10. **Phase 7 — EmberScope (built 2026-09-03; 112 EmberScope tests + 3 integration tests, all builds green)**: a netfox-style in-app inspector for Foundation Models as its own framework target (`InspectedSession`/`InspectedTool` wrappers, classified errors, per-entry context-window accounting, timeline, JSON/Markdown export, `OSLogSink`), wired through `FoundationModelProvider`, the utility sessions and the engine's notes, with every app surface `#if DEBUG` — spec `docs/superpowers/specs/2026-09-02-emberscope-foundation-models-inspector-design.md`, plan `docs/superpowers/plans/2026-09-02-emberscope-foundation-models-inspector.md`, library README `Targets/EmberScope/README.md`. See `README.md`.

## How this project is built

Superpowers flow per feature: **brainstorm → spec → writing-plans → subagent-driven TDD** (fresh implementer per task, spec-then-quality review gate, red→green→commit), one branch + PR per plan. Ground Foundation Models / NaturalLanguage API details in Apple docs (sosumi `fetchAppleDocumentation`), never assumptions.
