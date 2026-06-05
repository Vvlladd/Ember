# Ember — Plan 3 of N: Tool Calling & Guided Generation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Ember's on-device model the ability to call three pure tools (DateTime, Calculator, UnitConverter) and to produce a model-generated conversation title via guided generation — surfaced transparently in the Context inspector and token budget — without adding any network capability.

**Architecture:** Concrete `Tool`s live in `FoundationChatKit` (which already imports FoundationModels). The `ChatModelProvider`/`ChatSessionHandle` seam gains a `tools:` parameter; the real provider registers them with `LanguageModelSession(tools:…)`, the mock scripts tool interactions. Pure tool logic (especially arithmetic) is isolated for direct unit testing; guided-generation titles are encapsulated behind `generateTitle(forFirstExchange:)` so generics never touch the seam.

**Tech Stack:** Swift 6, FoundationModels, SwiftData, Tuist, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-06-05-ember-phase-2-tool-calling-design.md`

---

## Conventions for the executing engineer
- **Branch:** `plan-3-tools` (already created off `main`; the spec is already committed here).
- **TDD** for all `FoundationChatKit` logic (Milestones A–D). SwiftUI changes (E) are verified by **build**; Milestone F verifies by **running**.
- **Tuist:** after creating/deleting ANY file run `tuist generate --no-open` before building/testing.
- **Framework test command:**
  `xcodebuild -workspace Ember.xcworkspace -scheme FoundationChatKit -destination 'platform=macOS' test 2>&1 | tail -40` → expect `** TEST SUCCEEDED **`.
- **Build app (macOS):** `xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=macOS' build 2>&1 | tail -15`.
- **Build app (iOS):** `xcodebuild -workspace Ember.xcworkspace -scheme Ember -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -15`.
- Swift Testing (`import Testing`). `@testable import FoundationChatKit`. Sandbox failures → retry with Bash `dangerouslyDisableSandbox: true`; a real failure → report BLOCKED with output.
- SourceKit shows false "No such module 'Testing'"/"cannot find type" diagnostics in-editor — ground truth is the xcodebuild run.
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **Existing public API (do not break):** `ConversationEngine` (`messages`, `isResponding`, `budget`, `lastError`, `contextEntries`, `encodedTranscript`, `send`, `cancel`), `ChatModelProvider`/`ChatSessionHandle`, `FoundationModelProvider`, `ConversationStore`, `ChatCoordinator`, `TokenBudgetCalculator`, value types.

---

## File structure
```
Targets/FoundationChatKit/Sources/
  Tools/CalculatorEngine.swift        # NEW pure arithmetic evaluator (no FoundationModels)
  Tools/CalculatorTool.swift          # NEW Tool
  Tools/DateTimeTool.swift            # NEW Tool (injected clock)
  Tools/UnitConverterTool.swift       # NEW Tool (@Generable enum units)
  Tools/Toolbox.swift                 # NEW default tool set + ToolAccounting metadata
  Tools/ConversationTitler.swift      # NEW @Generable title via throwaway guided generation
  Tokens/TokenBudgetCalculator.swift  # MODIFY add tools: accounting lines
  Model/ChatError.swift               # MODIFY + toolFailed
  Provider/ChatModelProvider.swift    # MODIFY + TitleSeed, tools: on makeSession×2, generateTitle
  Provider/FoundationModelProvider.swift # MODIFY register tools; implement generateTitle; map ToolCallError
  Provider/TranscriptMapping.swift    # MODIFY render tool-call args as JSON
  Engine/ConversationEngine.swift     # MODIFY accept tools; pass to makeSession + budget; route toolFailed
  App/ChatCoordinator.swift           # MODIFY inject tools; first-exchange titling
  Persistence/ConversationStore.swift # MODIFY + setTitle(_:for:)
Targets/FoundationChatKit/Tests/
  CalculatorEngineTests.swift CalculatorToolTests.swift DateTimeToolTests.swift
  UnitConverterToolTests.swift ToolboxTests.swift ToolCallingEngineTests.swift
  ConversationTitlingTests.swift
  (extend) TokenBudgetCalculatorTests.swift, MockModelProvider.swift, ChatCoordinatorTests.swift
Targets/Ember/Sources/
  ErrorBanner.swift                   # MODIFY + toolFailed copy
  ContextInspectorView.swift          # MODIFY tool-row icon polish
```

---

## Milestone A — Tools (pure logic + `Tool` conformances)

No seam changes; these tasks only add new files, so the build/tests stay green throughout.

### Task A1: `CalculatorEngine` (pure arithmetic)

**Files:**
- Create: `Targets/FoundationChatKit/Sources/Tools/CalculatorEngine.swift`
- Test: `Targets/FoundationChatKit/Tests/CalculatorEngineTests.swift`

- [ ] **Step 1: Write the failing test**

`CalculatorEngineTests.swift`:
```swift
import Testing
@testable import FoundationChatKit

struct CalculatorEngineTests {
    let engine = CalculatorEngine()

    @Test func addition() throws { #expect(try engine.evaluate("2+2") == 4) }
    @Test func precedence() throws { #expect(try engine.evaluate("2 + 3 * 4") == 14) }
    @Test func parentheses() throws { #expect(try engine.evaluate("(2 + 3) * 4") == 20) }
    @Test func division() throws { #expect(try engine.evaluate("10 / 4") == 2.5) }
    @Test func unaryMinus() throws { #expect(try engine.evaluate("-5 + 2") == -3) }

    @Test func divisionByZeroThrows() {
        #expect(throws: CalculatorEngine.CalculatorError.divisionByZero) {
            try engine.evaluate("5 / 0")
        }
    }
    @Test func malformedThrows() {
        #expect(throws: CalculatorEngine.CalculatorError.malformedExpression) {
            try engine.evaluate("2 +")
        }
    }
    @Test func gibberishThrows() {
        #expect(throws: (any Error).self) { try engine.evaluate("abc") }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

`tuist generate --no-open`, then the framework test command. Expected: FAIL — `CalculatorEngine` not found.

- [ ] **Step 3: Implement `CalculatorEngine.swift`**

```swift
import Foundation

/// A small, dependency-free arithmetic evaluator: `+ - * /`, parentheses, decimals,
/// unary +/-. Precedence-correct recursive descent. No FoundationModels dependency so
/// it is trivially unit-testable.
public struct CalculatorEngine: Sendable {
    public enum CalculatorError: Error, Equatable {
        case malformedExpression
        case divisionByZero
    }

    public init() {}

    public func evaluate(_ expression: String) throws -> Double {
        var parser = Parser(expression)
        let value = try parser.parseExpression()
        try parser.expectEnd()
        return value
    }

    private struct Parser {
        let chars: [Character]
        var index = 0
        init(_ s: String) { chars = Array(s) }

        mutating func parseExpression() throws -> Double {     // + and -
            var value = try parseTerm()
            while let op = peekOperator(), op == "+" || op == "-" {
                advance()
                let rhs = try parseTerm()
                value = (op == "+") ? value + rhs : value - rhs
            }
            return value
        }

        mutating func parseTerm() throws -> Double {           // * and /
            var value = try parseFactor()
            while let op = peekOperator(), op == "*" || op == "/" {
                advance()
                let rhs = try parseFactor()
                if op == "/" {
                    guard rhs != 0 else { throw CalculatorError.divisionByZero }
                    value /= rhs
                } else {
                    value *= rhs
                }
            }
            return value
        }

        mutating func parseFactor() throws -> Double {
            skipSpaces()
            guard index < chars.count else { throw CalculatorError.malformedExpression }
            let c = chars[index]
            if c == "(" {
                advance()
                let value = try parseExpression()
                skipSpaces()
                guard index < chars.count, chars[index] == ")" else {
                    throw CalculatorError.malformedExpression
                }
                advance()
                return value
            }
            if c == "-" { advance(); return try -parseFactor() }
            if c == "+" { advance(); return try parseFactor() }
            return try parseNumber()
        }

        mutating func parseNumber() throws -> Double {
            skipSpaces()
            var digits = ""
            while index < chars.count, chars[index].isNumber || chars[index] == "." {
                digits.append(chars[index]); advance()
            }
            guard let value = Double(digits) else { throw CalculatorError.malformedExpression }
            return value
        }

        mutating func peekOperator() -> Character? {
            skipSpaces()
            guard index < chars.count else { return nil }
            let c = chars[index]
            return "+-*/".contains(c) ? c : nil
        }

        mutating func skipSpaces() { while index < chars.count, chars[index] == " " { advance() } }
        mutating func advance() { index += 1 }
        mutating func expectEnd() throws {
            skipSpaces()
            if index != chars.count { throw CalculatorError.malformedExpression }
        }
    }
}
```

- [ ] **Step 4: Run to verify all pass**

Framework test command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Targets/FoundationChatKit
git commit -m "feat(kit): pure CalculatorEngine arithmetic evaluator

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task A2: `CalculatorTool`

**Files:**
- Create: `Targets/FoundationChatKit/Sources/Tools/CalculatorTool.swift`
- Test: `Targets/FoundationChatKit/Tests/CalculatorToolTests.swift`

- [ ] **Step 1: Write the failing test**

`CalculatorToolTests.swift`:
```swift
import Testing
@testable import FoundationChatKit

struct CalculatorToolTests {
    @Test func evaluatesExpression() async throws {
        let tool = CalculatorTool()
        let result = try await tool.call(arguments: .init(expression: "(12.5/100)*80"))
        #expect(result == "10")
    }
    @Test func wholeNumbersHaveNoDecimal() async throws {
        let tool = CalculatorTool()
        #expect(try await tool.call(arguments: .init(expression: "2+2")) == "4")
    }
    @Test func malformedReturnsCorrectiveString() async throws {
        let tool = CalculatorTool()
        let result = try await tool.call(arguments: .init(expression: "2 +"))
        #expect(result.contains("Couldn't evaluate"))
    }
    @Test func metadata() {
        let tool = CalculatorTool()
        #expect(tool.name == "calculator")
        #expect(!tool.description.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

`tuist generate --no-open`, framework test command. Expected: FAIL — `CalculatorTool` not found.

- [ ] **Step 3: Implement `CalculatorTool.swift`**

```swift
import Foundation
import FoundationModels

/// A tool the model can call to evaluate arithmetic. Backed by the pure `CalculatorEngine`.
/// Malformed input returns a short corrective string (not a throw) so the model can recover.
public struct CalculatorTool: Tool {
    public let name = "calculator"
    public let description = "Evaluate an arithmetic expression with + - * / and parentheses."

    @Generable
    public struct Arguments {
        @Guide(description: "An arithmetic expression, e.g. (12.5/100)*80")
        public var expression: String
        public init(expression: String) { self.expression = expression }
    }

    private let engine = CalculatorEngine()
    public init() {}

    public func call(arguments: Arguments) async throws -> String {
        do {
            return Self.format(try engine.evaluate(arguments.expression))
        } catch {
            return "Couldn't evaluate '\(arguments.expression)'."
        }
    }

    /// Renders whole numbers without a trailing ".0".
    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        return String(value)
    }
}
```

- [ ] **Step 4: Run to verify all pass**

Framework test command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Targets/FoundationChatKit
git commit -m "feat(kit): CalculatorTool (Tool + @Generable args)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task A3: `DateTimeTool`

**Files:**
- Create: `Targets/FoundationChatKit/Sources/Tools/DateTimeTool.swift`
- Test: `Targets/FoundationChatKit/Tests/DateTimeToolTests.swift`

> Note: tests assert locale-independent substrings ("1970", our English note) to avoid flakiness.

- [ ] **Step 1: Write the failing test**

`DateTimeToolTests.swift`:
```swift
import Testing
import Foundation
@testable import FoundationChatKit

struct DateTimeToolTests {
    func toolAtEpoch() -> DateTimeTool {
        DateTimeTool(now: { Date(timeIntervalSince1970: 0) })
    }

    @Test func formatsForExplicitTimeZone() async throws {
        let result = try await toolAtEpoch().call(arguments: .init(timeZone: "UTC"))
        #expect(result.contains("1970"))
    }
    @Test func defaultsToDeviceLocal() async throws {
        let result = try await toolAtEpoch().call(arguments: .init(timeZone: nil))
        #expect(result.contains("19")) // year present
    }
    @Test func unknownTimeZoneFallsBackWithNote() async throws {
        let result = try await toolAtEpoch().call(arguments: .init(timeZone: "Not/AZone"))
        #expect(result.contains("unknown time zone"))
    }
    @Test func metadata() {
        #expect(toolAtEpoch().name == "currentDateTime")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

`tuist generate --no-open`, framework test command. Expected: FAIL — `DateTimeTool` not found.

- [ ] **Step 3: Implement `DateTimeTool.swift`**

```swift
import Foundation
import FoundationModels

/// A tool that returns the current date and time, optionally for a specific time zone.
/// The clock is injected so output is deterministic in tests.
public struct DateTimeTool: Tool {
    public let name = "currentDateTime"
    public let description = "Get the current date and time, optionally for a specific time zone."

    @Generable
    public struct Arguments {
        @Guide(description: "An IANA time zone like America/New_York. Omit for device local time.")
        public var timeZone: String?
        public init(timeZone: String? = nil) { self.timeZone = timeZone }
    }

    private let now: @Sendable () -> Date
    public init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

    public func call(arguments: Arguments) async throws -> String {
        var zone = TimeZone.current
        var note = ""
        if let id = arguments.timeZone, !id.isEmpty {
            if let tz = TimeZone(identifier: id) {
                zone = tz
            } else {
                note = " (unknown time zone '\(id)', showing device local time)"
            }
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        formatter.timeZone = zone
        return formatter.string(from: now()) + note
    }
}
```

- [ ] **Step 4: Run to verify all pass**

Framework test command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Targets/FoundationChatKit
git commit -m "feat(kit): DateTimeTool (injected clock)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task A4: `UnitConverterTool`

**Files:**
- Create: `Targets/FoundationChatKit/Sources/Tools/UnitConverterTool.swift`
- Test: `Targets/FoundationChatKit/Tests/UnitConverterToolTests.swift`

- [ ] **Step 1: Write the failing test**

`UnitConverterToolTests.swift`:
```swift
import Testing
@testable import FoundationChatKit

struct UnitConverterToolTests {
    @Test func kilometersToMiles() {
        let v = UnitConverterTool.convert(1, from: .kilometers, to: .miles)!
        #expect(abs(v - 0.621371) < 0.001)
    }
    @Test func celsiusToFahrenheit() {
        #expect(UnitConverterTool.convert(100, from: .celsius, to: .fahrenheit)! == 212)
        #expect(UnitConverterTool.convert(0, from: .celsius, to: .fahrenheit)! == 32)
    }
    @Test func kilogramsToPounds() {
        let v = UnitConverterTool.convert(1, from: .kilograms, to: .pounds)!
        #expect(abs(v - 2.20462) < 0.001)
    }
    @Test func crossDimensionIsNil() {
        #expect(UnitConverterTool.convert(1, from: .meters, to: .celsius) == nil)
    }
    @Test func callFormatsResult() async throws {
        let tool = UnitConverterTool()
        let result = try await tool.call(arguments: .init(value: 100, from: .celsius, to: .fahrenheit))
        #expect(result.contains("212"))
        #expect(result.contains("fahrenheit"))
    }
    @Test func callCrossDimensionIsCorrective() async throws {
        let tool = UnitConverterTool()
        let result = try await tool.call(arguments: .init(value: 1, from: .meters, to: .celsius))
        #expect(result.contains("different kinds of unit"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

`tuist generate --no-open`, framework test command. Expected: FAIL — `UnitConverterTool` not found.

- [ ] **Step 3: Implement `UnitConverterTool.swift`**

```swift
import Foundation
import FoundationModels

/// Converts a value between a small, honest set of length, mass, and temperature units.
/// Cross-dimension conversions return a corrective string instead of throwing.
public struct UnitConverterTool: Tool {
    public let name = "unitConverter"
    public let description = "Convert a value between units of length, mass, or temperature."

    @Generable
    public enum Unit: String {
        case meters, kilometers, miles, feet
        case kilograms, pounds
        case celsius, fahrenheit
    }

    @Generable
    public struct Arguments {
        @Guide(description: "The numeric value to convert")
        public var value: Double
        @Guide(description: "The unit to convert from")
        public var from: Unit
        @Guide(description: "The unit to convert to")
        public var to: Unit
        public init(value: Double, from: Unit, to: Unit) {
            self.value = value; self.from = from; self.to = to
        }
    }

    public init() {}

    public func call(arguments: Arguments) async throws -> String {
        guard let result = Self.convert(arguments.value, from: arguments.from, to: arguments.to) else {
            return "Can't convert \(arguments.from.rawValue) to \(arguments.to.rawValue) — they are different kinds of unit."
        }
        return "\(CalculatorTool.format(result)) \(arguments.to.rawValue)"
    }

    enum Dimension { case length, mass, temperature }
    static func dimension(of unit: Unit) -> Dimension {
        switch unit {
        case .meters, .kilometers, .miles, .feet: return .length
        case .kilograms, .pounds: return .mass
        case .celsius, .fahrenheit: return .temperature
        }
    }

    static func convert(_ value: Double, from: Unit, to: Unit) -> Double? {
        guard dimension(of: from) == dimension(of: to) else { return nil }
        switch dimension(of: from) {
        case .length:
            return fromMeters(toMeters(value, from), to)
        case .mass:
            let kg = (from == .kilograms) ? value : value * 0.45359237
            return (to == .kilograms) ? kg : kg / 0.45359237
        case .temperature:
            let celsius = (from == .celsius) ? value : (value - 32) * 5 / 9
            return (to == .celsius) ? celsius : celsius * 9 / 5 + 32
        }
    }

    private static func toMeters(_ v: Double, _ u: Unit) -> Double {
        switch u {
        case .meters: return v
        case .kilometers: return v * 1000
        case .miles: return v * 1609.344
        case .feet: return v * 0.3048
        default: return v
        }
    }
    private static func fromMeters(_ m: Double, _ u: Unit) -> Double {
        switch u {
        case .meters: return m
        case .kilometers: return m / 1000
        case .miles: return m / 1609.344
        case .feet: return m / 0.3048
        default: return m
        }
    }
}
```

- [ ] **Step 4: Run to verify all pass**

Framework test command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Targets/FoundationChatKit
git commit -m "feat(kit): UnitConverterTool (length/mass/temperature)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task A5: `ToolAccounting` + `Toolbox`

**Files:**
- Create: `Targets/FoundationChatKit/Sources/Tools/Toolbox.swift`
- Test: `Targets/FoundationChatKit/Tests/ToolboxTests.swift`

- [ ] **Step 1: Write the failing test**

`ToolboxTests.swift`:
```swift
import Testing
@testable import FoundationChatKit

struct ToolboxTests {
    @Test func defaultSetHasThreeUniquelyNamedTools() {
        let tools = Toolbox.defaultTools()
        #expect(tools.count == 3)
        let names = Set(tools.map(\.name))
        #expect(names == ["currentDateTime", "calculator", "unitConverter"])
    }
    @Test func accountingMetadataMirrorsTools() {
        let tools = Toolbox.defaultTools()
        let meta = Toolbox.accountingMetadata(for: tools)
        #expect(meta.count == 3)
        #expect(meta.allSatisfy { !$0.schemaDigest.isEmpty })
        #expect(meta.map(\.name) == tools.map(\.name))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

`tuist generate --no-open`, framework test command. Expected: FAIL — `Toolbox`/`ToolAccounting` not found.

- [ ] **Step 3: Implement `Toolbox.swift`**

```swift
import Foundation
import FoundationModels

/// Token-accounting metadata for one registered tool. Plain value type (no FoundationModels
/// dependency) so `TokenBudgetCalculator` can consume it.
public struct ToolAccounting: Sendable, Equatable {
    public let name: String
    public let schemaDigest: String   // the text the estimator counts (name + description + schema)
    public init(name: String, schemaDigest: String) {
        self.name = name
        self.schemaDigest = schemaDigest
    }
}

/// Assembles Ember's default tool set and derives token-accounting metadata.
public enum Toolbox {
    public static func defaultTools(now: @escaping @Sendable () -> Date = Date.init) -> [any Tool] {
        [DateTimeTool(now: now), CalculatorTool(), UnitConverterTool()]
    }

    public static func accountingMetadata(for tools: [any Tool]) -> [ToolAccounting] {
        tools.map { tool in
            ToolAccounting(
                name: tool.name,
                schemaDigest: tool.name + " " + tool.description + " " + String(describing: tool.parameters)
            )
        }
    }
}
```

- [ ] **Step 4: Run to verify all pass**

Framework test command. Expected: `** TEST SUCCEEDED **`. (≈ original 42 + new tool tests.)

- [ ] **Step 5: Commit**

```bash
git add Targets/FoundationChatKit
git commit -m "feat(kit): Toolbox default tool set + ToolAccounting metadata

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone B — Token accounting for tool definitions

### Task B1: `TokenBudgetCalculator` tool lines

**Files:**
- Modify: `Targets/FoundationChatKit/Sources/Tokens/TokenBudgetCalculator.swift`
- Test: `Targets/FoundationChatKit/Tests/TokenBudgetCalculatorTests.swift` (extend)

- [ ] **Step 1: Add the failing test**

Append to `TokenBudgetCalculatorTests.swift` (inside the existing test type):
```swift
    @Test func includesToolDefinitionLines() {
        let calc = TokenBudgetCalculator()
        let tools = [ToolAccounting(name: "calculator", schemaDigest: "calculator evaluate math expression")]
        let snapshot = calc.snapshot(
            maxTokens: 4096,
            instructions: "sys",
            entries: [ContextEntry(kind: .userPrompt, text: "hi")],
            inFlight: nil,
            tools: tools,
            exactCount: { _ in nil }
        )
        #expect(snapshot.lines.contains { $0.label == "Tool: calculator" })
        let toolLine = snapshot.lines.first { $0.label == "Tool: calculator" }!
        #expect(toolLine.tokens > 0)
        #expect(snapshot.usedTokens == snapshot.lines.reduce(0) { $0 + $1.tokens })
    }
```

- [ ] **Step 2: Run to verify it fails**

`tuist generate --no-open`, framework test command. Expected: FAIL — `snapshot(…tools:…)` has no `tools` parameter.

- [ ] **Step 3: Modify `snapshot` to accept tools**

In `TokenBudgetCalculator.swift`, change the `snapshot` signature and body. Replace the method signature line and insert the tool-line loop **after** the instructions line and **before** the entries loop:

Change the signature to:
```swift
    public func snapshot(
        maxTokens: Int,
        instructions: String?,
        entries: [ContextEntry],
        inFlight: String?,
        tools: [ToolAccounting] = [],
        exactCount: (String) -> Int?
    ) -> TokenBudgetSnapshot {
```

Then, immediately after the existing:
```swift
        if let instructions, !instructions.isEmpty {
            add("Instructions", instructions)
        }
```
insert:
```swift
        for tool in tools {
            add("Tool: \(tool.name)", tool.schemaDigest)
        }
```
(Leave the rest of the method unchanged. The defaulted `tools` keeps every existing caller compiling.)

- [ ] **Step 4: Run to verify all pass**

Framework test command. Expected: `** TEST SUCCEEDED **` (new test + all prior).

- [ ] **Step 5: Commit**

```bash
git add Targets/FoundationChatKit
git commit -m "feat(kit): tool-definition lines in token budget

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone C — Seam threading + providers

### Task C1: `ChatError.toolFailed` + `TitleSeed`

**Files:**
- Modify: `Targets/FoundationChatKit/Sources/Model/ChatError.swift`
- Modify: `Targets/FoundationChatKit/Sources/Provider/ChatModelProvider.swift`
- Test: `Targets/FoundationChatKit/Tests/SupportingTypesTests.swift` (extend)

- [ ] **Step 1: Add the failing test**

Append to `SupportingTypesTests.swift` (inside its test type):
```swift
    @Test func toolFailedIsEquatable() {
        #expect(ChatError.toolFailed(tool: "calculator", message: "x")
                == ChatError.toolFailed(tool: "calculator", message: "x"))
        #expect(ChatError.toolFailed(tool: "a", message: nil)
                != ChatError.toolFailed(tool: "b", message: nil))
    }
    @Test func titleSeedStoresExchange() {
        let seed = TitleSeed(userText: "u", assistantText: "a")
        #expect(seed.userText == "u")
        #expect(seed.assistantText == "a")
    }
```

- [ ] **Step 2: Run to verify it fails**

`tuist generate --no-open`, framework test command. Expected: FAIL — `toolFailed`/`TitleSeed` not found.

- [ ] **Step 3a: Add the `ChatError` case**

In `ChatError.swift`, add inside the enum (after `case cancelled`):
```swift
    case toolFailed(tool: String, message: String?)
```

- [ ] **Step 3b: Add `TitleSeed`**

At the top of `ChatModelProvider.swift` (after `import Foundation`, before the protocols), add:
```swift
/// A minimal seed for generating a conversation title from the first completed exchange.
public struct TitleSeed: Sendable, Equatable {
    public let userText: String
    public let assistantText: String
    public init(userText: String, assistantText: String) {
        self.userText = userText
        self.assistantText = assistantText
    }
}
```

- [ ] **Step 4: Run to verify all pass**

Framework test command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Targets/FoundationChatKit
git commit -m "feat(kit): ChatError.toolFailed + TitleSeed type

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task C2: Thread `tools:` through the seam, providers, and engine

This is the atomic signature change: protocol + mock + real provider + engine all move together so the module compiles.

**Files:**
- Modify: `Targets/FoundationChatKit/Sources/Provider/ChatModelProvider.swift`
- Modify: `Targets/FoundationChatKit/Sources/Provider/FoundationModelProvider.swift`
- Modify: `Targets/FoundationChatKit/Sources/Engine/ConversationEngine.swift`
- Modify: `Targets/FoundationChatKit/Tests/MockModelProvider.swift`
- Test: `Targets/FoundationChatKit/Tests/ToolCallingEngineTests.swift` (new)

> Before implementing, verify initializer names via the sosumi tool: `fetchAppleDocumentation /documentation/foundationmodels/languagemodelsession`. Confirmed at plan time: `init(model:tools:instructions:)` and `init(model:tools:transcript:)` exist (model defaults to `.default`).

- [ ] **Step 1: Write the failing test**

`ToolCallingEngineTests.swift`:
```swift
import Testing
import Foundation
@testable import FoundationChatKit

@MainActor
struct ToolCallingEngineTests {
    @Test func providerReceivesTools() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["ok"]
        let tools = Toolbox.defaultTools()
        let engine = ConversationEngine(provider: provider, tools: tools,
                                        now: { Date(timeIntervalSince1970: 0) })
        _ = engine
        #expect(provider.recordedTools.map(\.name) == tools.map(\.name))
    }

    @Test func surfacesScriptedToolCallAndOutputInOrder() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["42"]
        provider.session.scriptedToolInteractions = [(call: "calculator({\"expression\":\"6*7\"})", output: "42")]
        let engine = ConversationEngine(provider: provider, tools: Toolbox.defaultTools(),
                                        now: { Date(timeIntervalSince1970: 0) })
        await engine.send("what is 6*7")
        let kinds = engine.contextEntries.map(\.kind)
        #expect(kinds == [.userPrompt, .toolCall, .toolOutput, .modelResponse])
    }

    @Test func budgetIncludesToolLines() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["ok"]
        let engine = ConversationEngine(provider: provider, tools: Toolbox.defaultTools(),
                                        now: { Date(timeIntervalSince1970: 0) })
        await engine.send("hi")
        #expect(engine.budget.lines.contains { $0.label.hasPrefix("Tool: ") })
    }
}
```

- [ ] **Step 2: Run to verify it fails**

`tuist generate --no-open`, framework test command. Expected: FAIL — `ConversationEngine` has no `tools:` parameter / `recordedTools`/`scriptedToolInteractions` not found.

- [ ] **Step 3a: Update the protocols in `ChatModelProvider.swift`**

Add `import FoundationModels` under `import Foundation`. Replace the two `makeSession` requirements and add `generateTitle`:
```swift
    func makeSession(settings: GenerationSettings, tools: [any Tool], restoring encodedTranscript: Data?) -> any ChatSessionHandle
    /// Create a fresh session seeded with the given (already condensed) entries as its
    /// starting context. Used to recover from a context-window overflow.
    func makeSession(settings: GenerationSettings, tools: [any Tool], seeding entries: [ContextEntry]) -> any ChatSessionHandle
    /// Generate a short title from the first completed exchange via guided generation.
    /// Returns nil to fall back to the deterministic title.
    func generateTitle(forFirstExchange exchange: TitleSeed) async -> String?
```
(Leave `availability`, `maxContextTokens`, `tokenCount` unchanged.)

- [ ] **Step 3b: Update `FoundationModelProvider.swift`**

Change both `makeSession` methods to register tools and add `generateTitle`. Replace the two methods and add the new one:
```swift
    public func makeSession(settings: GenerationSettings, tools: [any Tool], restoring encodedTranscript: Data?) -> any ChatSessionHandle {
        let session: LanguageModelSession
        if let data = encodedTranscript,
           let transcript = try? JSONDecoder().decode(Transcript.self, from: data) {
            session = LanguageModelSession(tools: tools, transcript: transcript)
        } else if let instructions = settings.instructions {
            session = LanguageModelSession(tools: tools, instructions: instructions)
        } else {
            session = LanguageModelSession(tools: tools)
        }
        session.prewarm()
        return FoundationModelSession(session: session, settings: settings)
    }

    public func makeSession(settings: GenerationSettings, tools: [any Tool], seeding entries: [ContextEntry]) -> any ChatSessionHandle {
        let recap = entries.map { entry -> String in
            let speaker: String
            switch entry.kind {
            case .userPrompt: speaker = "User"
            case .modelResponse: speaker = "Assistant"
            case .instructions: speaker = "System"
            case .toolCall: speaker = "Tool call"
            case .toolOutput: speaker = "Tool output"
            }
            return "\(speaker): \(entry.text)"
        }.joined(separator: "\n")
        let combined: String?
        if recap.isEmpty {
            combined = settings.instructions
        } else {
            let base = settings.instructions.map { $0 + "\n\n" } ?? ""
            combined = base + "Summary of earlier conversation:\n" + recap
        }
        let session = combined.map { LanguageModelSession(tools: tools, instructions: $0) }
            ?? LanguageModelSession(tools: tools)
        session.prewarm()
        return FoundationModelSession(session: session, settings: settings)
    }

    public func generateTitle(forFirstExchange exchange: TitleSeed) async -> String? {
        await ConversationTitler.generate(from: exchange)
    }
```
Also extend `FoundationModelSession.map(_:)` to catch tool-call errors. Add this as the **first** check inside `map`, before the `GenerationError` cast:
```swift
        if let toolError = error as? LanguageModelSession.ToolCallError {
            return ChatError.toolFailed(tool: toolError.tool.name,
                                        message: String(describing: toolError.underlyingError))
        }
```

> `ConversationTitler` is created in Task C3. To keep this task compiling on its own, add a temporary stub now and replace it in C3. Create `Targets/FoundationChatKit/Sources/Tools/ConversationTitler.swift` with:
> ```swift
> import Foundation
> enum ConversationTitler { @MainActor static func generate(from seed: TitleSeed) async -> String? { nil } }
> ```

- [ ] **Step 3c: Update `MockModelProvider.swift`**

Add `import FoundationModels` at the top. On `MockSessionHandle`, add a scripted-interactions property and emit them on finish:
```swift
    /// Scripted (toolCallText, toolOutputText) pairs injected into contextEntries on finish.
    var scriptedToolInteractions: [(call: String, output: String)] = []
```
In `stream(...)`, inside the `if commits {` block, **before** appending the user/response entries, capture and append interactions. Replace the commit block with:
```swift
                if commits {
                    self.contextEntries.append(ContextEntry(kind: .userPrompt, text: prompt))
                    for interaction in self.scriptedToolInteractions {
                        self.contextEntries.append(ContextEntry(kind: .toolCall, text: interaction.call))
                        self.contextEntries.append(ContextEntry(kind: .toolOutput, text: interaction.output))
                    }
                    self.contextEntries.append(ContextEntry(kind: .modelResponse, text: snapshots.last ?? ""))
                }
```
On `MockModelProvider`, add stored state and update the two `makeSession` methods + add `generateTitle`:
```swift
    var recordedTools: [any Tool] = []
    var titleResult: String?
```
```swift
    func makeSession(settings: GenerationSettings, tools: [any Tool], restoring encodedTranscript: Data?) -> any ChatSessionHandle {
        recordedTools = tools
        return session
    }
    func makeSession(settings: GenerationSettings, tools: [any Tool], seeding entries: [ContextEntry]) -> any ChatSessionHandle {
        recordedTools = tools
        session.contextEntries = entries
        return session
    }
    func generateTitle(forFirstExchange exchange: TitleSeed) async -> String? { titleResult }
```

- [ ] **Step 3d: Update `ConversationEngine.swift`**

Add `import FoundationModels`. Add a `tools` init parameter, store tools + accounting, pass tools to `makeSession`, and pass accounting to the budget. Specifically:

Add stored properties (near the other `private let`s):
```swift
    private let tools: [any Tool]
    private let toolAccounting: [ToolAccounting]
```
Change the `init` signature to add `tools` (place it right after `restoringEntries`):
```swift
        restoringEntries: [ContextEntry]? = nil,
        tools: [any Tool] = [],
        persistence: ConversationPersistence? = nil,
```
At the top of the init body (before the `if let encodedTranscript` block) set:
```swift
        self.tools = tools
        self.toolAccounting = Toolbox.accountingMetadata(for: tools)
```
Update the three session-construction calls to pass `tools: tools`:
```swift
        if let encodedTranscript {
            self.session = provider.makeSession(settings: settings, tools: tools, restoring: encodedTranscript)
        } else if let restoringEntries, !restoringEntries.isEmpty {
            self.session = provider.makeSession(settings: settings, tools: tools, seeding: restoringEntries)
        } else {
            self.session = provider.makeSession(settings: settings, tools: tools, restoring: nil)
        }
```
In `recoverFromOverflow()`, update the seeding call:
```swift
        session = provider.makeSession(settings: settings, tools: tools, seeding: condensed)
```
In `recomputeBudget(inFlight:)`, pass the accounting into the calculator (add the `tools:` argument):
```swift
        budget = calculator.snapshot(
            maxTokens: providerRef.maxContextTokens,
            instructions: settings.instructions,
            entries: session.contextEntries,
            inFlight: inFlight,
            tools: toolAccounting,
            exactCount: { text in providerRef.tokenCount(for: text) }
        )
```

- [ ] **Step 4: Run to verify all pass**

Framework test command. Expected: `** TEST SUCCEEDED **` — the three new tool-calling tests pass and all prior tests still pass (engine `tools` defaulted to `[]` everywhere else).

- [ ] **Step 5: Commit**

```bash
git add Targets/FoundationChatKit
git commit -m "feat(kit): thread tools through provider seam + engine + budget

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task C3: Guided-generation titles (`ConversationTitler`)

**Files:**
- Modify (replace stub): `Targets/FoundationChatKit/Sources/Tools/ConversationTitler.swift`
- Test: `Targets/FoundationChatKit/Tests/ConversationTitlingTests.swift` (new) — provider-level mock test

> The real guided-generation call needs an Apple-Intelligence device, so it is exercised at runtime (Milestone F). The unit test here covers the **mock** path (scripted title) to lock the seam behavior; the real `ConversationTitler` is verified by build + run.

- [ ] **Step 1: Write the failing test**

`ConversationTitlingTests.swift`:
```swift
import Testing
import Foundation
@testable import FoundationChatKit

@MainActor
struct ConversationTitlingTests {
    @Test func mockProviderReturnsScriptedTitle() async {
        let provider = MockModelProvider()
        provider.titleResult = "Weekend Trip Planning"
        let title = await provider.generateTitle(
            forFirstExchange: TitleSeed(userText: "help me plan a trip", assistantText: "Sure!"))
        #expect(title == "Weekend Trip Planning")
    }
    @Test func mockProviderNilByDefault() async {
        let provider = MockModelProvider()
        let title = await provider.generateTitle(
            forFirstExchange: TitleSeed(userText: "hi", assistantText: "hello"))
        #expect(title == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Framework test command. Expected: FAIL — `titleResult`/`generateTitle` already exist from C2, so this test should actually PASS for the mock. If it passes, that's fine — proceed to replace the real `ConversationTitler` stub (the value of this task is the real implementation). If `ConversationTitlingTests.swift` is new, run `tuist generate --no-open` first.

- [ ] **Step 3: Replace `ConversationTitler.swift` with the real implementation**

```swift
import Foundation
import FoundationModels

/// Generates a short conversation title via guided generation, in a throwaway session so it
/// never pollutes the chat transcript. Returns nil on any failure (caller falls back to the
/// deterministic title).
enum ConversationTitler {
    @Generable
    struct ConversationTitle {
        @Guide(description: "A concise 3-5 word title for the conversation topic")
        var title: String
    }

    @MainActor
    static func generate(from seed: TitleSeed) async -> String? {
        let session = LanguageModelSession(
            instructions: "You write very short, descriptive chat titles. No quotes, 3-5 words.")
        let prompt = """
            Summarize this conversation's topic as a 3-5 word title.
            User: \(seed.userText)
            Assistant: \(seed.assistantText)
            """
        do {
            let response = try await session.respond(to: prompt, generating: ConversationTitle.self)
            let title = response.content.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : title
        } catch {
            return nil
        }
    }
}
```

- [ ] **Step 4: Run to verify all pass + build the app**

Framework test command → `** TEST SUCCEEDED **`. Then build macOS app (Conventions) to confirm the real guided-generation API compiles → `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Targets/FoundationChatKit
git commit -m "feat(kit): guided-generation conversation titles (ConversationTitler)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task C4: Render tool-call arguments as JSON in the inspector

**Files:**
- Modify: `Targets/FoundationChatKit/Sources/Provider/TranscriptMapping.swift`

> Build-verified (constructing `Transcript` tool entries in a unit test requires a model). The engine-level projection is already covered by C2's mock test; this only improves how the *real* provider renders tool-call args.

- [ ] **Step 1: Improve the tool-call rendering**

In `TranscriptMapping.swift`, replace the `.toolCalls` case body so arguments render as readable JSON when possible:
```swift
            case .toolCalls(let calls):
                let joined = calls.map { call -> String in
                    "\(call.toolName)(\(Self.argumentString(call.arguments)))"
                }.joined(separator: "\n")
                return ContextEntry(kind: .toolCall, text: joined)
```
Add a helper to the enum:
```swift
    private static func argumentString(_ content: GeneratedContent) -> String {
        let raw = String(describing: content)
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
```
> Note: `Transcript.ToolCall.arguments` is `GeneratedContent`. `String(describing:)` yields a JSON-like rendering; if the SDK exposes a cleaner accessor (verify via sosumi `/documentation/foundationmodels/generatedcontent`), prefer it. Keep the signature `argumentString(_:) -> String` either way.

- [ ] **Step 2: Build to verify**

`tuist generate --no-open`, then build macOS app and run framework tests. Expected: `** BUILD SUCCEEDED **` and `** TEST SUCCEEDED **` (no regressions).

- [ ] **Step 3: Commit**

```bash
git add Targets/FoundationChatKit
git commit -m "feat(kit): render tool-call arguments readably in the inspector

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone D — Coordinator titling

### Task D1: `ConversationStore.setTitle` + first-exchange titling

**Files:**
- Modify: `Targets/FoundationChatKit/Sources/Persistence/ConversationStore.swift`
- Modify: `Targets/FoundationChatKit/Sources/App/ChatCoordinator.swift`
- Test: `Targets/FoundationChatKit/Tests/ChatCoordinatorTests.swift` (extend)

- [ ] **Step 1: Write the failing tests**

Append to `ChatCoordinatorTests.swift` (inside the existing test type; it already has a `make()` helper returning `(ChatCoordinator, MockModelProvider)`):
```swift
    @Test func firstExchangeAppliesGeneratedTitle() async throws {
        let (coord, provider) = try make()
        provider.session.scriptedSnapshots = ["Sure, here's a plan."]
        provider.titleResult = "Weekend Trip Plan"
        coord.newConversation()
        await coord.send("help me plan a weekend trip")
        #expect(coord.conversations.first?.title == "Weekend Trip Plan")
    }

    @Test func nilTitleKeepsDeterministicTitle() async throws {
        let (coord, provider) = try make()
        provider.session.scriptedSnapshots = ["ok"]
        provider.titleResult = nil
        coord.newConversation()
        await coord.send("hello there friend")
        #expect(coord.conversations.first?.title == "hello there friend")
    }

    @Test func titleNotRegeneratedOnSecondTurn() async throws {
        let (coord, provider) = try make()
        provider.session.scriptedSnapshots = ["a"]
        provider.titleResult = "First Title"
        coord.newConversation()
        await coord.send("first message")
        provider.titleResult = "Second Title"
        await coord.send("second message")
        #expect(coord.conversations.first?.title == "First Title")
    }
```

- [ ] **Step 2: Run to verify it fails**

`tuist generate --no-open`, framework test command. Expected: FAIL — titles are still deterministic; `setTitle` not found.

- [ ] **Step 3a: Add `setTitle` to `ConversationStore.swift`**

After `updateResumeState(...)`:
```swift
    public func setTitle(_ title: String, for conversation: Conversation) {
        conversation.title = title
        try? context.save()
    }
```

- [ ] **Step 3b: Update `ChatCoordinator` to inject tools and apply the title**

In `makeEngine(for:)`, add tools to the engine init (place `tools:` right before `persistence:` to match the engine signature):
```swift
        return ConversationEngine(
            provider: provider,
            settings: settings,
            restoring: canUseTranscript ? convo.transcriptData : nil,
            restoringEntries: canUseTranscript ? nil : store.contextEntries(for: convo),
            tools: Toolbox.defaultTools(),
            persistence: persistence,
            now: now
        )
```
Replace the `send(_:)` method with one that captures first-exchange state and applies the generated title:
```swift
    public func send(_ text: String) async {
        guard let engine,
              let id = selectedID,
              let convo = conversations.first(where: { $0.id == id }) else { return }
        let isFirstExchange = convo.orderedMessages.isEmpty
        await engine.send(text)
        if isFirstExchange {
            let assistantText = engine.messages.last(where: { $0.role == .assistant })?.text ?? ""
            let seed = TitleSeed(userText: text, assistantText: assistantText)
            if let title = await provider.generateTitle(forFirstExchange: seed) {
                store.setTitle(title, for: convo)
            }
        }
        reload()   // title/updatedAt may have changed
    }
```

- [ ] **Step 4: Run to verify all pass**

Framework test command. Expected: `** TEST SUCCEEDED **` (≈ 42 original + all new tool/title tests).

- [ ] **Step 5: Commit**

```bash
git add Targets/FoundationChatKit
git commit -m "feat(kit): first-exchange guided titles + tool injection in coordinator

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone E — App UI polish (build-verified)

### Task E1: ErrorBanner `.toolFailed` + inspector tool-row icons

**Files:**
- Modify: `Targets/Ember/Sources/ErrorBanner.swift`
- Modify: `Targets/Ember/Sources/ContextInspectorView.swift`

- [ ] **Step 1: Add `.toolFailed` to `ErrorBanner.swift`**

The `message` switch is exhaustive over `ChatError`, so the new case must be handled. Add to the `switch error` in `ErrorBanner.message`:
```swift
        case .toolFailed(let tool, _): "The '\(tool)' tool failed. Try rephrasing."
```
(Place it alongside the other cases. `.modelUnavailable` and `.cancelled` are already handled.)

- [ ] **Step 2: Add a tool-row icon to `ContextInspectorView.swift`**

Give tool rows a distinct icon next to the role chip. In the `List(entries)` row `HStack(spacing: 6)`, before the `Text(label(entry.kind))`, add:
```swift
                        if entry.kind == .toolCall || entry.kind == .toolOutput {
                            Image(systemName: entry.kind == .toolCall ? "wrench.and.screwdriver" : "arrow.uturn.left")
                                .font(.caption2)
                                .foregroundStyle(color(entry.kind))
                        }
```
(`label(_:)` and `color(_:)` already handle `.toolCall`/`.toolOutput`.)

- [ ] **Step 3: Build both platforms**

`tuist generate --no-open`, build macOS + iOS (Conventions). Expected: `** BUILD SUCCEEDED **` on both.

- [ ] **Step 4: Commit**

```bash
git add Targets/Ember
git commit -m "feat(app): tool-failed banner copy + inspector tool-row icons

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone F — Run verification + finalize

### Task F1: Run, exercise a tool end-to-end, finalize

- [ ] **Step 1: Build + run on macOS, screenshot**

```bash
xcodebuild -workspace Ember.xcworkspace -scheme Ember -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/ember-dd-p3 build 2>&1 | tail -5
APP=$(find /tmp/ember-dd-p3/Build/Products -name "Ember.app" -maxdepth 3 | head -1)
open "$APP"
sleep 6
screencapture -x /tmp/ember-p3-macos.png
```
Verify the app launches (sidebar + empty state, or the unavailable screen if the model isn't ready — both valid). If it crashes, capture and report BLOCKED.

- [ ] **Step 2: Exercise a tool end-to-end on the iOS simulator**

Build, install, and launch on the simulator (the model has been `.available` on the iOS 26 sim historically — see Plan 2 outcome):
```bash
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null || true
xcodebuild -workspace Ember.xcworkspace -scheme Ember -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/ember-ios-p3 build 2>&1 | tail -5
APP=$(find /tmp/ember-ios-p3/Build/Products -name "Ember.app" -maxdepth 3 | head -1)
xcrun simctl install booted "$APP"
xcrun simctl launch booted dev.iosunpi.ember
sleep 6
xcrun simctl io booted screenshot /tmp/ember-p3-ios-launch.png
```
Then drive the UI to trigger a tool call (prefer the `xcodebuildmcp` tools when available: `describe_ui` to find the composer field, `tap`, `type_text` "what is 19 times 23?", tap Send, wait, `screenshot`; open the inspector's Context tab and screenshot the `.toolCall`/`.toolOutput` rows). 

Verify (best-effort, model permitting): the assistant answers 437, and the Context inspector shows a `calculator` tool call + output, with a `Tool: calculator` line in the Tokens tab. If the model declines to call the tool or is unavailable on the sim, record the observed behavior and the launch screenshot as the verification artifact, and note that on-device tool selection is model-dependent.

- [ ] **Step 3: Final commit + tag**

```bash
git commit --allow-empty -m "chore: Plan 3 complete — tool calling + guided-generation titles

Three pure on-device tools (DateTime/Calculator/UnitConverter) via the provider
seam; tool-definition token lines; tool calls/outputs surfaced in the Context
inspector; model-generated conversation titles with deterministic fallback.
No network capability added.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git tag plan-3-tools-complete
```

---

## Self-review (author check against spec)

**Spec coverage (spec §):**
- §1/§3 Architecture A (tools in kit, seam carries `[any Tool]`, mock scripts) → C2 (seam threading), A1–A5 (tools), `ToolCallingEngineTests`. ✓
- §1 three pure tools → A2 (Calculator), A3 (DateTime), A4 (UnitConverter), A1 (CalculatorEngine). ✓
- §1/§2.5 guided-generation titles → C3 (`ConversationTitler`) + D1 (coordinator applies, deterministic fallback). ✓
- §3/§4 seam `tools:` on both `makeSession` overloads + `generateTitle`/`TitleSeed` → C1 (TitleSeed), C2 (seam). ✓
- §6 tool-definition token lines → B1 (`TokenBudgetCalculator.tools:`) + engine wiring in C2. ✓
- §2.3/§9 tool calls/outputs in the inspector → already-mapped + C4 (JSON args) + E1 (icons). ✓
- §5/§8 `.toolFailed` + `ToolCallError` mapping → C1 (case) + C2 (`map`) + E1 (banner copy). ✓
- §5 no schema/network change → no `Project.swift`/entitlement edits in any task. ✓

**Placeholder scan:** No `TBD`/`TODO`. The only temporary stub (`ConversationTitler` in C2) is explicitly replaced in C3, in the same milestone chain.

**Type consistency:** `tools: [any Tool]` identical across protocol (C2), real provider (C2), mock (C2), engine init (C2), coordinator (D1). `ToolAccounting`/`schemaDigest` defined once (A5), consumed by `Toolbox.accountingMetadata` (A5) and `TokenBudgetCalculator.snapshot(tools:)` (B1) and engine (`toolAccounting`, C2). `generateTitle(forFirstExchange: TitleSeed) async -> String?` identical across protocol/real/mock (C1–C3) and call site (D1). `ChatError.toolFailed(tool:message:)` identical in C1/C2/E1. `CalculatorTool.format(_:)` defined in A2, reused by `UnitConverterTool` (A4). `UnitConverterTool.convert(_:from:to:)` signature identical in tests (A4) and `call` (A4).

**Ordering:** A (new files only, build stays green) → B (defaulted param, no call-site breaks) → C (atomic signature change across protocol+conformers+engine) → D (coordinator) → E (app build) → F (run). Each task ends green/committed.
