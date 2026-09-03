import SwiftUI

struct ErrorsView: View {
    let store: ScopeStore

    /// One pass over the errors, not one pass per kind — `body` runs on every projection change.
    private var grouped: [(ScopeErrorRecord.Kind, [ScopeErrorRecord])] {
        let byKind = Dictionary(grouping: store.errors, by: \.kind)
        return ScopeErrorRecord.Kind.allCases.compactMap { kind in
            byKind[kind].map { (kind, $0) }
        }
    }

    var body: some View {
        List {
            if store.errors.isEmpty {
                ContentUnavailableView("No errors captured", systemImage: "checkmark.seal",
                                       description: Text("Every error thrown by a session or tool lands here with Apple's debug description, recovery suggestion and underlying error chain."))
            }
            ForEach(grouped, id: \.0) { kind, items in
                Section("\(kind.title) (\(items.count))") {
                    ForEach(items) { error in
                        NavigationLink { ErrorDetailView(error: error) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                RedactableText(error.message).font(.callout).lineLimit(2)
                                HStack(spacing: 8) {
                                    if let tool = error.toolName { Text(tool).font(.caption.monospaced()) }
                                    if error.isRetryable { Text("retryable").font(.caption2) }
                                    if let debug = error.debugDescription { RedactableText(debug).font(.caption).lineLimit(1) }
                                }
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Errors")
    }
}

struct ErrorDetailView: View {
    let error: ScopeErrorRecord
    private var copyText: String {
        var lines = ["\(error.kind.title): \(error.message)"]
        if let d = error.debugDescription { lines.append("debug: \(d)") }
        if let r = error.recoverySuggestion { lines.append("recovery: \(r)") }
        if let f = error.failureReason { lines.append("reason: \(f)") }
        if !error.underlyingChain.isEmpty { lines.append("chain: \(error.underlyingChain.joined(separator: " > "))") }
        lines.append("retryable: \(error.isRetryable)")
        return lines.joined(separator: "\n")
    }
    var body: some View {
        List {
            Section { ErrorSummary(error: error) }
            Section("Links") {
                if let r = error.requestID { LabeledContent("Request", value: ScopeFormatting.short(r)) }
                if let c = error.toolCallID { LabeledContent("Tool call", value: ScopeFormatting.short(c)) }
                LabeledContent("Kind", value: error.kind.rawValue)
            }
        }
        .textSelection(.enabled)
        .navigationTitle(error.kind.title)
        .toolbar { CopyButton(text: copyText) }
    }
}
