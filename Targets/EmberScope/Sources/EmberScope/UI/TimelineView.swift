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

    /// Titles and subtitles are precomputed in the fold (`TimelineEntry.searchKey`), so neither the
    /// no-query path nor a keystroke rebuilds thousands of strings in `body`.
    private var entries: [TimelineEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.timeline.reversed().filter { entry in
            guard filter.matches(entry.event.payload) else { return false }
            return q.isEmpty || entry.searchKey.contains(q)
        }
    }

    private var isFiltering: Bool { filter != .all || !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        List {
            Picker("Filter", selection: $filter) { ForEach(Filter.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            if entries.isEmpty {
                if isFiltering {
                    ContentUnavailableView("No matching events", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("\(store.timeline.count) events were captured; none match this filter and search."))
                } else {
                    ContentUnavailableView("No events", systemImage: "list.bullet.rectangle",
                                           description: Text("Events appear here in order as sessions run."))
                }
            }
            ForEach(entries) { entry in
                NavigationLink { EventDetailView(event: entry.event) } label: { TimelineRow(entry: entry) }
            }
        }
        .searchable(text: $query, prompt: "Search titles and previews")
        .navigationTitle("Timeline")
    }
}

struct TimelineRow: View {
    let entry: TimelineEntry
    @ScaledMetric(relativeTo: .callout) private var glyphWidth: CGFloat = 20
    var body: some View {
        let icon = ScopeStyle.icon(for: entry.event.payload)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon.name).foregroundStyle(icon.color).frame(width: glyphWidth)
                .accessibilityHidden(true)   // the title carries the meaning
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.callout)
                if let subtitle = entry.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.event.timestamp, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if let sid = entry.event.sessionID {
                    Text(ScopeFormatting.short(sid)).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
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
