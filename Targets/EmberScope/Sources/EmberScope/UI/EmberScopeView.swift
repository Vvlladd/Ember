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
                NavigationStack { SessionListView(store: store) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 480)
        #endif
    }
}

#Preview("Sessions") { EmberScopeView(store: .preview) }
#Preview("Session detail") {
    NavigationStack { SessionDetailView(session: ScopeStore.preview.sessions.last!) }
}
