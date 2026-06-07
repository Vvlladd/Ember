# Contributing to Ember

Thanks for your interest in improving **Ember** — a privacy-first, fully on-device AI chat app built on Apple's Foundation Models framework. This guide covers how to build, test, and submit changes.

By participating you agree your contributions are licensed under the project's [MIT License](LICENSE).

---

## Guiding principles

These are non-negotiable for this project — please keep them in mind before opening a PR:

1. **On-device & private by design.** No network calls, **no network entitlement**, no third-party runtime dependencies. Embeddings use the system `NLEmbedding`; the model is Apple's on-device `SystemLanguageModel`. If a change would send data off-device, it doesn't belong here.
2. **All decision logic lives in the framework, behind a protocol seam.** `FoundationChatKit` must be unit-testable with `MockModelProvider`/`MockEmbedder` on any machine — *no Apple-Intelligence device required*. The `Ember` app target stays a thin SwiftUI binding layer.
3. **TDD, with granular commits.** Write a failing test, make it pass, refactor. Keep commits small and focused.
4. **Keep the app target compiling at every commit.** e.g. adding a `ChatError` case requires updating `ErrorBanner`'s exhaustive `switch` in the *same* change.

---

## Prerequisites

- **macOS 26 (Tahoe)** + **Xcode 26.x** (built against the 26.4 SDK).
- **[Tuist](https://docs.tuist.dev)** — the `.xcodeproj`/`.xcworkspace` are generated and git-ignored.
- To exercise the real on-device model: an Apple-Intelligence-capable device or an iOS 26 simulator with Apple Intelligence enabled. (Not required for the test suite.)

## Getting started

```bash
git clone https://github.com/Vvlladd/Ember.git
cd Ember
tuist generate            # creates Ember.xcworkspace (regenerate after any file add/delete)
open Ember.xcworkspace
```

> **Tuist resolves source globs at generation time.** Run `tuist generate --no-open` **after creating or deleting any source/test file** before you build or test, or the new file won't be in the module.

## Build & test

The framework test suite is the **primary gate** — all logic lives there:

```bash
# Framework unit tests (must print ** TEST SUCCEEDED **):
xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit \
  -destination 'platform=macOS' test 2>&1 | tail -40

# App builds (keep both green):
xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=macOS' build 2>&1 | tail -10
xcodebuild -workspace Ember.xcworkspace -scheme Ember \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -10
```

> **Editor diagnostics are unreliable here.** SourceKit shows false "No such module 'Testing'" / "cannot find type …" errors because there's no module graph in the editor. **Ground truth is the `xcodebuild` run** — trust it, not the squiggles.

## Project layout

- `Targets/FoundationChatKit/` — framework: engine, model seam, tools, memory/RAG, budgeting, persistence, and **all tests** (`Sources/`, `Tests/`).
- `Targets/Ember/` — SwiftUI app (views, `ErrorBanner`, inspector).
- `docs/superpowers/{specs,plans}/` — one design spec + one task-by-task plan per phase, grounded in Apple docs.
- `.claude/skills/` — reusable iOS/SwiftUI/Foundation-Models skills (also useful as house-style references).

## Conventions & hard-won gotchas

- **SwiftData:** use an explicit `ConversationStore(context: ModelContext(container))` — *not* `@Query`/`.modelContainer` (cross-module `@Model` + `mainContext` traps on macOS 26.x). Share **one** `ModelContext` between `ConversationStore` and `MemoryStore`.
- **Tools cost context.** Keep to **3–5 tools** with short `@Guide` descriptions; tool definitions are counted against the 4,096-token budget.
- **Exact token counts are async-only** (`SystemLanguageModel.tokenCount(for:)` is `async throws`); the live/typing path uses the char estimator and refreshes to exact counts after a turn.
- **Memory facts vs. messages:** durable curated `.note` facts are ranked above raw conversation snippets in retrieval (`search(preferNotes:)`). Prefer adding facts over indexing chatty messages.
- **Diagnostics:** the `EmberLog` (`os.Logger`) layer logs user-derived text at `.public` for debugging. If you add logging, keep privacy in mind and don't ship verbose user-text logging un-gated.

## Commit & PR guidelines

- **Commits:** imperative subject, focused scope, tests included. Use the project trailer:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  ```
  (only when an AI assistant co-authored the change).
- **Before opening a PR:** `tuist generate` is clean, the framework test suite is **green**, and both app targets **build**.
- **PR description:** what changed and why, how it was tested (paste the `TEST SUCCEEDED` tail), and any on-device verification. Reference the relevant spec/plan in `docs/superpowers/` when applicable.
- For larger features, follow the spec → plan → TDD flow used across the repo (see existing docs for the shape).

## Reporting issues

Open a GitHub issue with: what you expected, what happened, repro steps, device/OS (e.g. *iOS 26.5 simulator*), and any relevant `EmberLog` output (filter: `subsystem == "com.ember.FoundationChatKit"`).

---

Happy hacking — and thanks for keeping Ember on-device, private, and transparent. 🔥
