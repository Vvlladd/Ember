import Foundation
import Testing
import EmberScope
@testable import FoundationChatKit

/// The real provider must route every session through EmberScope.
///
/// This suite owns process-global EmberScope state (`EmberScope.recorder` / `configuration` / sinks):
/// it is `.serialized` and resets between tests, and any FUTURE real-provider test that records must
/// join this suite rather than start its own. `reset()` clears the events and pauses recording but
/// deliberately leaves the process-wide configuration and installed sinks as configured — `start()`
/// replaces them anyway, and the OSLog sink is installed once for the life of the process.
///
/// Every assertion is scoped to the ids this test itself produced, because other suites running in
/// parallel (`EmberScope.note` from `ConversationEngine`, say) share the same recorder.
@Suite(.serialized)
@MainActor
struct EmberScopeIntegrationTests {
    private func reset() { EmberScope.stop(); EmberScope.clear() }

    /// Events belonging to one handle's session — never the whole process-global log.
    private func events(of handle: any ChatSessionHandle) -> [ScopeEvent] {
        guard let id = handle.inspectionID else { return [] }
        return EmberScope.recorder.snapshot().filter { $0.sessionID == id }
    }

    private func sessionInfo(of handle: any ChatSessionHandle) -> SessionInfo? {
        events(of: handle).compactMap { if case .sessionCreated(let i) = $0.payload { return i } else { return nil } }.first
    }

    @Test func chatSessionsAreInspectedWithToolsAndInstructions() throws {
        defer { reset() }
        EmberScope.start(configuration: ScopeConfiguration(isEnabled: true, logToOSLog: false))
        let provider = FoundationModelProvider()
        let handle = provider.makeSession(settings: GenerationSettings(instructions: "Be Ember."),
                                          tools: Toolbox.defaultTools(), restoring: nil)
        #expect(handle.inspectionID != nil)
        let info = try #require(sessionInfo(of: handle))
        #expect(info.label == "chat")
        #expect(info.instructions == "Be Ember.")
        #expect(info.tools.map(\.name) == ["currentDateTime", "calculator", "unitConverter"])
        #expect(handle.contextEntries.map(\.kind) == [.instructions])
        // Everything this session recorded is attributed to it (the rest of the log may belong to
        // other suites sharing the process-wide recorder).
        #expect(!events(of: handle).isEmpty)
    }

    @Test func seededSessionsAreInspectedToo() throws {
        defer { reset() }
        EmberScope.start(configuration: ScopeConfiguration(isEnabled: true, logToOSLog: false))
        let provider = FoundationModelProvider()
        let handle = provider.makeSession(settings: GenerationSettings(instructions: "Be Ember."), tools: [],
                                          seeding: [ContextEntry(kind: .userPrompt, text: "hi"), ContextEntry(kind: .modelResponse, text: "hello")])
        #expect(handle.inspectionID != nil)
        #expect(sessionInfo(of: handle)?.label == "chat")
        #expect(handle.contextEntries.first?.text.contains("Summary of earlier conversation") == true)
    }

    @Test func mockHandleHasNoInspectionID() {
        #expect(MockSessionHandle().inspectionID == nil)
    }
}
