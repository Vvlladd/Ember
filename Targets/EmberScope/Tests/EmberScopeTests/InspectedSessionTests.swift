import Foundation
import FoundationModels
import Synchronization
import Testing
@testable import EmberScope

/// Blocks every count until released, so "one exact-count resolver at a time" is observable.
final class GatedTokenCounter: TokenCounting {
    private let open = Mutex(false)
    let supportsExactCounts = true
    func release() { open.withLock { $0 = true } }

    private func waitForRelease() async throws {
        for _ in 0..<20_000 {
            if Task.isCancelled { throw CancellationError() }
            if open.withLock({ $0 }) { return }
            await Task.yield()
        }
        throw TokenCountingError.unsupported   // never hang a test run
    }
    func count(entry: Transcript.Entry) async throws -> Int { try await waitForRelease(); return 7 }
    func count(tools: [any Tool]) async throws -> Int { try await waitForRelease(); return 11 }
}

struct InspectedSessionTests {
    private func recorder() -> ScopeRecorder {
        ScopeRecorder(configuration: ScopeConfiguration(isEnabled: true), isRecording: true)
    }
    private let noExact = MockTokenCounter(supportsExactCounts: false)

    private func kinds(_ r: ScopeRecorder) -> [String] {
        r.snapshot().map { e in
            switch e.payload {
            case .sessionCreated: return "created"
            case .prewarm: return "prewarm"
            case .requestStarted: return "start"
            case .streamProgress: return "progress"
            case .requestFinished: return "end"
            case .toolCallStarted, .toolCallFinished: return "tool"
            case .error: return "error"
            case .transcriptSnapshot: return "snapshot"
            case .tokenCountsResolved: return "counts"
            case .modelStatus: return "model"
            case .note: return "note"
            }
        }
    }

    @Test func creationRecordsSessionInfoAndInitialSnapshot() {
        let r = recorder()
        let session = InspectedSession(tools: [EchoTool()], instructions: "You are terse.", label: "test",
                                       recorder: r, counter: noExact)
        #expect(kinds(r) == ["created", "snapshot"])
        guard case .sessionCreated(let info) = r.snapshot()[0].payload else { Issue.record("no created"); return }
        #expect(info.label == "test")
        #expect(info.instructions == "You are terse.")
        #expect(info.tools.map(\.name) == ["echo"])
        #expect(info.tools[0].parametersJSON?.contains("\"text\"") == true)
        #expect(info.contextSize == SystemLanguageModel.default.contextSize)
        #expect(!info.restoredFromTranscript)
        guard case .transcriptSnapshot(let snap) = r.snapshot()[1].payload else { Issue.record("no snapshot"); return }
        #expect(snap.entries.map(\.kind) == [.instructions])
        #expect(snap.entries[0].toolDefinitions.map(\.name) == ["echo"])
        #expect(snap.sessionID == session.id)
        #expect(session.tools.allSatisfy { $0 is any InspectedToolMarker })
        #expect(session.transcript.count == 1)
        #expect(!session.isResponding)
        #expect(r.snapshot().allSatisfy { $0.sessionID == session.id })
    }

    @Test func wrappingAnExistingSessionRecordsCreation() {
        let r = recorder()
        let base = LanguageModelSession(instructions: "Plain")
        let session = InspectedSession(wrapping: base, label: "wrapped", recorder: r, counter: noExact)
        #expect(session.base === base)
        guard case .sessionCreated(let info) = r.snapshot()[0].payload else { Issue.record("no created"); return }
        #expect(info.label == "wrapped" && info.instructions == "Plain" && info.tools.isEmpty)
    }

    @Test func transcriptInitIsMarkedRestored() {
        let r = recorder()
        _ = InspectedSession(transcript: Fixtures.transcript(), label: "restored", recorder: r, counter: noExact)
        guard case .sessionCreated(let info) = r.snapshot()[0].payload,
              case .transcriptSnapshot(let snap) = r.snapshot()[1].payload else { Issue.record("shape"); return }
        #expect(info.restoredFromTranscript)
        #expect(snap.entries.count == 5)
    }

    @Test func defaultLabelAndPrewarm() {
        let r = recorder()
        let session = InspectedSession(recorder: r, counter: noExact)
        #expect(session.label == "session")
        session.prewarm()
        #expect(kinds(r).last == "prewarm")
    }

    /// Runs with or without Apple Intelligence: either the request succeeds or it fails with a classified
    /// error — both paths must leave a complete, ordered lifecycle behind.
    @Test func respondRecordsLifecycleAndSnapshot() async {
        let r = recorder()
        let session = InspectedSession(instructions: "Reply briefly.", label: "respond", recorder: r, counter: noExact)
        _ = try? await session.respond(to: "Say hi", options: GenerationOptions(maximumResponseTokens: 8))
        let k = kinds(r)
        let start = k.firstIndex(of: "start"), end = k.firstIndex(of: "end"), lastSnapshot = k.lastIndex(of: "snapshot")
        #expect(start != nil && end != nil && lastSnapshot != nil)
        #expect(start! < end! && end! < lastSnapshot!)
        guard case .requestStarted(let s) = r.snapshot()[start!].payload,
              case .requestFinished(let e) = r.snapshot()[end!].payload else { Issue.record("shape"); return }
        #expect(s.kind == .respond && s.prompt == "Say hi" && s.options.maximumResponseTokens == 8)
        #expect(e.requestID == s.requestID)
        if case .failed(let errorID) = e.status {
            let errors = r.snapshot().compactMap { if case .error(let rec) = $0.payload { return rec } else { return nil } }
            #expect(errors.contains { $0.id == errorID && $0.requestID == s.requestID })
        } else {
            #expect(e.status == .succeeded && (e.output?.isEmpty == false))
        }
    }

    @Test func streamRecordsLifecycleAndSnapshot() async {
        let r = recorder()
        let session = InspectedSession(label: "stream", recorder: r, counter: noExact)
        var chunks = 0
        do {
            for try await _ in session.streamResponse(to: "Say hi", options: GenerationOptions(maximumResponseTokens: 8)) { chunks += 1 }
        } catch { /* expected without Apple Intelligence */ }
        let k = kinds(r)
        guard let start = k.firstIndex(of: "start"), let end = k.firstIndex(of: "end") else { Issue.record("no lifecycle"); return }
        #expect(start < end)
        #expect(k.lastIndex(of: "snapshot")! > end)
        guard case .requestStarted(let s) = r.snapshot()[start].payload,
              case .requestFinished(let e) = r.snapshot()[end].payload else { Issue.record("shape"); return }
        #expect(s.kind == .stream)
        #expect(e.chunkCount == chunks)
    }

    @Test func guidedGenerationRecordsResponseFormat() async {
        let r = recorder()
        let session = InspectedSession(label: "guided", recorder: r, counter: noExact)
        _ = try? await session.respond(to: "Echo hi", generating: EchoTool.Arguments.self)
        guard case .requestStarted(let s)? = r.snapshot().first(where: { if case .requestStarted = $0.payload { return true } else { return false } })?.payload else {
            Issue.record("no start"); return
        }
        #expect(s.responseFormat == "Arguments")
        #expect(s.includeSchemaInPrompt == true)
    }

    @Test func droppedStreamIsRecordedAsCancelled() async {
        let r = recorder()
        let session = InspectedSession(label: "dropped", recorder: r, counter: noExact)
        do {
            let stream = session.streamResponse(to: "Say hi")
            _ = stream    // never iterated; goes out of scope here
        }
        // Give the finalizer's deinit a chance to run (it is synchronous once the last reference drops).
        let ends = r.snapshot().compactMap { if case .requestFinished(let e) = $0.payload { return e } else { return nil } }
        #expect(ends.count == 1)
        #expect(ends.first?.status == .cancelled)
    }

    @Test func inactiveRecorderIsPassThrough() async {
        let r = ScopeRecorder(configuration: ScopeConfiguration(isEnabled: true), isRecording: false)
        let session = InspectedSession(label: "quiet", recorder: r, counter: noExact)
        _ = try? await session.respond(to: "Say hi")
        #expect(r.snapshot().isEmpty)
    }

    /// Ruling (final review B4): `collect()` had no test at all, though it is the whole non-iterating
    /// half of the streaming API. Runs with or without Apple Intelligence.
    @Test func collectRecordsOneTerminalEventAndASnapshot() async {
        let r = recorder()
        let session = InspectedSession(label: "collect", recorder: r, counter: noExact)
        _ = try? await session.streamResponse(to: "Say hi", options: GenerationOptions(maximumResponseTokens: 8)).collect()
        let k = kinds(r)
        guard let start = k.firstIndex(of: "start"), let end = k.firstIndex(of: "end") else {
            Issue.record("no lifecycle"); return
        }
        #expect(start < end)
        #expect(k.filter { $0 == "end" }.count == 1)          // exactly one terminal event
        #expect(k.lastIndex(of: "snapshot")! > end)
        guard case .requestStarted(let s) = r.snapshot()[start].payload,
              case .requestFinished(let e) = r.snapshot()[end].payload else { Issue.record("shape"); return }
        #expect(s.kind == .stream && s.prompt == "Say hi")
        #expect(e.requestID == s.requestID)
        if case .failed = e.status {
            #expect(r.snapshot().contains { if case .error = $0.payload { return true } else { return false } })
        } else {
            #expect(e.status == .succeeded)
        }
    }

    /// Ruling (final review B5): the `schema:` streaming overloads were missing even though the SDK
    /// has both and EmberScope mirrors the `respond` pair.
    @Test func schemaStreamOverloadsRecordTheirResponseFormat() async {
        for prompt in ["String", "Prompt"] {
            let r = recorder()
            let session = InspectedSession(label: "schema-stream", recorder: r, counter: noExact)
            let schema = EchoTool.Arguments.generationSchema
            let stream = prompt == "String"
                ? session.streamResponse(to: "Echo hi", schema: schema)
                : session.streamResponse(to: Prompt("Echo hi"), schema: schema)
            _ = try? await stream.collect()
            let k = kinds(r)
            guard let start = k.firstIndex(of: "start"), let end = k.firstIndex(of: "end") else {
                Issue.record("no lifecycle for \(prompt)"); return
            }
            guard case .requestStarted(let s) = r.snapshot()[start].payload else { Issue.record("shape"); return }
            #expect(s.kind == .stream)
            #expect(s.responseFormat == "GenerationSchema")
            #expect(s.includeSchemaInPrompt == true)
            #expect(s.prompt == (prompt == "String" ? "Echo hi" : nil))
            #expect(k.filter { $0 == "end" }.count == 1)
            #expect(end > start)
        }
    }

    /// Ruling (final review B16): `respond(to:schema:)` must report the same format as its stream twin.
    @Test func respondWithSchemaRecordsGenerationSchemaFormat() async {
        let r = recorder()
        let session = InspectedSession(label: "schema", recorder: r, counter: noExact)
        _ = try? await session.respond(to: "Echo hi", schema: EchoTool.Arguments.generationSchema)
        guard let start = kinds(r).firstIndex(of: "start"),
              case .requestStarted(let s) = r.snapshot()[start].payload else { Issue.record("no start"); return }
        #expect(s.kind == .respond && s.responseFormat == "GenerationSchema")
    }

    /// Ruling (final review B16): breaking out of a stream mid-iteration must still produce exactly one
    /// terminal event. Without Apple Intelligence the stream throws before yielding, which is the other
    /// half of the same contract.
    @Test func breakingOutOfAStreamStillRecordsOneTerminalEvent() async {
        let r = recorder()
        let session = InspectedSession(label: "broken", recorder: r, counter: noExact)
        do {
            for try await _ in session.streamResponse(to: "Say hi", options: GenerationOptions(maximumResponseTokens: 8)) {
                break   // consumer walks away after the first snapshot
            }
        } catch { /* expected without Apple Intelligence */ }
        let ends = r.snapshot().compactMap { if case .requestFinished(let e) = $0.payload { return e } else { return nil } }
        #expect(ends.count == 1)
        #expect(ends.first?.status == .cancelled || ends.first?.status == .succeeded
                || { if case .failed = ends.first?.status { return true } else { return false } }())
    }

    /// Spec §7: one exact-count resolver at a time — a newer snapshot cancels the older resolve, whose
    /// answer would describe a transcript that no longer exists.
    @Test func onlyTheNewestSnapshotResolvesExactCounts() async {
        let r = recorder()
        let counter = GatedTokenCounter()
        // Instructions AND a tool, so every resolver has something to count and blocks on the gate.
        let session = InspectedSession(tools: [EchoTool()], instructions: "You are terse.", label: "resolve",
                                       recorder: r, counter: counter)                     // resolver #1
        session.snapshotTranscript()                                                      // #2 cancels #1
        session.snapshotTranscript()                                                      // #3 cancels #2
        counter.release()
        let snapshots = r.snapshot().compactMap { if case .transcriptSnapshot(let s) = $0.payload { return s } else { return nil } }
        #expect(snapshots.count == 3)
        func resolved() -> [TokenCounts] {
            r.snapshot().compactMap { if case .tokenCountsResolved(let c) = $0.payload { return c } else { return nil } }
        }
        for _ in 0..<10_000 where resolved().isEmpty { await Task.yield() }
        for _ in 0..<500 { await Task.yield() }        // let any straggler record before asserting
        #expect(resolved().count == 1)
        #expect(resolved().first?.snapshotID == snapshots.last?.id)
    }

    @Test func feedbackAttachmentForwards() {
        let session = InspectedSession(recorder: recorder(), counter: noExact)
        let data = session.logFeedbackAttachment(sentiment: .negative)
        #expect(data.count >= 0)
    }
}
