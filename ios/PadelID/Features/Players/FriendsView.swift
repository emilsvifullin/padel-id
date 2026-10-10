import SwiftUI

struct FriendsView: View {
    @Environment(AppModel.self) private var app
    @State private var friends = Resource<FriendsResponse>(cacheKey: CacheKey.friends) { .get("v1/friends") }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink(value: Route.findPlayers) {
                        Label("Найти игроков", systemImage: "magnifyingglass")
                    }.accessibilityIdentifier("friends.search")
                }
                if let value = friends.value {
                    if friends.isStale, let error = friends.error { StaleDataBanner(error: error) }
                    friendshipSection("Входящие заявки", items: value.incoming)
                    friendshipSection("Исходящие заявки", items: value.outgoing)
                    friendshipSection("Друзья", items: value.accepted)
                    if value.accepted.isEmpty && value.incoming.isEmpty && value.outgoing.isEmpty {
                        ContentUnavailableView("Играйте вместе", systemImage: "person.2", description: Text("Найдите игрока и отправьте заявку из его профиля."))
                    }
                } else if let error = friends.error {
                    ErrorStateView(error: error) { Task { await friends.load(using: app) } }
                } else { ProgressView() }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Друзья")
            .padelRoutes()
            .refreshable { await friends.load(using: app) }
        }
        .task(id: app.dataRevision) { await friends.load(using: app) }
    }

    @ViewBuilder
    private func friendshipSection(_ title: String, items: [Friendship]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { relation in
                    VStack(alignment: .leading, spacing: 8) {
                        NavigationLink(value: Route.player(relation.id)) {
                            PlayerRow(card: relation.player) {
                                LevelChip(level: relation.player.level, reliability: relation.player.reliability)
                            }
                        }
                        if relation.status != .accepted { FriendshipControls(playerId: relation.id, initial: relation.status) }
                    }
                    .accessibilityIdentifier("friends.row")
                }
            }
        }
    }
}

/// Uses a live relationship endpoint, so cached lists never authorize actions.
struct FriendshipControls: View {
    let playerId: UUID
    var initial: FriendshipState = .none
    @Environment(AppModel.self) private var app
    @State private var state: FriendshipState?
    @State private var isWorking = false
    @State private var error: String?
    @State private var requestID = UUID()
    @State private var confirmingRemoval = false

    private var current: FriendshipState { state ?? initial }
    private var path: String { "v1/friends/" + playerId.uuidString.lowercased() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !app.isOnline { SettingsOfflineNotice(message: "Для изменения дружбы нужно подключение.") }
            HStack {
                switch current {
                case .none:
                    Button("Добавить в друзья", systemImage: "person.badge.plus") { perform("request") }
                case .incoming:
                    Button("Принять") { perform("respond", decision: "accepted") }.buttonStyle(.borderedProminent)
                    Button("Отклонить") { perform("respond", decision: "rejected") }
                case .outgoing:
                    Button("Отменить заявку") { perform("delete") }
                case .accepted:
                    Label("Вы друзья", systemImage: "person.2.fill").foregroundStyle(Theme.positive)
                    Spacer(minLength: 4)
                    Button("Удалить", role: .destructive) { confirmingRemoval = true }
                }
                if isWorking { ProgressView() }
            }
            .disabled(!app.isOnline || isWorking)
            .buttonStyle(.bordered)
            if let error { SettingsErrorRow(message: error) }
        }
        .accessibilityIdentifier("profile.friendship")
        .alert("Удалить из друзей?", isPresented: $confirmingRemoval) {
            Button("Удалить", role: .destructive) { perform("delete") }
            Button("Отмена", role: .cancel) {}
        }
        .task(id: app.dataRevision) {
            let id = UUID()
            requestID = id
            do {
                let fresh = try await app.api.send(.get(path), as: FriendshipStatus.self)
                guard requestID == id, !Task.isCancelled else { return }
                state = fresh.status
            }
            catch let failure as APIError { if requestID == id && !Task.isCancelled && state == nil && initial == .none { error = failure.message } }
            catch { }
        }
    }

    private func perform(_ action: String, decision: String? = nil) {
        guard app.isOnline, !isWorking else { return }
        requestID = UUID()
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                let endpoint: Endpoint = action == "delete"
                    ? .json(.delete, path, [String: String](), retryable: true)
                    : .json(.post, path + "/" + action, decision.map { ["decision": $0] } ?? [:], retryable: true)
                let result = try await app.api.send(endpoint, as: FriendshipStatus.self)
                state = result.status
                app.dataDidChange()
                Announce.post(result.status == .accepted ? "Заявка принята" : result.status == .outgoing ? "Заявка отправлена" : "Дружба обновлена")
            } catch let failure as APIError { error = failure.message; Announce.post(failure.message) }
            catch { self.error = "Не удалось изменить дружбу. Попробуйте снова." }
        }
    }
}
