---
name: foundation-models-best-practices
description: Best practices for integrating Apple Foundation Models in iOS apps. Use when asked to design, implement, or review Foundation Models usage, including model selection, prompt design, safety/guardrails, async/await integration, performance, and privacy.
---

# Foundation Models Best Practices

## Goals

- Build safe, performant, and user-respecting features using Foundation Models.
- Prefer modern Swift patterns and strict concurrency compatibility.

## Workflow

### 1) Clarify scope and requirements

- Identify the feature, user value, and constraints (latency, offline, privacy).
- Determine the OS/version requirements and minimum deployment target.
- Confirm any data handling limitations or redaction needs.

### 2) Check availability and plan a fallback

- Always check `SystemLanguageModel.default.availability` before showing AI UI.
- Provide a deterministic fallback when Apple Intelligence is unavailable or not enabled.
- Handle `.modelNotReady` by retrying or suggesting the user wait for download to finish.

### 2) Choose the right model and API surface

- Select the model based on task type (classification, summarization, generation).
- Prefer the simplest model that meets quality and latency requirements.
- Keep model usage behind a small, testable abstraction.

### 3) Design prompts and outputs

- Use structured prompts with explicit instructions and constraints.
- Limit output variance with clear formatting expectations.
- Validate or normalize outputs before use.
- Keep prompts focused on a single task; break complex tasks into smaller prompts.
- Specify desired length (for example, single sentence) to reduce latency.

### 4) Prefer guided generation for structured output

- Use `@Generable` and `@Guide` to produce typed, constrained output.
- Keep guide descriptions short to reduce context size.
- Use dynamic schemas at runtime when the output options are data-driven.

### 4) Safety and privacy

- Avoid sending sensitive user data unless explicitly required.
- Redact personal data when possible.
- Provide clear user consent and affordances for AI-generated content.

### 5) Concurrency and performance

- Use async/await APIs and keep UI updates on @MainActor.
- Move model work off the main actor when possible.
- Cache results when appropriate; avoid duplicate requests.
- Reuse sessions for multi-turn flows; create a new session for single-turn requests.
- Respect the per-session context window (tokens from instructions, prompts, outputs).

### 6) Testing

- Unit test prompt construction and output parsing.
- Add deterministic fixtures for model outputs.
- Add integration tests for end-to-end flows when feasible.

## Implementation Notes

- Prefer @Observable models annotated with @MainActor for UI state.
- Use actors to guard shared, mutable state or caches.
- Avoid force unwraps and force try unless unrecoverable.
- Check `LanguageModelSession.isResponding` before sending another request.
- Use `GenerationOptions` to tune temperature and length for predictable results.

## Best-Practice Example (Structured Goals)

```swift
import FoundationModels

@Generable(description: "A weekly goal item")
struct GoalItem {
    @Guide(description: "Short, concrete goal title")
    var title: String
    @Guide(description: "One of: Health, Learning, Personal, Family, Work")
    var category: String
    @Guide(.range(15...600))
    var totalMinutes: Int
    @Guide(.range(15...120))
    var sessionLengthMinutes: Int
}

@Generable
struct GoalExtractionResult {
    @Guide(.count(1...6))
    var goals: [GoalItem]
}

let model = SystemLanguageModel.default
guard model.availability == .available else { /* fallback */ return }

let instructions = """
Extract weekly goals. Return only structured data.
If the input implies steps, split into multiple goals.
"""

let session = LanguageModelSession(model: model, instructions: instructions)
let prompt = "I want to become a better Swift developer."

let response = try await session.respond(
    to: prompt,
    generating: GoalExtractionResult.self,
    includeSchemaInPrompt: true
)
```

## Best-Practice Example (Tool Calling)

```swift
import FoundationModels

struct GoalHistoryTool: Tool {
    let name = "goalHistory"
    let description = "Finds recent goals for the current user."

    @Generable
    struct Arguments {
        @Guide(description: "The number of recent goals to return", .range(1...5))
        var limit: Int
    }

    func call(arguments: Arguments) async throws -> [String] {
        // Fetch from local storage or database; return short summaries.
        return ["Read Swift book", "Build SwiftUI demo", "Refactor networking layer"]
    }
}

let session = LanguageModelSession(
    tools: [GoalHistoryTool()],
    instructions: "Use goalHistory when recommending a new goal."
)

let response = try await session.respond(
    to: "Suggest a new learning goal based on my recent goals."
)
```

## References

- https://developer.apple.com/documentation/foundationmodels
