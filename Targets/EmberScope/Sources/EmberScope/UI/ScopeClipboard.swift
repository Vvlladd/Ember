import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum ScopeClipboard {
    @MainActor static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

struct CopyButton: View {
    let text: String
    var body: some View {
        Button { ScopeClipboard.copy(text) } label: { Label("Copy", systemImage: "doc.on.doc") }
    }
}

/// Selectable, monospaced text for JSON / raw content. A redaction placeholder is italicised so it
/// reads as "not captured" rather than as content that happens to look like that.
struct CodeText: View {
    let text: String
    var body: some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .italic(ScopeRedaction.isRedacted(text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Spec §10: captured content renders normally, a redaction placeholder renders in italics.
struct RedactableText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).italic(ScopeRedaction.isRedacted(text))
    }
}
