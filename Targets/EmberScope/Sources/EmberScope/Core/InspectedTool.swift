import Foundation
import FoundationModels

/// Lets `EmberScope.wrap` recognise tools that are already inspected.
protocol InspectedToolMarker {}

/// Wraps any `Tool`, forwarding its metadata and recording each call (arguments, output, duration,
/// failures) into a `ScopeRecorder`. The model sees exactly the same tool definition.
public struct InspectedTool<Base: Tool>: Tool, InspectedToolMarker {
    public typealias Arguments = Base.Arguments
    public typealias Output = Base.Output

    public let base: Base
    /// The `InspectedSession` this tool was registered with (nil when wrapped standalone).
    public let sessionID: UUID?
    let recorder: ScopeRecorder
    let now: @Sendable () -> Duration

    public init(_ base: Base, sessionID: UUID? = nil, recorder: ScopeRecorder = EmberScope.recorder) {
        // `MonotonicClock.now` as an unapplied reference is a non-Sendable function value: converting it
        // warns under strict concurrency (same as `Date.init` in `ScopeRecorder`). The closure literal
        // captures nothing and is identical in behaviour.
        self.init(base, sessionID: sessionID, recorder: recorder, now: { MonotonicClock.now() })
    }

    init(_ base: Base, sessionID: UUID?, recorder: ScopeRecorder, now: @escaping @Sendable () -> Duration) {
        self.base = base
        self.sessionID = sessionID
        self.recorder = recorder
        self.now = now
    }

    public var name: String { base.name }
    public var description: String { base.description }
    public var parameters: GenerationSchema { base.parameters }
    public var includesSchemaInInstructions: Bool { base.includesSchemaInInstructions }

    public func call(arguments: Arguments) async throws -> Output {
        guard recorder.isActive else { return try await base.call(arguments: arguments) }
        let callID = UUID()
        let started = now()
        recorder.record(.toolCallStarted(ToolCallStart(callID: callID, toolName: base.name,
                                                       arguments: ToolRendering.render(arguments))),
                        sessionID: sessionID)
        do {
            let output = try await base.call(arguments: arguments)
            recorder.record(.toolCallFinished(ToolCallEnd(callID: callID, toolName: base.name, status: .succeeded,
                                                          duration: now() - started,
                                                          output: ToolRendering.render(output))),
                            sessionID: sessionID)
            return output
        } catch {
            var record = ScopeErrorClassifier.classify(error, toolCallID: callID, toolName: base.name)
            if record.kind == .unknown { record.kind = .toolCallFailed }
            recorder.record(.error(record), sessionID: sessionID)
            recorder.record(.toolCallFinished(ToolCallEnd(callID: callID, toolName: base.name,
                                                          status: .failed(errorID: record.id),
                                                          duration: now() - started, output: nil)),
                            sessionID: sessionID)
            throw error
        }
    }
}

enum ToolRendering {
    /// Strings as-is, `@Generable`/`ConvertibleToGeneratedContent` values as JSON, anything else described.
    static func render<T>(_ value: T) -> String {
        if let text = value as? String { return text }
        if let convertible = value as? any ConvertibleToGeneratedContent { return convertible.generatedContent.jsonString }
        return String(describing: value)
    }
}

public extension EmberScope {
    /// Wrap every tool for live call telemetry. Order and names are preserved; already-inspected tools
    /// are returned untouched.
    static func wrap(_ tools: [any Tool], sessionID: UUID? = nil,
                     recorder: ScopeRecorder = EmberScope.recorder) -> [any Tool] {
        tools.map { wrapOne($0, sessionID: sessionID, recorder: recorder) }
    }

    private static func wrapOne(_ tool: some Tool, sessionID: UUID?, recorder: ScopeRecorder) -> any Tool {
        if tool is any InspectedToolMarker { return tool }
        return InspectedTool(tool, sessionID: sessionID, recorder: recorder)
    }
}

public extension Tool {
    /// `myTool.inspected()` — record this tool's calls.
    func inspected(sessionID: UUID? = nil, recorder: ScopeRecorder = EmberScope.recorder) -> InspectedTool<Self> {
        InspectedTool(self, sessionID: sessionID, recorder: recorder)
    }
}
