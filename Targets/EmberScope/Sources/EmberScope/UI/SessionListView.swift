import SwiftUI

struct SessionListView: View {
    let store: ScopeStore

    var body: some View {
        List {
            Section("Model") { ModelStatusCard(status: store.modelStatus) }
            Section {
                if store.sessions.isEmpty {
                    ContentUnavailableView("No sessions yet", systemImage: "waveform.path.ecg",
                        description: Text("Create sessions with EmberScope.session(…) or wrap one with .inspected(). Requests, tool calls and errors appear here as they happen."))
                } else {
                    ForEach(store.sessions) { session in
                        NavigationLink(value: session.id) { SessionRow(session: session) }
                    }
                }
            } header: {
                Text("Sessions (\(store.sessions.count))")
            } footer: {
                if store.evictedEventCount > 0 {
                    Text("\(store.evictedEventCount) older events were evicted (maxEvents = \(store.maxEvents)).")
                }
                if !store.isRecording { Text("Recording is paused.") }
            }
        }
        .navigationTitle("Ember Scope")
        .navigationDestination(for: UUID.self) { id in
            if let session = store.session(id: id) {
                SessionDetailView(session: session)
            } else {
                ContentUnavailableView("Session evicted", systemImage: "clock.arrow.circlepath")
            }
        }
    }
}

struct SessionRow: View {
    let session: SessionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.label).font(.headline)
                Text(ScopeFormatting.short(session.id)).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Text(session.createdAt, style: .time).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                badge("\(session.requests.count) req", .blue)
                badge("\(session.toolCalls.count) tools", .orange)
                if !session.errors.isEmpty { badge("\(session.errors.count) errors", .red) }
                if session.requests.contains(where: \.isInFlight) { ProgressView().controlSize(.mini).accessibilityLabel("Running") }
            }
            if let snap = session.latestSnapshot { ContextWindowBar(snapshot: snap, compact: true) }
        }
        .padding(.vertical, 2)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2).monospacedDigit()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
    }
}
