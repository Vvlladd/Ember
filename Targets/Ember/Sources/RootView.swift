import SwiftUI
import FoundationChatKit

struct RootView: View {
    let coordinator: ChatCoordinator

    var body: some View {
        switch coordinator.availability {
        case .available:
            ChatScene(coordinator: coordinator)
        case .unavailable(let reason):
            UnavailableView(reason: reason)
        }
    }
}
