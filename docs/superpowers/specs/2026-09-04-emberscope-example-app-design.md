# EmberScope Example app — design

**Date:** 2026-09-04 · **Status:** approved in chat, implementing · **Parent:** `2026-09-02-emberscope-foundation-models-inspector-design.md` (the library)

## Goal

A minimal Foundation Models chat app, `EmberScopeExample`, whose only job is to host EmberScope and let a developer see it working correctly in minutes — the role netfox's example project plays. It must depend on **`EmberScope` alone** (never on `FoundationChatKit`): that dependency shape proves the library drops into any Foundation Models app, and the app shows the minimal integration the library README prescribes, in about ten lines.

## Non-goals

No persistence, no memory/RAG, no conversation list, no Markdown rendering, no settings, no tests of the demo UI itself (the gate is that it builds on macOS and the iOS Simulator and that the library suite stays green). No new public API in `EmberScope`; if the example needs something the library does not expose, that is a finding to report, not a reason to widen the API silently.

## Target

`Project.swift` gains one target, modelled on `Ember`:

| Field | Value |
|---|---|
| name / product | `EmberScopeExample` / `.app` |
| bundleId | `dev.iosunpi.emberscope.example` |
| destinations / deployment | `appDestinations` / `deployment` (iPhone, iPad, Mac; 26.0) |
| sources | `Targets/EmberScopeExample/Sources/**` |
| infoPlist | `.extendingDefault(with:)` — `CFBundleDisplayName` "EmberScope Example", `CFBundleShortVersionString` "0.1", `CFBundleVersion` "1", `LSApplicationCategoryType` developer-tools, `UILaunchScreen: [:]` |
| dependencies | `[.target(name: "EmberScope")]` — nothing else |
| settings | none beyond the project defaults (Swift 5 language mode like `Ember`; the example is a host, not the library) |

No resources directory is needed. Everything else in `Project.swift` is untouched.

## Files (`Targets/EmberScopeExample/Sources/`)

- `ExampleApp.swift` — `@main` App. `init()` calls `EmberScope.start()` inside `#if DEBUG`. `WindowGroup { ChatScreen(model: model).emberScope() }` (the modifier attached **once**). `.commands { EmberScopeCommands { … } }` and, on macOS, a `Window("Ember Scope", id: "emberscope") { EmberScopeView() }` opened by the commands and the toolbar button — mirror `Targets/Ember/Sources/EmberApp.swift` exactly, including the `#if DEBUG` gating of every EmberScope surface. In Release the app is a plain chat.
- `ChatModel.swift` — `@Observable @MainActor final class ChatModel`. Owns `session: InspectedSession` created by `EmberScope.session(tools: [CalculatorTool(), ClockTool(), FlakyTool()], instructions: Self.instructions, label: "example")`. State: `messages: [ChatMessage]` (`id`, `role` user/assistant, `text`), `isResponding`, `errorText: String?`, `availability: SystemLanguageModel.Availability` (read once at init from `SystemLanguageModel.default.availability`, refreshed by `refreshAvailability()`), `lookFor: String?` (the current scenario's hint). Methods: `send(_ text: String)` streams with `for try await snapshot in session.streamResponse(to: text)` (the `String` overload, so the prompt is captured up front) and replaces the trailing assistant bubble with `snapshot.content`; `sendStructured()` calls `session.respond(to:generating: CityFacts.self)` and renders the result as text; `cancel()` cancels the in-flight `Task`; `resetSession()` replaces `session` with a fresh one (a new session row in the scope). Every error is caught, its `String(describing:)` shown in `errorText`, and the turn ends — the scope shows the classified version. Sending is allowed even when the model is unavailable: the failure path is part of what the example demonstrates.
- `Tools.swift` — three self-contained tools, no dependency on Ember's: `CalculatorTool` (`name` "calculator"; `@Generable Arguments { @Guide expression: String }`; evaluates with `NSExpression(format:)` inside a `do/catch`-style guard and returns a short corrective string on failure rather than throwing); `ClockTool` (`name` "clock"; no meaningful arguments beyond an optional `@Guide timeZone: String?`; returns the current date and time formatted); `FlakyTool` (`name` "flaky"; `@Guide input: String`; **always throws** `ExampleToolError.simulatedFailure(input)` — it exists to show a tool error plus the request error that carries it).
- `Generable.swift` — `@Generable struct CityFacts { @Guide(description:) name: String; country: String; @Guide(.range(1...50_000_000)) population: Int; oneLineFact: String }`.
- `Scenarios.swift` — `enum Scenario: CaseIterable, Identifiable` with `title`, `prompt`, `lookFor` (one sentence naming what the developer should see in the console) and `run(on model: ChatModel)`. Cases: **calculator** ("What is 4892 * 1773? Use the calculator." → a `calculator` tool-call row with its duration under the request), **clock** ("What time is it right now? Use the clock tool." → a `clock` tool call), **longAnswer** ("Explain how an on-device language model manages a 4,096-token context window, in five short paragraphs." → chunk count and time-to-first-token on the request; the context bar grows), **cancelMidStream** (sends the long prompt and cancels after the first snapshot → a cancelled request row), **structured** (`sendStructured()` → a request whose response format is `CityFacts`), **toolFailure** ("Call the flaky tool with the input 'demo'." → a tool error row and the request error that carries it), **overBudget** (a prompt of ~6,000 words built by repeating a paragraph → an over-budget context snapshot and an `exceededContextWindowSize` error), **newSession** (`resetSession()` → a second session row).
- `ChatScreen.swift` — `List`/`ScrollView` of bubbles (right-aligned user, left-aligned assistant, a progress indicator while responding), a composer (`TextField` + send button, disabled while responding, Return sends), an availability banner when the model is not `.available` (text from the `unavailable(reason)` case, e.g. "Apple Intelligence is not enabled"), an error banner showing `errorText` with a dismiss button, a footer line "Look for: …" after a scenario runs, and a toolbar with: a **Scenarios** `Menu` (one button per case, each with its `lookFor` as subtitle), a **Cancel** button while responding, and an **Ember Scope** button (`Label("Ember Scope", systemImage: "waveform.path.ecg")`) that calls `EmberScope.present()` on iOS and opens the window on macOS — all `#if DEBUG`.

## Behaviour to verify by hand (the "does it work" checklist, also in the README)

1. Launch → the availability banner reflects the machine (on a Mac without Apple Intelligence: shows the reason; on a device with it: no banner).
2. Run **calculator** → the reply contains 8,673,516 (with Apple Intelligence) and the scope shows session `example` with three tools, one request, one `calculator` tool call with a duration, and a context snapshot whose tool definitions sit inside the instructions entry.
3. Run **cancelMidStream** → a request with status cancelled and no error.
4. Run **toolFailure** → Errors tab shows a `toolCallFailed` error whose chain names `ExampleToolError`, linked to the request.
5. Run **overBudget** → the context bar turns red / "N over", and (with Apple Intelligence) an `exceededContextWindowSize` error.
6. **newSession** → two session rows; the older one keeps its history.
7. Without Apple Intelligence every scenario ends in the classified `assetsUnavailable` (or `unavailable`) error and the scope still shows the session, the prompt, the request and the context snapshot — the example works as a failure-path demo everywhere.

## Docs

- `Targets/EmberScope/README.md`: a new "## Example app" section right after Quick start — how to run (`tuist generate --no-open`, scheme `EmberScopeExample`, My Mac or an iOS simulator), the scenario table (scenario → what to look for), the checklist above, and the honest caveat that simulators and Macs without Apple Intelligence show the failure path only. Note that the example is a Tuist target in this repo and is not part of the extraction manifest (SwiftPM has no app targets); an extracted package would carry it as a separate Xcode project.
- `CLAUDE.md` (AGENTS.md follows): "Four Tuist targets" with an `EmberScopeExample` bullet; the build block gains `xcodebuild -workspace Ember.xcworkspace -scheme EmberScopeExample -destination 'platform=macOS' build 2>&1 | tail -10`; the gotcha that the example must never import `FoundationChatKit`.
- Root `README.md`: one sentence in the EmberScope section pointing at the example app, and the layout tree gains `Targets/EmberScopeExample/`.
- `CONTRIBUTING.md`: the example app build joins the matrix as "keep it building" (not the PR checklist).

## Gates

`tuist generate --no-open`; `xcodebuild -workspace Ember.xcworkspace -scheme EmberScopeExample -destination 'platform=macOS' build`; the same with `-destination 'platform=iOS Simulator,name=iPhone 17 Pro'`; `xcodebuild … -scheme EmberScope … test` (112 tests) and `… -scheme Ember -destination 'platform=macOS' build` still green (Project.swift changed).

## Decisions

- Depends only on `EmberScope` (proves host-agnosticism; keeps the demo honest about what an adopter writes).
- `FlakyTool` always throws — a deterministic tool-error path is worth one silly tool.
- No tests for the demo UI; the library's 112 tests already cover the recording pipeline the demo drives, and the demo's value is visual.
- Own branch and PR (`feat/emberscope-example-app` off `feat/emberscope-inspector`), so #9 stays reviewable as is.
