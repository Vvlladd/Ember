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

/// Selectable, monospaced text for JSON / raw content.
struct CodeText: View {
    let text: String
    var body: some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
