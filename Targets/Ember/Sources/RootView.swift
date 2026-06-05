import SwiftUI
import FoundationChatKit

struct RootView: View {
    let coordinator: ChatCoordinator
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch coordinator.availability {
            case .available:
                ChatScene(coordinator: coordinator)
            case .unavailable(let reason):
                UnavailableView(reason: reason) { coordinator.refreshAvailability() }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { coordinator.refreshAvailability() }
        }
    }
}
