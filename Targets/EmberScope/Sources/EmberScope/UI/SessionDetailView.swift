import SwiftUI

struct SessionDetailView: View {
    let session: SessionRecord

    var body: some View {
        List {
            if let snap = session.latestSnapshot {
                Section("Context window") {
                    ContextWindowBar(snapshot: snap).padding(.vertical, 4)
                }
            }
            Section("Instructions & tools") {
                if let instructions = session.info.instructions {
                    Text(instructions).font(.callout).textSelection(.enabled)
                } else {
                    Text("No instructions").foregroundStyle(.secondary)
                }
                ForEach(session.info.tools) { tool in
                    DisclosureGroup {
                        Text(tool.description).font(.callout).textSelection(.enabled)
                        Text(tool.includesSchemaInInstructions ? "Schema is injected into the instructions" : "Schema not injected")
                            .font(.caption).foregroundStyle(.secondary)
                        if let json = tool.parametersJSON { CodeText(text: json) }
                    } label: {
                        Label(tool.name, systemImage: "wrench.and.screwdriver").foregroundStyle(.orange)
                    }
                }
                if session.info.restoredFromTranscript {
                    Label("Restored from a saved transcript", systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let snap = session.latestSnapshot {
                Section("Transcript (\(snap.entries.count) entries)") {
                    ForEach(snap.entries) { entry in
                        NavigationLink { TranscriptEntryDetail(entry: entry) } label: { TranscriptEntryRow(entry: entry) }
                    }
                }
            }
            Section("Requests (\(session.requests.count))") {
                ForEach(session.requests.reversed()) { request in
                    NavigationLink { RequestDetail(request: request) } label: { RequestRow(request: request) }
                }
            }
            if !session.toolCalls.isEmpty {
                Section("Tool calls (\(session.toolCalls.count))") {
                    ForEach(session.toolCalls.reversed()) { call in
                        NavigationLink { ToolCallDetail(call: call) } label: { ToolCallRow(call: call) }
                    }
                }
            }
            if !session.notes.isEmpty {
                Section("Notes") {
                    ForEach(session.notes) { note in
                        HStack(alignment: .top) {
                            Text(note.timestamp, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(note.text).font(.callout)
                        }
                    }
                }
            }
        }
        .navigationTitle(session.label)
    }
}
