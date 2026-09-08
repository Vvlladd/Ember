import SwiftUI
import UniformTypeIdentifiers

/// Rendering happens inside the transfer representation (on share), never in a view `body`.
/// Both carry a `suggestedFileName`: without one the share sheet writes "Untitled" and a bug report
/// arrives as an unnamed attachment.
struct ScopeMarkdownExport: Transferable {
    let archive: ScopeArchive
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .utf8PlainText) { Data(ScopeExport.markdown($0.archive).utf8) }
            .suggestedFileName("EmberScope-report.md")
    }
}

struct ScopeJSONExport: Transferable {
    let archive: ScopeArchive
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { try ScopeExport.json($0.archive) }
            .suggestedFileName("EmberScope-archive.json")
    }
}

struct ExportMenu: View {
    let store: ScopeStore
    private var archive: ScopeArchive { ScopeArchive(projection: store.projection) }

    var body: some View {
        Menu {
            ShareLink(item: ScopeMarkdownExport(archive: archive),
                      preview: SharePreview("EmberScope-report.md")) {
                Label("Share Markdown report", systemImage: "doc.richtext")
            }
            ShareLink(item: ScopeJSONExport(archive: archive),
                      preview: SharePreview("EmberScope-archive.json")) {
                Label("Share JSON archive", systemImage: "curlybraces")
            }
            Button { ScopeClipboard.copy(ScopeExport.markdown(archive)) } label: { Label("Copy Markdown", systemImage: "doc.on.doc") }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
    }
}

/// Record / clear / export / done — applied to every tab's root.
struct ScopeToolbar: ViewModifier {
    let store: ScopeStore
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingClear = false

    /// `isRecording` mirrors the recorder's flag, but a host that disabled EmberScope records nothing
    /// whatever the flag says — so the toggle is inert and says why. Read from the store's mirror:
    /// a `body` must not take the recorder's lock.
    private var isEnabled: Bool { store.isEnabled }

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    store.setRecording(!store.isRecording)
                } label: {
                    Label(store.isRecording ? "Pause" : "Record", systemImage: store.isRecording ? "pause.circle.fill" : "record.circle")
                }
                .disabled(!isEnabled)
                .help(isEnabled ? (store.isRecording ? "Pause recording" : "Resume recording")
                                : "EmberScope is disabled by configuration")
                // One tap from Export, and there is no undo: the ring buffer is the only copy.
                Button(role: .destructive) { isConfirmingClear = true } label: { Label("Clear", systemImage: "trash") }
                    .help("Clear all captured events")
                ExportMenu(store: store)
            }
            if store.isPresented {
                // `dismiss()` is inert when the console was placed by the host (a macOS window, a tab):
                // only offer Done for the presentation this store actually drives.
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .confirmationDialog("Clear every captured event?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { store.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sessions, requests, tool calls and errors are dropped. Export first if you need them.")
        }
    }
}

extension View {
    func scopeToolbar(_ store: ScopeStore) -> some View { modifier(ScopeToolbar(store: store)) }
}
