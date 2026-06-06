# Ember — Claude Code project guide

Ember is a **privacy-first, fully on-device AI chat app** for iOS / iPadOS / macOS 26, built on Apple's **Foundation Models** framework. It looks like Claude/Codex (conversation sidebar, streaming bubbles, composer) and adds a **transparency layer**: a Context inspector showing exactly what the model sees, and a token gauge against the 4,096-token window.

This file tells Claude Code how to work in this repo. Keep it accurate when things change.

---

## Build, test & run (ground truth)

Tooling: **Tuist** (project generation) + **Swift Testing** + **xcodebuild**. The `.xcodeproj`/`.xcworkspace` are generated and git-ignored.

```bash
# After creating/deleting ANY source file, regenerate before building/testing:
tuist generate --no-open

# Framework unit tests (all logic lives here; this is the primary gate):
xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40   # -> ** TEST SUCCEEDED **

# Build the app:
xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=macOS' build 2>&1 | tail -10
xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -10
```

- **SourceKit/editor diagnostics are unreliable here** ("No such module 'Testing'", "cannot find type …") — there is no module graph in the editor. **Ground truth is the xcodebuild run.** Trust it, not the squiggles.
- If a Bash command fails with a sandbox/permission error (not a real compile/test failure), retry it with `dangerouslyDisableSandbox: true`.
- To run/observe the app on the simulator, prefer the **`ios-debugger-agent`** skill (XcodeBuildMCP).

## Architecture

Two Tuist targets; **all decision logic is in the framework, behind a protocol seam, so it is unit-testable with a mock on any machine** (no Apple-Intelligence device required). The app target is thin SwiftUI binding.

- **`FoundationChatKit`** (framework, no UI) — `ConversationEngine` (`@Observable @MainActor` per-conversation view model), `ChatModelProvider`/`ChatSessionHandle` seam (`FoundationModelProvider` real + `MockModelProvider` test double), token budgeting, transcript projection, tools, conversation-memory RAG, overflow/compaction, SwiftData persistence (`Conversation`/`Message`/`ConversationStore`), and the app brain `ChatCoordinator`.
- **`Ember`** (SwiftUI app) — `RootView` (availability gate) → `ChatScene` (`NavigationSplitView` + toolbar gauge + `.inspector`), `ConversationListView`, `ChatView`/`MessageBubble`/`ComposerView`, `ContextInspectorView` + `TokenMeterView`.

**Patterns:** MVVM + `@Observable`; dependency injection via protocols; **dual-truth persistence** (durable `Message` rows + best-effort encoded `Transcript`); tools conform to FoundationModels `Tool` with `@Generable`/`@Guide`.

## Conventions & hard-won gotchas

- **Run `tuist generate --no-open` after any file add/delete** before xcodebuild (Tuist resolves source globs at generation time).
- **SwiftData:** use an explicit `ConversationStore(context: ModelContext(container))` — NOT `@Query`/`.modelContainer` (cross-module `@Model` + `mainContext` traps on macOS 26.x). Share **one** `ModelContext` between `ConversationStore` and `MemoryStore`.
- **Exact token counts are async-only:** `SystemLanguageModel.tokenCount(for:)` is `async throws`; the live/typing path uses the char estimator, and the engine refreshes to exact counts after a turn and on resume. `contextSize` is non-throwing.
- **Tools cost context** — keep to **3–5 tools**, short `@Guide` descriptions; tool definitions are counted as budget lines.
- **On-device / privacy-first ethos:** **no network capability or entitlement.** Embeddings use `NLEmbedding` (system framework). Keep it on-device.
- **Keep the app target compiling at every commit** — e.g. adding a `ChatError` case requires updating `ErrorBanner`'s exhaustive switch in the same change.
- **TDD, granular commits.** Commit trailer:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

## Project skills — invoke via the Skill tool when relevant

Reusable skills live in **`.claude/skills/`** (imported from `unPiRoomPlan`). Treat these as the house style for iOS/SwiftUI/Foundation Models work and **invoke the matching skill before doing that kind of task**:

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

> Project skills are auto-discovered by Claude Code; this table is the index of when each applies.

## Where things live

- **Specs:** `docs/superpowers/specs/` · **Plans:** `docs/superpowers/plans/` (one spec + one task-by-task plan per phase; grounded in Apple docs).
- **Roadmap status:** Phases 1–4 are **built** (streaming chat + gauge + inspector + history → tool calling + guided generation → conversation-memory RAG + advanced budgeting → **automatic retrieve-before-generate + embedder/snapshot caching + model-decided `saveMemory`**). See `README.md`.

## How this project is built

Superpowers flow per feature: **brainstorm → spec → writing-plans → subagent-driven TDD** (fresh implementer per task, spec-then-quality review gate, red→green→commit), one branch + PR per plan. Ground Foundation Models / NaturalLanguage API details in Apple docs (sosumi `fetchAppleDocumentation`), never assumptions.
