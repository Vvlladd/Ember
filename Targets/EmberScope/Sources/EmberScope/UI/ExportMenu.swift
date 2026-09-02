import SwiftUI
import UniformTypeIdentifiers

struct ScopeMarkdownExport: Transferable {
    let text: String
    static var transferRepresentation: some TransferRepresentation { ProxyRepresentation(exporting: \.text) }
}

struct ScopeJSONExport: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { $0.data }
    }
}

struct ExportMenu: View {
    let store: ScopeStore
    private var archive: ScopeArchive { ScopeArchive(projection: store.projection) }

    var body: some View {
        Menu {
            ShareLink(item: ScopeMarkdownExport(text: ScopeExport.markdown(archive)),
                      preview: SharePreview("EmberScope report.md")) {
                Label("Share Markdown report", systemImage: "doc.richtext")
            }
            if let data = try? ScopeExport.json(archive) {
                ShareLink(item: ScopeJSONExport(data: data), preview: SharePreview("EmberScope export.json")) {
                    Label("Share JSON archive", systemImage: "curlybraces")
                }
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

    /// `isRecording` mirrors the recorder's flag, but a host that disabled EmberScope records nothing
    /// whatever the flag says — so the toggle is inert and says why.
    private var isEnabled: Bool { store.recorder.configuration.isEnabled }

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
                Button(role: .destructive) { store.clear() } label: { Label("Clear", systemImage: "trash") }
                    .help("Clear all captured events")
                ExportMenu(store: store)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { store.isPresented = false }
            }
        }
    }
}

extension View {
    func scopeToolbar(_ store: ScopeStore) -> some View { modifier(ScopeToolbar(store: store)) }
}
