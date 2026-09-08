import SwiftUI

/// The inspector console. Present it with `.emberScope()`, `EmberScope.present()`, or place it yourself.
public struct EmberScopeView: View {
    let store: ScopeStore

    @MainActor public init(store: ScopeStore? = nil) {
        self.store = store ?? EmberScope.store
    }

    public var body: some View {
        TabView {
            Tab("Sessions", systemImage: "rectangle.stack") {
                NavigationStack { SessionListView(store: store).scopeToolbar(store) }
            }
            Tab("Timeline", systemImage: "list.bullet.rectangle") {
                NavigationStack { TimelineView(store: store).scopeToolbar(store) }
            }
            Tab("Errors", systemImage: "exclamationmark.triangle") {
                NavigationStack { ErrorsView(store: store).scopeToolbar(store) }
            }
            .badge(store.errors.count)
            Tab("Tools", systemImage: "wrench.and.screwdriver") {
                NavigationStack { ToolsView(store: store).scopeToolbar(store) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 520)
        #endif
    }
}

#if DEBUG
#Preview("Sessions") { EmberScopeView(store: .preview) }
#Preview("Session detail") {
    NavigationStack {
        if let chat = ScopeStore.preview.sessions.first(where: { !$0.requests.isEmpty }) {
            SessionDetailView(session: chat)
        } else {
            ContentUnavailableView("No preview session", systemImage: "questionmark.circle")
        }
    }
}
#Preview("Timeline") { NavigationStack { TimelineView(store: .preview) } }
#Preview("Errors") { NavigationStack { ErrorsView(store: .preview) } }
#Preview("Tools") { NavigationStack { ToolsView(store: .preview) } }
#endif
