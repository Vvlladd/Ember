import SwiftUI

struct SessionDetailView: View {
    let session: SessionRecord

    var body: some View {
        List {
            Section("Session") {
                LabeledContent("Model", value: session.info.modelDescription)
                LabeledContent("Created", value: ScopeFormatting.timestamp(session.createdAt))
                LabeledContent("Last activity", value: ScopeFormatting.timestamp(session.lastActivity))
                if session.prewarmCount > 0 {
                    LabeledContent("Prewarms", value: "\(session.prewarmCount)")
                }
                if session.info.restoredFromTranscript {
                    Label("Restored from a saved transcript", systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let snap = session.latestSnapshot {
                Section("Context window") {
                    ContextWindowBar(snapshot: snap).padding(.vertical, 4)
                }
            }
            Section("Instructions & tools") {
                if let instructions = session.info.instructions {
                    RedactableText(instructions).font(.callout).textSelection(.enabled)
                } else {
                    Text("No instructions").foregroundStyle(.secondary)
                }
                // Keyed by position: `ToolInfo.id` is the host-supplied tool NAME, and two tools with
                // the same name would break List diffing.
                ForEach(Array(session.info.tools.enumerated()), id: \.offset) { _, tool in
                    DisclosureGroup {
                        Text(tool.description).font(.callout).textSelection(.enabled)
                        Text(tool.includesSchemaInInstructions ? "Schema is injected into the instructions" : "Schema not injected")
                            .font(.caption).foregroundStyle(.secondary)
                        if let json = tool.parametersJSON { CodeText(text: json) }
                    } label: {
                        Label(tool.name, systemImage: "wrench.and.screwdriver").foregroundStyle(.orange)
                    }
                }
            }
            if let snap = session.latestSnapshot {
                Section("Transcript (\(snap.entries.count) entries)") {
                    // Same reason: `ScopeEntry.id` comes from the SDK's transcript, not from us.
                    ForEach(Array(snap.entries.enumerated()), id: \.offset) { _, entry in
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
            if !session.errors.isEmpty {
                // The row badge counts these, so the detail must be able to show them.
                Section("Errors (\(session.errors.count))") {
                    ForEach(session.errors) { error in
                        NavigationLink { ErrorDetailView(error: error) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(error.kind.title, systemImage: "exclamationmark.triangle.fill")
                                    .font(.callout).foregroundStyle(ScopeStyle.error)
                                RedactableText(ScopeFormatting.preview(error.message, max: 120))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
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
        .textSelection(.enabled)
        .navigationTitle(session.label)
    }
}
