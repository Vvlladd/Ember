# EmberScope Example app — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `EmberScopeExample`, a minimal Foundation Models chat app that depends only on `EmberScope`, with a Scenarios menu that exercises every inspector path.

**Architecture:** One Tuist app target, one `@Observable` chat model owning an `InspectedSession`, three self-contained tools, a scenario enum, one SwiftUI screen, EmberScope hooks copied from `Ember`. No persistence, no FoundationChatKit.

**Tech Stack:** Swift 5 language mode, SwiftUI, FoundationModels, EmberScope, Tuist.

**Spec:** `docs/superpowers/specs/2026-09-04-emberscope-example-app-design.md` — the binding authority; every value below comes from it.

## Global Constraints

- The example target depends on `EmberScope` only; it never imports `FoundationChatKit`.
- Every EmberScope surface in the example is `#if DEBUG`, mirroring `Targets/Ember/Sources/EmberApp.swift`.
- No new public API in `EmberScope`; report a need instead of widening the surface.
- `tuist generate --no-open` after any file add/delete; xcodebuild is ground truth.
- Explicit `git add <paths>`; commit trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

### Task 1: Target skeleton that builds
**Files:** Modify `Project.swift`; Create `Targets/EmberScopeExample/Sources/ExampleApp.swift`, `ChatScreen.swift` (placeholder text).
- [ ] Add the `EmberScopeExample` target exactly as the spec's table says. `tuist generate --no-open`.
- [ ] `ExampleApp.swift` with `#if DEBUG EmberScope.start()`, `.emberScope()`, `EmberScopeCommands`, the macOS `Window` — copied from `EmberApp.swift` minus SwiftData/coordinator.
- [ ] Build on macOS and iOS Simulator (iPhone 17 Pro). Commit: `feat(example): EmberScopeExample target skeleton`.

### Task 2: Chat model, tools, generable
**Files:** Create `ChatModel.swift`, `Tools.swift`, `Generable.swift`.
- [ ] `CalculatorTool`, `ClockTool`, `FlakyTool` (always throws `ExampleToolError.simulatedFailure`), `CityFacts` as specified.
- [ ] `ChatModel` with `send`, `sendStructured`, `cancel`, `resetSession`, `refreshAvailability`, error capture, `lookFor`.
- [ ] Build both platforms. Commit: `feat(example): chat model, tools and structured output`.

### Task 3: Chat screen and scenarios
**Files:** Create `Scenarios.swift`; Modify `ChatScreen.swift`.
- [ ] `Scenario` enum with the eight cases, `title`/`prompt`/`lookFor`/`run(on:)`.
- [ ] `ChatScreen`: bubbles, composer, availability banner, error banner, "Look for" footer, toolbar (Scenarios menu, Cancel, Ember Scope button — `#if DEBUG`).
- [ ] Build both platforms; run the macOS app once (`open` the built product or ⌘R) and confirm the scope opens and a scenario records a session (failure path is fine on this Mac). Commit: `feat(example): chat screen and inspector scenarios`.

### Task 4: Docs and gates
**Files:** Modify `Targets/EmberScope/README.md`, `CLAUDE.md`, `README.md`, `CONTRIBUTING.md`.
- [ ] Docs exactly as the spec's Docs section lists.
- [ ] Run all gates from the spec; paste the tail lines into the report. Commit: `docs: EmberScope example app`.
