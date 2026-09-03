import Foundation
import FoundationModels
import Synchronization

/// A `LanguageModelSession` that records what it does. Same API shape as the SDK class (create it the same
/// way, call `respond` / `streamResponse` the same way, read `transcript` / `isResponding`), same return
/// types. Every error is recorded and rethrown unchanged. When the recorder is inactive, calls forward
/// directly with no bookkeeping.
public final class InspectedSession: Sendable {
    public let id: UUID
    public let label: String
    /// The wrapped SDK session (escape hatch).
    public let base: LanguageModelSession
    public let model: SystemLanguageModel
    /// The tools handed to the SDK — already wrapped in `InspectedTool` when created through the
    /// convenience initializers; whatever the caller supplied when wrapping an existing session.
    public let tools: [any Tool]
    let recorder: ScopeRecorder
    let observer: RequestObserver
    let resolver: TokenCountResolver
    /// Spec §7: at most ONE exact-count resolve in flight per session — a newer snapshot cancels the
    /// older one, whose result would be stale anyway. `Mutex` is `~Copyable`, so nothing may capture
    /// it; `snapshotTranscript` swaps the task out under the lock and cancels the previous one after.
    private let inFlightResolve = Mutex<Task<Void, Never>?>(nil)

    public var transcript: Transcript { base.transcript }
    public var isResponding: Bool { base.isResponding }

    /// Wrap an existing session. Tool calls are then visible only through the transcript (the tools are
    /// already bound inside `base`); use a convenience initializer for live tool telemetry.
    public init(wrapping base: LanguageModelSession, model: SystemLanguageModel = .default, tools: [any Tool] = [],
                label: String? = nil, recorder: ScopeRecorder = EmberScope.recorder,
                counter: (any TokenCounting)? = nil, id: UUID = UUID(), restoredFromTranscript: Bool = false) {
        self.id = id
        self.label = label ?? "session"
        self.base = base
        self.model = model
        self.tools = tools
        self.recorder = recorder
        // No `progressInterval:` — the observer reads the recorder's CURRENT configuration per chunk,
        // so a later `EmberScope.start(configuration:)` takes effect on sessions that already exist.
        self.observer = RequestObserver(recorder: recorder, sessionID: id)
        self.resolver = TokenCountResolver(counter: counter ?? SystemTokenCounter(model: model), recorder: recorder)
        recordCreation(restoredFromTranscript: restoredFromTranscript)
    }

    public convenience init(model: SystemLanguageModel = .default, tools: [any Tool] = [],
                            instructions: Instructions? = nil, label: String? = nil,
                            recorder: ScopeRecorder = EmberScope.recorder, counter: (any TokenCounting)? = nil) {
        let id = UUID()
        let wrapped = EmberScope.wrap(tools, sessionID: id, recorder: recorder)
        let base = LanguageModelSession(model: model, tools: wrapped, instructions: instructions)
        self.init(wrapping: base, model: model, tools: wrapped, label: label, recorder: recorder,
                  counter: counter, id: id, restoredFromTranscript: false)
    }

    @_disfavoredOverload
    public convenience init(model: SystemLanguageModel = .default, tools: [any Tool] = [],
                            instructions: String? = nil, label: String? = nil,
                            recorder: ScopeRecorder = EmberScope.recorder, counter: (any TokenCounting)? = nil) {
        let id = UUID()
        let wrapped = EmberScope.wrap(tools, sessionID: id, recorder: recorder)
        let base = LanguageModelSession(model: model, tools: wrapped, instructions: instructions)
        self.init(wrapping: base, model: model, tools: wrapped, label: label, recorder: recorder,
                  counter: counter, id: id, restoredFromTranscript: false)
    }

    public convenience init(model: SystemLanguageModel = .default, tools: [any Tool] = [],
                            transcript: Transcript, label: String? = nil,
                            recorder: ScopeRecorder = EmberScope.recorder, counter: (any TokenCounting)? = nil) {
        let id = UUID()
        let wrapped = EmberScope.wrap(tools, sessionID: id, recorder: recorder)
        let base = LanguageModelSession(model: model, tools: wrapped, transcript: transcript)
        self.init(wrapping: base, model: model, tools: wrapped, label: label, recorder: recorder,
                  counter: counter, id: id, restoredFromTranscript: true)
    }

    // MARK: Forwarded API

    public func prewarm(promptPrefix: Prompt? = nil) {
        base.prewarm(promptPrefix: promptPrefix)
        recorder.record(.prewarm, sessionID: id)
    }

    @discardableResult
    nonisolated(nonsending) public func respond(to prompt: Prompt, options: GenerationOptions = GenerationOptions()) async throws
        -> LanguageModelSession.Response<String> {
        guard recorder.isActive else { return try await base.respond(to: prompt, options: options) }
        let handle = begin(kind: .respond, prompt: nil, options: options, responseFormat: nil, includeSchema: nil)
        do {
            let response = try await base.respond(to: prompt, options: options)
            finish(handle, output: response.content, entries: response.transcriptEntries)
            return response
        } catch { fail(handle, error: error); throw error }
    }

    @_disfavoredOverload
    @discardableResult
    nonisolated(nonsending) public func respond(to prompt: String, options: GenerationOptions = GenerationOptions()) async throws
        -> LanguageModelSession.Response<String> {
        guard recorder.isActive else { return try await base.respond(to: prompt, options: options) }
        let handle = begin(kind: .respond, prompt: prompt, options: options, responseFormat: nil, includeSchema: nil)
        do {
            let response = try await base.respond(to: prompt, options: options)
            finish(handle, output: response.content, entries: response.transcriptEntries)
            return response
        } catch { fail(handle, error: error); throw error }
    }

    @discardableResult
    nonisolated(nonsending) public func respond<Content: Generable>(to prompt: Prompt, generating type: Content.Type = Content.self,
                                            includeSchemaInPrompt: Bool = true,
                                            options: GenerationOptions = GenerationOptions()) async throws
        -> LanguageModelSession.Response<Content> {
        guard recorder.isActive else {
            return try await base.respond(to: prompt, generating: type, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
        }
        let handle = begin(kind: .respond, prompt: nil, options: options,
                           responseFormat: String(describing: Content.self), includeSchema: includeSchemaInPrompt)
        do {
            let response = try await base.respond(to: prompt, generating: type, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
            finish(handle, output: Self.outputText(response), entries: response.transcriptEntries)
            return response
        } catch { fail(handle, error: error); throw error }
    }

    @_disfavoredOverload
    @discardableResult
    nonisolated(nonsending) public func respond<Content: Generable>(to prompt: String, generating type: Content.Type = Content.self,
                                            includeSchemaInPrompt: Bool = true,
                                            options: GenerationOptions = GenerationOptions()) async throws
        -> LanguageModelSession.Response<Content> {
        guard recorder.isActive else {
            return try await base.respond(to: prompt, generating: type, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
        }
        let handle = begin(kind: .respond, prompt: prompt, options: options,
                           responseFormat: String(describing: Content.self), includeSchema: includeSchemaInPrompt)
        do {
            let response = try await base.respond(to: prompt, generating: type, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
            finish(handle, output: Self.outputText(response), entries: response.transcriptEntries)
            return response
        } catch { fail(handle, error: error); throw error }
    }

    @discardableResult
    nonisolated(nonsending) public func respond(to prompt: Prompt, schema: GenerationSchema, includeSchemaInPrompt: Bool = true,
                        options: GenerationOptions = GenerationOptions()) async throws
        -> LanguageModelSession.Response<GeneratedContent> {
        guard recorder.isActive else {
            return try await base.respond(to: prompt, schema: schema, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
        }
        let handle = begin(kind: .respond, prompt: nil, options: options, responseFormat: "GenerationSchema",
                           includeSchema: includeSchemaInPrompt)
        do {
            let response = try await base.respond(to: prompt, schema: schema, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
            finish(handle, output: response.rawContent.jsonString, entries: response.transcriptEntries)
            return response
        } catch { fail(handle, error: error); throw error }
    }

    @_disfavoredOverload
    @discardableResult
    nonisolated(nonsending) public func respond(to prompt: String, schema: GenerationSchema, includeSchemaInPrompt: Bool = true,
                        options: GenerationOptions = GenerationOptions()) async throws
        -> LanguageModelSession.Response<GeneratedContent> {
        guard recorder.isActive else {
            return try await base.respond(to: prompt, schema: schema, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
        }
        let handle = begin(kind: .respond, prompt: prompt, options: options, responseFormat: "GenerationSchema",
                           includeSchema: includeSchemaInPrompt)
        do {
            let response = try await base.respond(to: prompt, schema: schema, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
            finish(handle, output: response.rawContent.jsonString, entries: response.transcriptEntries)
            return response
        } catch { fail(handle, error: error); throw error }
    }

    public func streamResponse(to prompt: Prompt, options: GenerationOptions = GenerationOptions())
        -> sending InspectedResponseStream<String> {
        let handle = recorder.isActive
            ? begin(kind: .stream, prompt: nil, options: options, responseFormat: nil, includeSchema: nil) : nil
        return InspectedResponseStream(base: base.streamResponse(to: prompt, options: options), session: self, handle: handle)
    }

    @_disfavoredOverload
    public func streamResponse(to prompt: String, options: GenerationOptions = GenerationOptions())
        -> sending InspectedResponseStream<String> {
        let handle = recorder.isActive
            ? begin(kind: .stream, prompt: prompt, options: options, responseFormat: nil, includeSchema: nil) : nil
        return InspectedResponseStream(base: base.streamResponse(to: prompt, options: options), session: self, handle: handle)
    }

    public func streamResponse<Content: Generable>(to prompt: Prompt, generating type: Content.Type = Content.self,
                                                   includeSchemaInPrompt: Bool = true,
                                                   options: GenerationOptions = GenerationOptions())
        -> sending InspectedResponseStream<Content> {
        let handle = recorder.isActive
            ? begin(kind: .stream, prompt: nil, options: options, responseFormat: String(describing: Content.self),
                    includeSchema: includeSchemaInPrompt) : nil
        return InspectedResponseStream(
            base: base.streamResponse(to: prompt, generating: type, includeSchemaInPrompt: includeSchemaInPrompt, options: options),
            session: self, handle: handle)
    }

    @_disfavoredOverload
    public func streamResponse<Content: Generable>(to prompt: String, generating type: Content.Type = Content.self,
                                                   includeSchemaInPrompt: Bool = true,
                                                   options: GenerationOptions = GenerationOptions())
        -> sending InspectedResponseStream<Content> {
        let handle = recorder.isActive
            ? begin(kind: .stream, prompt: prompt, options: options, responseFormat: String(describing: Content.self),
                    includeSchema: includeSchemaInPrompt) : nil
        return InspectedResponseStream(
            base: base.streamResponse(to: prompt, generating: type, includeSchemaInPrompt: includeSchemaInPrompt, options: options),
            session: self, handle: handle)
    }

    public func streamResponse(to prompt: Prompt, schema: GenerationSchema, includeSchemaInPrompt: Bool = true,
                               options: GenerationOptions = GenerationOptions())
        -> sending InspectedResponseStream<GeneratedContent> {
        let handle = recorder.isActive
            ? begin(kind: .stream, prompt: nil, options: options, responseFormat: "GenerationSchema",
                    includeSchema: includeSchemaInPrompt) : nil
        return InspectedResponseStream(
            base: base.streamResponse(to: prompt, schema: schema, includeSchemaInPrompt: includeSchemaInPrompt, options: options),
            session: self, handle: handle)
    }

    @_disfavoredOverload
    public func streamResponse(to prompt: String, schema: GenerationSchema, includeSchemaInPrompt: Bool = true,
                               options: GenerationOptions = GenerationOptions())
        -> sending InspectedResponseStream<GeneratedContent> {
        let handle = recorder.isActive
            ? begin(kind: .stream, prompt: prompt, options: options, responseFormat: "GenerationSchema",
                    includeSchema: includeSchemaInPrompt) : nil
        return InspectedResponseStream(
            base: base.streamResponse(to: prompt, schema: schema, includeSchemaInPrompt: includeSchemaInPrompt, options: options),
            session: self, handle: handle)
    }

    @discardableResult
    public func logFeedbackAttachment(sentiment: LanguageModelFeedback.Sentiment?,
                                      issues: [LanguageModelFeedback.Issue] = [],
                                      desiredOutput: Transcript.Entry? = nil) -> Data {
        base.logFeedbackAttachment(sentiment: sentiment, issues: issues, desiredOutput: desiredOutput)
    }

    // MARK: Recording

    /// Record the current context window (estimated now, exact counts follow asynchronously on 26.4+).
    public func snapshotTranscript() {
        guard recorder.isActive else { return }
        let transcript = base.transcript
        let snapshot = TranscriptSnapshot.make(from: transcript, sessionID: id, contextSize: model.contextSize, tools: tools)
        recorder.record(.transcriptSnapshot(snapshot), sessionID: id)
        guard resolver.counter.supportsExactCounts else { return }
        let resolver = self.resolver
        let tools = self.tools
        // The task is created before the lock below is taken, so two genuinely concurrent snapshots whose
        // lock acquisitions invert relative to their `record` order could keep the older resolver alive.
        // Bounded and safe: the fold only applies counts whose snapshotID is the session's LATEST snapshot,
        // so the worst case is a turn that keeps its estimates. Request lifecycles are serialized in practice.
        let task = Task.detached(priority: .utility) {
            await resolver.resolve(snapshot: snapshot, transcript: transcript, tools: tools)
        }
        let previous = inFlightResolve.withLock { current -> Task<Void, Never>? in
            let previous = current
            current = task
            return previous
        }
        previous?.cancel()   // outside the lock: `cancel()` can run arbitrary cancellation handlers
    }

    private func recordCreation(restoredFromTranscript: Bool) {
        guard recorder.isActive else { return }
        let info = SessionInfo(label: label,
                               instructions: Self.instructionsText(in: base.transcript),
                               tools: tools.map { ToolInfo($0) },
                               contextSize: model.contextSize,
                               modelDescription: "SystemLanguageModel",
                               restoredFromTranscript: restoredFromTranscript)
        recorder.record(.sessionCreated(info), sessionID: id)
        snapshotTranscript()
    }

    private func begin(kind: RequestKind, prompt: String?, options: GenerationOptions, responseFormat: String?,
                       includeSchema: Bool?) -> RequestObserver.Handle {
        observer.start(kind: kind, prompt: prompt, options: options, responseFormat: responseFormat,
                       includeSchemaInPrompt: includeSchema, transcriptCount: base.transcript.count)
    }

    func finish(_ handle: RequestObserver.Handle, output: String?, entries: some Collection<Transcript.Entry>) {
        observer.finish(handle, output: output, resolvedPrompt: Self.promptText(in: entries),
                        transcriptCount: base.transcript.count)
        snapshotTranscript()
    }

    /// Streams do not hand back the appended entries; diff the transcript instead.
    func finishFromTranscript(_ handle: RequestObserver.Handle, output: String?) {
        let appended = Array(base.transcript.dropFirst(handle.transcriptCountAtStart))
        finish(handle, output: output, entries: appended)
    }

    func fail(_ handle: RequestObserver.Handle, error: any Error) {
        if error is CancellationError {
            observer.cancel(handle, transcriptCount: base.transcript.count)
        } else {
            observer.fail(handle, error: error, transcriptCount: base.transcript.count)
        }
        snapshotTranscript()
    }

    func cancel(_ handle: RequestObserver.Handle) {
        observer.cancel(handle, transcriptCount: base.transcript.count)
    }

    // MARK: Text extraction

    static func instructionsText(in transcript: Transcript) -> String? {
        for entry in transcript {
            if case .instructions(let i) = entry { return TranscriptRendering.text(of: i.segments) }
        }
        return nil
    }

    static func promptText(in entries: some Collection<Transcript.Entry>) -> String? {
        for entry in entries {
            if case .prompt(let p) = entry { return TranscriptRendering.text(of: p.segments) }
        }
        return nil
    }

    static func outputText<Content: Generable>(_ response: LanguageModelSession.Response<Content>) -> String {
        if let text = response.content as? String { return text }
        return response.rawContent.jsonString
    }

    static func outputText<Partial>(partial: Partial, raw: GeneratedContent) -> String {
        if let text = partial as? String { return text }
        return raw.jsonString
    }
}
