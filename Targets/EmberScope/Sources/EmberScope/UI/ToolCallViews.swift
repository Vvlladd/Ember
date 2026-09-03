import SwiftUI

struct ToolCallRow: View {
    let call: ToolCallRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Label(call.start.toolName, systemImage: "wrench.and.screwdriver").font(.callout.bold()).foregroundStyle(.orange)
                Spacer()
                if let end = call.end {
                    Text(ScopeFormatting.duration(end.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if case .failed = end.status { Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).accessibilityLabel("Failed") }
                } else {
                    ProgressView().controlSize(.small).accessibilityLabel("Running")
                }
            }
            RedactableText(ScopeFormatting.preview(call.start.arguments, max: 120))
                .font(.caption.monospaced()).lineLimit(2)
            if let output = call.end?.output {
                RedactableText("→ " + ScopeFormatting.preview(output, max: 120))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ToolCallDetail: View {
    let call: ToolCallRecord
    var body: some View {
        List {
            Section("Arguments") { CodeText(text: call.start.arguments) }
            if let end = call.end {
                Section("Result") {
                    LabeledContent("Duration", value: ScopeFormatting.duration(end.duration))
                    if let output = end.output { RedactableText(output).font(.callout).textSelection(.enabled) }
                }
            } else {
                Section("Result") { Text("Running…").foregroundStyle(.secondary) }
            }
            if let error = call.error { Section("Error") { ErrorSummary(error: error) } }
            Section { LabeledContent("Started", value: ScopeFormatting.timestamp(call.startedAt)); LabeledContent("Call id", value: ScopeFormatting.short(call.id)) }
        }
        .textSelection(.enabled)
        .navigationTitle(call.start.toolName)
        .toolbar { CopyButton(text: call.start.arguments) }
    }
}
