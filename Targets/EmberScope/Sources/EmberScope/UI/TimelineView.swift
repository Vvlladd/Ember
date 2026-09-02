import SwiftUI

struct TimelineView: View {
    let store: ScopeStore
    @State private var filter: Filter = .all
    @State private var query = ""

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", requests = "Requests", tools = "Tools", errors = "Errors", snapshots = "Context", notes = "Notes"
        var id: String { rawValue }
        func matches(_ payload: ScopePayload) -> Bool {
            switch (self, payload) {
            case (.all, _): true
            case (.requests, .requestStarted), (.requests, .streamProgress), (.requests, .requestFinished): true
            case (.tools, .toolCallStarted), (.tools, .toolCallFinished): true
            case (.errors, .error): true
            case (.snapshots, .transcriptSnapshot), (.snapshots, .tokenCountsResolved): true
            case (.notes, .note), (.notes, .sessionCreated), (.notes, .modelStatus), (.notes, .prewarm): true
            default: false
            }
        }
    }

    private var events: [ScopeEvent] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.timeline.reversed().filter { event in
            guard filter.matches(event.payload) else { return false }
            guard !q.isEmpty else { return true }
            let haystack = (ScopeStyle.title(for: event.payload) + " " + (ScopeStyle.subtitle(for: event.payload) ?? "")).lowercased()
            return haystack.contains(q)
        }
    }

    var body: some View {
        List {
            Picker("Filter", selection: $filter) { ForEach(Filter.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            if events.isEmpty {
                ContentUnavailableView("No events", systemImage: "list.bullet.rectangle",
                                       description: Text("Events appear here in order as sessions run."))
            }
            ForEach(events) { event in
                NavigationLink { EventDetailView(event: event) } label: { TimelineRow(event: event) }
            }
        }
        .searchable(text: $query, prompt: "Search titles and previews")
        .navigationTitle("Timeline")
    }
}

struct TimelineRow: View {
    let event: ScopeEvent
    var body: some View {
        let icon = ScopeStyle.icon(for: event.payload)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon.name).foregroundStyle(icon.color).frame(width: 20)
                .accessibilityHidden(true)   // the title carries the meaning
            VStack(alignment: .leading, spacing: 2) {
                Text(ScopeStyle.title(for: event.payload)).font(.callout)
                if let subtitle = ScopeStyle.subtitle(for: event.payload) {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(event.timestamp, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if let sid = event.sessionID { Text(ScopeFormatting.short(sid)).font(.caption2.monospaced()).foregroundStyle(.tertiary) }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Raw event as pretty JSON — the escape hatch when a screen does not show a field.
struct EventDetailView: View {
    let event: ScopeEvent
    private var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(event)).flatMap { String(data: $0, encoding: .utf8) } ?? "(unencodable)"
    }
    var body: some View {
        List {
            Section {
                LabeledContent("Sequence", value: "\(event.sequence)")
                LabeledContent("Time", value: ScopeFormatting.timestamp(event.timestamp))
                if let sid = event.sessionID { LabeledContent("Session", value: ScopeFormatting.short(sid)) }
            }
            if case .error(let error) = event.payload { Section("Error") { ErrorSummary(error: error) } }
            Section("Event JSON") { CodeText(text: json) }
        }
        .textSelection(.enabled)
        .navigationTitle(ScopeStyle.title(for: event.payload))
        .toolbar { CopyButton(text: json) }
    }
}
