# Contributing to Ember

Thank you for helping improve Ember. Contributions of code, tests, documentation, design feedback, and reproducible bug reports are welcome.

By contributing, you agree that your contribution will be licensed under the project's [MIT License](LICENSE).

## Start here

- Use GitHub Issues for reproducible bugs and focused feature proposals.
- For substantial features or architecture changes, open an issue before implementation so the direction can be agreed first.
- Never attach private conversations or unredacted Ember logs to a public issue.
- Keep discussion constructive, specific, and welcoming.

## Project principles

These constraints define Ember and should be preserved by every contribution:

1. **Private and on-device by design.** Generation, retrieval, tools, and persistence stay on the device. Do not add cloud inference, analytics, tracking, remote storage, or a network entitlement without an explicit project-level design decision.
2. **Transparency is a product invariant.** Anything inserted into model context must be representable in the Context inspector and included exactly once in token accounting.
3. **Framework first.** Decision logic belongs in `FoundationChatKit` behind protocol seams. The `Ember` target should remain a thin SwiftUI binding layer.
4. **Graceful degradation.** The app must remain useful when Apple Intelligence, exact token counting, semantic embeddings, or optional EmbeddingGemma assets are unavailable.
5. **Test-driven changes.** Add a failing test, implement the smallest behavior that passes, then refactor. Keep the app buildable at each commit.
6. **Minimize dependencies.** New dependencies need a clear local-only purpose, license review, and an explanation of their binary and privacy impact.

## Prerequisites

- macOS 26 with Xcode 26.x and the iOS/macOS 26 SDK.
- [Tuist](https://docs.tuist.dev).
- Git.
- An Apple Intelligence environment only for real-model verification; unit tests use mocks.

## Set up a development checkout

```bash
git clone https://github.com/Vvlladd/Ember.git
cd Ember
tuist generate --no-open
open Ember.xcworkspace
```

Tuist resolves source globs during generation. After adding or deleting a source or test file, run:

```bash
tuist generate --no-open
```

Generated `.xcodeproj` and `.xcworkspace` files are intentionally gitignored and must not be committed.

## Development workflow

1. Fork the repository and create a focused branch from `main`.
2. Reproduce the problem or agree on the proposed behavior.
3. Add or update tests in `Targets/FoundationChatKit/Tests/` whenever logic changes, or in `Targets/EmberScope/Tests/` for inspector changes.
4. Implement the change behind the existing provider, session, embedder, or persistence seams.
5. Regenerate the project if the file graph changed.
6. Run the relevant tests and both app builds.
7. Update README, architecture documentation, or specs when behavior or constraints change.
8. Open a pull request describing what changed, why, and exactly how it was verified.

## Build and test matrix

The framework suite is the primary gate:

```bash
xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit \
  -destination 'platform=macOS' test 2>&1 | tail -40
```

The EmberScope inspector is a separate framework with its own suite and scheme:

```bash
xcodebuild -workspace Ember.xcworkspace -scheme EmberScope \
  -destination 'platform=macOS' test 2>&1 | tail -20
```

Keep both app targets green:

```bash
xcodebuild -workspace Ember.xcworkspace -scheme Ember \
  -destination 'platform=macOS' build 2>&1 | tail -10

xcodebuild -workspace Ember.xcworkspace -scheme Ember \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -10
```

The expected test result is `** TEST SUCCEEDED **`.

> [!IMPORTANT]
> SourceKit/editor diagnostics can report false missing-module or missing-type errors when the generated module graph is unavailable. `xcodebuild` is the source of truth.

## Optional EmbeddingGemma verification

The repository does not include model weights. A normal checkout builds and tests with the `NLEmbedding` fallback.

To exercise EmbeddingGemma locally, accept its separate license, authenticate with Hugging Face, and run `scripts/fetch_embeddinggemma.sh`. Assets are written to the gitignored `Targets/Ember/Resources/Models/` directory and must never be committed.

Run the real-model retrieval gate with:

```bash
TEST_RUNNER_EMBER_GEMMA_MODEL_DIR="$PWD/Targets/Ember/Resources/Models" \
xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit \
  -destination 'platform=macOS' test 2>&1 | tail -20
```

If you change tokenizer configuration, role prefixes, vector dimensions, or embedding normalization, treat it as a new vector space and update the embedder identity plus migration coverage.

## Code conventions

- Follow Swift 6 concurrency rules and preserve actor isolation. `ConversationEngine`, `ChatCoordinator`, and persistence/memory orchestration are intentionally main-actor isolated.
- Prefer small value types, protocol seams, dependency injection, and deterministic clocks/providers over global state.
- Keep Foundation Models tool descriptions short: tool schemas consume context tokens.
- Keep tool conformances pure and `Sendable`; route writes through the existing buffer/coordinator boundary.
- Use one shared `ModelContext` for `ConversationStore` and `MemoryStore`. Do not replace this with cross-module `@Query` or `.modelContainer` wiring.
- Update every exhaustive UI switch when adding an error or availability case.
- Preserve the distinction between durable `MemoryNote` facts and raw message snippets.
- Never compare vectors produced by different `embedderID` values.

## Privacy and logging

Treat prompts, replies, memories, titles, and extracted facts as sensitive user data.

- Do not add telemetry or upload logs.
- Prefer metadata such as lengths, counts, and stable error categories over content.
- Do not add new `privacy: .public` interpolation for user-derived strings.
- EmberScope records everything in memory only, logs metadata-only to the unified log by default, and is surfaced from the app exclusively behind `#if DEBUG`. Keep all three properties: no disk or network writes, no content in the log unless the developer opts in, and no inspector in a Release build.
- Redact any log excerpt before posting it publicly.
- If your work touches the existing verbose memory diagnostics, move it toward explicit debug gating or private/redacted interpolation.

## Documentation and diagrams

- Keep the checked-in Mermaid sources valid, regenerate their README PNG exports, and visually inspect the results; follow [`docs/diagrams/README.md`](docs/diagrams/README.md).
- Update [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) when changing system boundaries or context-window behavior.
- Keep public documentation factual about privacy, optional model assets, linked dependencies, and known limitations.
- Add alt text for images and concise prose around diagrams so the documentation remains accessible.

## Commits

- Use an imperative, focused subject line.
- Keep unrelated refactors out of feature commits.
- Include tests with the behavior they protect.
- If an AI assistant materially co-authored a commit, use the applicable co-author trailer and disclose the assistance in the pull request. Contributors remain responsible for understanding and reviewing all submitted code.

## Pull request checklist

- [ ] The change has a focused purpose and references an issue or design discussion when appropriate.
- [ ] New behavior is covered by tests, or the PR explains why tests do not apply.
- [ ] `tuist generate --no-open` was rerun after file additions or deletions.
- [ ] The `FoundationChatKit` test suite succeeds, and the `EmberScope` suite too when the inspector changed.
- [ ] The macOS app builds.
- [ ] The iOS Simulator app builds.
- [ ] Real-device/model behavior was verified when the change depends on it.
- [ ] User-facing or architectural documentation was updated.
- [ ] No generated project, model weights, private conversations, tokens, or unredacted logs are included.
- [ ] New dependencies and assets have compatible licenses and documented privacy impact.

## Reporting bugs and security issues

For a normal bug, include expected behavior, actual behavior, reproduction steps, OS/device details, and a minimal redacted log excerpt when useful.

For a vulnerability or privacy issue, avoid publishing exploit details or user data. Use GitHub's private vulnerability reporting when available, or contact the maintainer at `vlad@unpi.dev`.

Thank you for keeping Ember private, transparent, and approachable. 🔥
