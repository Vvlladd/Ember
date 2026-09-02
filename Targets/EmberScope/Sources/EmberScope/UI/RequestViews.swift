import SwiftUI

struct RequestStatusIcon: View {
    let request: RequestRecord
    var body: some View {
        // Glyph-only status: VoiceOver would otherwise read the SF Symbol name, or nothing at all.
        switch request.end?.status {
        case .succeeded?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Succeeded")
        case .failed?: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).accessibilityLabel("Failed")
        case .cancelled?: Image(systemName: "slash.circle").foregroundStyle(.secondary).accessibilityLabel("Cancelled")
        case nil: ProgressView().controlSize(.small).accessibilityLabel("In flight")
        }
    }
}

struct RequestRow: View {
    let request: RequestRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: request.start.kind == .stream ? "waveform" : "arrow.right.circle").foregroundStyle(.blue)
                Text(request.start.kind == .stream ? "stream" : "respond").font(.caption.bold())
                if let format = request.start.responseFormat {
                    Text("→ \(format)").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.purple.opacity(0.15), in: Capsule()).foregroundStyle(.purple)
                }
                Spacer()
                RequestStatusIcon(request: request)
            }
            Text(request.promptText.map { ScopeFormatting.preview($0, max: 140) } ?? "(Prompt value — text resolved on completion)")
                .font(.callout).lineLimit(2)
            if let end = request.end {
                HStack(spacing: 10) {
                    Text(ScopeFormatting.duration(end.duration))
                    if let ttft = end.timeToFirstToken { Text("first token \(ScopeFormatting.duration(ttft))") }
                    if end.chunkCount > 0 { Text("\(end.chunkCount) chunks") }
                    Text("\(end.outputChars) chars out")
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else if let progress = request.progress {
                Text("streaming · \(progress.chunkCount) chunks · \(progress.contentChars) chars").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct RequestDetail: View {
    let request: RequestRecord
    var body: some View {
        List {
            Section("Prompt") {
                Text(request.promptText ?? "(not captured — a Prompt value was used and the request has not completed)")
                    .font(.callout).textSelection(.enabled)
            }
            Section("Options") {
                LabeledContent("Kind", value: request.start.kind.rawValue)
                LabeledContent("Temperature", value: request.start.options.temperature.map { String($0) } ?? "default")
                LabeledContent("Max response tokens", value: request.start.options.maximumResponseTokens.map(String.init) ?? "default")
                LabeledContent("Sampling", value: request.start.options.samplingDescription)
                if let format = request.start.responseFormat {
                    LabeledContent("Response format", value: format)
                    LabeledContent("Schema in prompt", value: (request.start.includeSchemaInPrompt ?? true) ? "yes" : "no")
                }
            }
            Section("Timing") {
                LabeledContent("Started", value: ScopeFormatting.timestamp(request.startedAt))
                if let end = request.end {
                    LabeledContent("Status") { RequestStatusIcon(request: request) }
                    LabeledContent("Duration", value: ScopeFormatting.duration(end.duration))
                    if let ttft = end.timeToFirstToken { LabeledContent("Time to first token", value: ScopeFormatting.duration(ttft)) }
                    LabeledContent("Chunks", value: "\(end.chunkCount)")
                    LabeledContent("Output characters", value: "\(end.outputChars)")
                    LabeledContent("Transcript entries appended", value: "\(end.appendedEntryCount)")
                } else {
                    LabeledContent("Status", value: "in flight")
                }
            }
            if let output = request.end?.output {
                Section("Output") { Text(output).font(.callout).textSelection(.enabled) }
            }
            if let error = request.error {
                Section("Error") { ErrorSummary(error: error) }
            }
        }
        .textSelection(.enabled)
        .navigationTitle("Request")
        .toolbar { if let text = request.promptText { CopyButton(text: text) } }
    }
}

/// Compact error block reused by request/tool-call details and the Errors tab.
struct ErrorSummary: View {
    let error: ScopeErrorRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(error.kind.title, systemImage: "exclamationmark.triangle.fill").foregroundStyle(ScopeStyle.error).font(.headline)
            Text(error.message).font(.callout).textSelection(.enabled)
            if let debug = error.debugDescription { Text(debug).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
            if let recovery = error.recoverySuggestion { Label(recovery, systemImage: "lightbulb").font(.caption) }
            if let reason = error.failureReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
            if !error.underlyingChain.isEmpty {
                Text("Underlying: " + error.underlyingChain.joined(separator: " › ")).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                if error.isRetryable { Text("retryable").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(.yellow.opacity(0.2), in: Capsule()) }
                if let tool = error.toolName { Text("tool: \(tool)").font(.caption2.monospaced()).foregroundStyle(.secondary) }
            }
        }
    }
}
