import SwiftUI
import FoundationChatKit

struct ConversationListView: View {
    let coordinator: ChatCoordinator
    @State private var renamingID: UUID?
    @State private var renameDraft = ""
    private static let startTimestampFormat = Date.FormatStyle.dateTime
        .month(.abbreviated)
        .day()
        .hour()
        .minute()

    var body: some View {
        List(selection: Binding(get: { coordinator.selectedID },
                                set: { coordinator.select($0) })) {
            ForEach(coordinator.visibleConversations, id: \.id) { convo in
                VStack(alignment: .leading, spacing: 2) {
                    Text(convo.title).lineLimit(1)
                    Text(convo.createdAt, format: Self.startTimestampFormat)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .tag(convo.id)
                .contextMenu {
                    Button { renamingID = convo.id; renameDraft = convo.title } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        coordinator.deleteConversation(convo.id)
                    } label: { Label("Delete", systemImage: "trash") }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        coordinator.deleteConversation(convo.id)
                    } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .searchable(text: Binding(get: { coordinator.searchText },
                                  set: { coordinator.searchText = $0 }),
                    prompt: "Search chats")
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
        .alert("Rename Chat", isPresented: Binding(get: { renamingID != nil },
                                                   set: { if !$0 { renamingID = nil } })) {
            TextField("Title", text: $renameDraft)
            Button("Cancel", role: .cancel) { renamingID = nil }
            Button("Save") {
                if let id = renamingID { coordinator.rename(id, to: renameDraft) }
                renamingID = nil
            }
        }
        .overlay {
            if coordinator.visibleConversations.isEmpty {
                ContentUnavailableView("No Chats", systemImage: "bubble.left",
                                       description: Text("Tap compose to start."))
            }
        }
    }
}
