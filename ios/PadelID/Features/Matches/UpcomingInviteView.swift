import SwiftUI

struct UpcomingInviteView: View {
    let matchId: UUID
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var friends = Resource<FriendsResponse>(cacheKey: nil) { .get("v1/friends") }
    @State private var invited: Set<UUID> = []
    @State private var working = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(friends.value?.accepted ?? []) { friend in
                        Button {
                            invite(friend.id)
                        } label: {
                            PlayerRow(card: friend.player) {
                                if invited.contains(friend.id) { Image(systemName: "checkmark") }
                            }
                        }.disabled(working || invited.contains(friend.id) || !app.isOnline)
                    }
                    if friends.isLoading || working { ProgressView() }
                    if let failure = friends.error { SettingsErrorRow(message: failure.message) }
                    if let error { SettingsErrorRow(message: error) }
                } footer: { Text("Друг сам принимает приглашение. До принятия место остаётся свободным.") }
            }
            .navigationTitle("Пригласить друзей")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .task { await friends.load(using: app) }
        }
    }
    private func invite(_ id: UUID) {
        working = true; error = nil
        Task {
            defer { working = false }
            do {
                try await app.api.sendVoid(.json(.post, "v1/upcoming-matches/\(matchId)/invitations", ["player_id": id.uuidString], retryable: true))
                invited.insert(id); app.dataDidChange()
            } catch let failure as APIError { error = failure.message }
            catch { self.error = "Не удалось подтвердить приглашение." }
        }
    }
}

struct GameChatButton: View {
    let gameId: UUID
    @Environment(AppModel.self) private var app
    @Environment(NavigationRouter.self) private var navigation
    @State private var working = false
    @State private var error: String?
    @State private var requestId = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Чат участников", systemImage: "bubble.left.and.bubble.right") {
                let source = navigation.path
                working = true; error = nil
                Task {
                    defer { working = false }
                    do {
                        let chat = try await app.api.send(.json(.post, "v1/conversations", ConversationCreate(kind: "game", gameId: gameId), idempotencyKey: requestId), as: Conversation.self)
                        navigation.push(.conversation(chat.id), from: source)
                    } catch let failure as APIError { error = failure.message }
                    catch { self.error = "Не удалось открыть чат." }
                }
            }.disabled(working || !app.isOnline)
            if let error { SettingsErrorRow(message: error) }
        }
    }
}
