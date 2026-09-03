import SwiftUI

struct KindBadge: View {
    let kind: ScopeEntry.Kind
    var body: some View {
        Label(ScopeStyle.label(kind), systemImage: ScopeStyle.icon(kind))
            .font(.caption2.bold()).foregroundStyle(ScopeStyle.color(kind))
    }
}

struct TranscriptEntryRow: View {
    let entry: ScopeEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                KindBadge(kind: entry.kind)
                if let tool = entry.toolName { Text(tool).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                if let format = entry.responseFormat { Text("→ \(format)").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                Text("\(entry.isExact ? "" : "~")\(ScopeFormatting.tokens(entry.tokens))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            RedactableText(ScopeFormatting.preview(entry.text, max: 160)).font(.callout).lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

struct TranscriptEntryDetail: View {
    let entry: ScopeEntry
    var body: some View {
        List {
            Section {
                LabeledContent("Kind") { KindBadge(kind: entry.kind) }
                LabeledContent("Tokens", value: "\(entry.isExact ? "" : "~")\(ScopeFormatting.tokens(entry.tokens))\(entry.isExact ? " (exact)" : " (estimated)")")
                LabeledContent("Entry id", value: entry.id)
                if let tool = entry.toolName { LabeledContent("Tool", value: tool) }
                if let format = entry.responseFormat { LabeledContent("Response format", value: format) }
                if let o = entry.options {
                    LabeledContent("Temperature", value: o.temperature.map { String($0) } ?? "default")
                    LabeledContent("Max response tokens", value: o.maximumResponseTokens.map(String.init) ?? "default")
                    LabeledContent("Sampling", value: o.samplingDescription)
                }
            }
            if !entry.toolDefinitions.isEmpty {
                Section("Tool definitions the model sees") {
                    // Keyed by position: the names come from the host's tools, and two same-named
                    // definitions would break List diffing.
                    ForEach(Array(entry.toolDefinitions.enumerated()), id: \.offset) { _, def in
                        VStack(alignment: .leading) {
                            Text(def.name).font(.callout.monospaced())
                            Text(def.description).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Text") { RedactableText(entry.text).font(.callout).textSelection(.enabled) }
            // `TranscriptRendering.text` already joins structured segments in, so showing the JSON
            // again would print the same bytes twice. (Do not change `text` itself — token counting
            // reads it.)
            if let json = entry.structuredJSON, !entry.text.contains(json) {
                Section("Structured content") { CodeText(text: json) }
            }
        }
        .textSelection(.enabled)
        .navigationTitle(ScopeStyle.label(entry.kind).capitalized)
        .toolbar { CopyButton(text: entry.text) }
    }
}
