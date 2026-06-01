import SwiftUI
import FoundationChatKit

struct ConversationListView: View {
    let coordinator: ChatCoordinator

    var body: some View {
        List(selection: Binding(get: { coordinator.selectedID },
                                set: { coordinator.select($0) })) {
            ForEach(coordinator.conversations, id: \.id) { convo in
                VStack(alignment: .leading, spacing: 2) {
                    Text(convo.title).lineLimit(1)
                    Text(convo.updatedAt, style: .relative)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(convo.id)
                .swipeActions {
                    Button(role: .destructive) {
                        coordinator.deleteConversation(convo.id)
                    } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .navigationTitle("Ember")
        .toolbar {
            ToolbarItem {
                Button { coordinator.newConversation() } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("New chat")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .overlay {
            if coordinator.conversations.isEmpty {
                ContentUnavailableView("No Chats", systemImage: "bubble.left",
                                       description: Text("Tap compose to start."))
            }
        }
    }
}
