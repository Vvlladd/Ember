import Foundation
import FoundationModels
import Testing
@testable import EmberScope

/// Uses the process-wide recorder, so the suite is serialized and cleans up after itself.
@Suite(.serialized)
struct EmberScopeFacadeTests {
    private func reset() { EmberScope.stop(); EmberScope.clear() }

    private func kinds() -> [String] {
        EmberScope.recorder.snapshot().map { e in
            switch e.payload {
            case .modelStatus: return "model"
            case .sessionCreated: return "created"
            case .note: return "note"
            case .transcriptSnapshot: return "snapshot"
            default: return "other"
            }
        }
    }

    @Test func startEnablesRecordingAndCapturesModelStatus() {
        defer { reset() }
        EmberScope.start(configuration: ScopeConfiguration(isEnabled: true, logToOSLog: false))
        #expect(EmberScope.isRecording)
        #expect(EmberScope.configuration.logToOSLog == false)
        #expect(kinds().contains("model"))
        guard case .modelStatus(let status)? = EmberScope.recorder.snapshot().first?.payload else { Issue.record("no status"); return }
        #expect(status.contextSize == SystemLanguageModel.default.contextSize)
        #expect(status.isAvailable == SystemLanguageModel.default.isAvailable)
        #expect(!status.availability.isEmpty && !status.osVersion.isEmpty)
    }

    @Test func sessionFactoryRecordsIntoSharedRecorder() {
        defer { reset() }
        EmberScope.start(configuration: ScopeConfiguration(isEnabled: true, logToOSLog: false))
        let session = EmberScope.session(tools: [EchoTool()], instructions: "Be brief.", label: "chat")
        #expect(session.label == "chat")
        #expect(session.tools.count == 1)
        let created = EmberScope.recorder.snapshot().compactMap { if case .sessionCreated(let i) = $0.payload { return i } else { return nil } }
        #expect(created.map(\.label) == ["chat"])
        #expect(created.first?.instructions == "Be brief.")
        let restored = EmberScope.session(transcript: Fixtures.transcript(), label: "restored")
        #expect(restored.label == "restored")
        let wrapped = LanguageModelSession(instructions: "x").inspected(label: "wrapped")
        #expect(wrapped.label == "wrapped")
        // Everything the facade records is attributed to a session — except the global model status.
        #expect(EmberScope.recorder.snapshot().allSatisfy { event in
            if case .modelStatus = event.payload { return true }
            return event.sessionID != nil
        })
    }

    @Test func notesStopAndClear() {
        defer { reset() }
        EmberScope.start(configuration: ScopeConfiguration(isEnabled: true, logToOSLog: false))
        EmberScope.note("compacted", session: Fixtures.sessionID)
        EmberScope.note("global")
        let notes = EmberScope.recorder.snapshot().filter { if case .note = $0.payload { return true } else { return false } }
        #expect(notes.map(\.sessionID) == [Fixtures.sessionID, nil])
        EmberScope.stop()
        #expect(!EmberScope.isRecording)
        EmberScope.note("ignored")
        #expect(kinds().filter { $0 == "note" }.count == 2)
        EmberScope.clear()
        #expect(EmberScope.recorder.snapshot().isEmpty)
    }

    @Test func startIsIdempotentForTheOSLogSink() {
        defer { reset() }
        EmberScope.start(configuration: ScopeConfiguration(isEnabled: true, logToOSLog: true))
        EmberScope.start(configuration: ScopeConfiguration(isEnabled: true, logToOSLog: true))
        #expect(EmberScope.osLogSinkInstallCount() == 1)
    }

    /// Ruling (Task 11 review): a second start() must reconfigure the already-installed sink.
    @Test func secondStartReconfiguresTheOSLogSink() {
        defer { reset() }
        EmberScope.start(configuration: ScopeConfiguration(isEnabled: true, logToOSLog: true, logContent: true))
        #expect(EmberScope.osLogSink.isEnabled && EmberScope.osLogSink.logsContent)
        EmberScope.start(configuration: ScopeConfiguration(isEnabled: true, logToOSLog: false))
        #expect(!EmberScope.osLogSink.isEnabled && !EmberScope.osLogSink.logsContent)
        #expect(EmberScope.configuration.logToOSLog == false)
        #expect(EmberScope.osLogSinkInstallCount() == 1)
    }

    @Test @MainActor func presentAndDismissToggleTheStore() {
        EmberScope.present()
        #expect(EmberScope.store.isPresented)
        EmberScope.dismiss()
        #expect(!EmberScope.store.isPresented)
    }

    @Test func modelStatusDescribesAvailability() {
        let status = ModelStatus(SystemLanguageModel.default)
        #expect(status.availability.hasPrefix("available") || status.availability.hasPrefix("unavailable"))
        #expect(status.supportedLanguageCount >= 0)
    }
}
