import SwiftUI

struct ToolsView: View {
    let store: ScopeStore
    var body: some View {
        List {
            if store.tools.isEmpty {
                ContentUnavailableView("No tools registered", systemImage: "wrench.and.screwdriver",
                                       description: Text("Tools passed to EmberScope.session(tools:) or wrapped with .inspected() appear here with their schema and call statistics."))
            }
            ForEach(store.tools) { tool in
                NavigationLink { ToolRegistryDetail(tool: tool) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(tool.name).font(.callout.bold().monospaced()).foregroundStyle(.orange)
                            Spacer()
                            Text("\(tool.callCount) calls").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            if tool.failureCount > 0 { Text("\(tool.failureCount) failed").font(.caption.monospacedDigit()).foregroundStyle(.red) }
                            if let mean = tool.meanDuration { Text("avg \(ScopeFormatting.duration(mean))").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        }
                        if let info = tool.info { Text(info.description).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
            }
        }
        .navigationTitle("Tools")
    }
}

struct ToolRegistryDetail: View {
    let tool: ToolRegistryEntry
    var body: some View {
        List {
            Section("Definition") {
                if let info = tool.info {
                    Text(info.description).font(.callout).textSelection(.enabled)
                    LabeledContent("Schema in instructions", value: info.includesSchemaInInstructions ? "yes" : "no")
                } else {
                    Text("Only seen through calls — pass the tool to EmberScope.session(tools:) to capture its definition.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let json = tool.info?.parametersJSON { Section("Parameters schema (JSON)") { CodeText(text: json) } }
            Section("Statistics") {
                LabeledContent("Calls", value: "\(tool.callCount)")
                // The mean is over COMPLETED calls, so show that population rather than leaving the
                // reader to assume it divides by "Calls".
                LabeledContent("Completed", value: "\(tool.completedCount)")
                LabeledContent("Failures", value: "\(tool.failureCount)")
                LabeledContent("Total time", value: ScopeFormatting.duration(tool.totalDuration))
                if let mean = tool.meanDuration { LabeledContent("Mean time", value: ScopeFormatting.duration(mean)) }
            }
        }
        .textSelection(.enabled)
        .navigationTitle(tool.name)
        .toolbar { if let json = tool.info?.parametersJSON { CopyButton(text: json) } }
    }
}
