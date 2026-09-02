import Foundation
import Testing
import EmberScope
@testable import FoundationChatKit

/// The real provider must route every session through EmberScope. Uses the process-wide recorder, so
/// the suite is serialized and resets it. Constructing a `LanguageModelSession` needs no Apple Intelligence.
@Suite(.serialized)
@MainActor
struct EmberScopeIntegrationTests {
    private func reset() { EmberScope.stop(); EmberScope.clear() }

    private func labels() -> [String] {
        EmberScope.recorder.snapshot().compactMap { if case .sessionCreated(let i) = $0.payload { return i.label } else { return nil } }
    }

    @Test func chatSessionsAreInspectedWithToolsAndInstructions() {
        defer { reset() }
        EmberScope.start(configuration: ScopeConfiguration(isEnabled: true, logToOSLog: false))
        let provider = FoundationModelProvider()
        let handle = provider.makeSession(settings: GenerationSettings(instructions: "Be Ember."),
                                          tools: Toolbox.defaultTools(), restoring: nil)
        #expect(handle.inspectionID != nil)
        #expect(labels() == ["chat"])
        guard case .sessionCreated(let info)? = EmberScope.recorder.snapshot().first(where: { if case .sessionCreated = $0.payload { return true } else { return false } })?.payload else {
            Issue.record("no session"); return
        }
        #expect(info.instructions == "Be Ember.")
        #expect(info.tools.map(\.name) == ["currentDateTime", "calculator", "unitConverter"])
        #expect(handle.contextEntries.map(\.kind) == [.instructions])
        #expect(EmberScope.recorder.snapshot().allSatisfy { $0.sessionID == handle.inspectionID || $0.sessionID == nil })
    }

    @Test func seededSessionsAreInspectedToo() {
        defer { reset() }
        EmberScope.start(configuration: ScopeConfiguration(isEnabled: true, logToOSLog: false))
        let provider = FoundationModelProvider()
        let handle = provider.makeSession(settings: GenerationSettings(instructions: "Be Ember."), tools: [],
                                          seeding: [ContextEntry(kind: .userPrompt, text: "hi"), ContextEntry(kind: .modelResponse, text: "hello")])
        #expect(handle.inspectionID != nil)
        #expect(labels() == ["chat"])
        #expect(handle.contextEntries.first?.text.contains("Summary of earlier conversation") == true)
    }

    @Test func mockHandleHasNoInspectionID() {
        #expect(MockSessionHandle().inspectionID == nil)
    }
}
