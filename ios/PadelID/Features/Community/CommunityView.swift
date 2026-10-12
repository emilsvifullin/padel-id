import SwiftUI

struct CommunityView: View {
    var body: some View {
        PadelNavigationStack {
            List {
                Section {
                    NavigationLink(value: Route.communityFeed) {
                        Label("Лента", systemImage: "text.bubble")
                    }.accessibilityIdentifier("community.feed")
                    NavigationLink(value: Route.conversations) {
                        Label("Сообщения", systemImage: "bubble.left.and.bubble.right")
                    }.accessibilityIdentifier("community.chats")
                    NavigationLink(value: Route.groups) {
                        Label("Игровые сообщества", systemImage: "person.3")
                    }.accessibilityIdentifier("community.groups")
                    NavigationLink(value: Route.friends) {
                        Label("Друзья", systemImage: "person.2")
                    }.accessibilityIdentifier("community.friends")
                    NavigationLink(value: Route.findPlayers) {
                        Label("Найти игроков и тренеров", systemImage: "magnifyingglass")
                    }
                    NavigationLink(value: Route.socialInbox) {
                        Label("Уведомления", systemImage: "bell")
                    }
                } footer: {
                    Text("Знакомьтесь, собирайте игры и оставайтесь на связи.")
                }
            }
            .navigationTitle("Сообщество")
            .padelRoutes()
        }
    }
}

struct ConversationsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var conversations = CommunityCollection<Conversation>("v1/conversations", windowLimit: 150)
    @State private var creating = false
    var body: some View {
        List {
            ForEach(conversations.items) { conversation in
                NavigationLink(value: Route.conversation(conversation.id)) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(conversation.title).font(.headline)
                            Spacer()
                            if conversation.unreadCount > 0 {
                                Text(String(conversation.unreadCount)).font(.caption.bold()).foregroundStyle(Theme.accent)
                            }
                        }
                        Text(conversation.latestMessage?.body ?? "Пока нет сообщений")
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            CommunityCollectionFooter(collection: conversations)
        }
        .navigationTitle("Сообщения")
        .toolbar { Button("Новый чат", systemImage: "square.and.pencil") { creating = true } }
        .sheet(isPresented: $creating) { ConversationCreateView() }
        .task(id: "\(app.dataRevision):\(scenePhase):\(app.isOnline)") {
            guard scenePhase == .active, app.isOnline else { return }
            await conversations.refreshVisibleWindow(using: app)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard scenePhase == .active, app.isOnline else { return }
                await conversations.refreshVisibleWindow(using: app)
            }
        }
        .refreshable { await conversations.load(using: app) }
    }
}

struct CommunityCollectionFooter<Item: Decodable & Sendable & Identifiable>: View where Item.ID: Hashable {
    let collection: CommunityCollection<Item>
    @Environment(AppModel.self) private var app
    var body: some View {
        if let error = collection.error {
            SettingsErrorRow(message: error.message)
            Button("Повторить") { Task { await collection.load(using: app) } }
        }
        if collection.isLoading { ProgressView() }
        else if collection.nextOffset != nil {
            Button("Загрузить ещё") { Task { await collection.load(using: app, more: true) } }
        } else if collection.hasLoaded && collection.items.isEmpty {
            ContentUnavailableView("Пока пусто", systemImage: "bubble.left", description: Text("Здесь появится активность сообщества."))
        }
    }
}

struct ConversationCreateView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var friends = Resource<FriendsResponse>(cacheKey: nil) { .get("v1/friends") }
    @State private var title = ""
    @State private var description = ""
    @State private var publicGroup = false
    @State private var selected: Set<UUID> = []
    @State private var isWorking = false
    @State private var error: String?
    @State private var pending: ConversationCreate?
    @State private var lastSubmission: ConversationCreate?
    @State private var requestId = UUID()

    var body: some View {
        NavigationStack {
            Form {
                Section("Групповой чат") {
                    TextField("Название", text: $title)
                    TextField("О группе", text: $description, axis: .vertical).lineLimit(3...6)
                    Toggle("Открытое сообщество", isOn: $publicGroup)
                }
                .disabled(pending != nil)
                Section("Пригласить друзей") {
                    ForEach(friends.value?.accepted ?? []) { friend in
                        Toggle(friend.player.displayName, isOn: Binding(get: { selected.contains(friend.id) }, set: { included in
                            if included { selected.insert(friend.id) } else { selected.remove(friend.id) }
                        }))
                    }
                    if friends.isLoading { ProgressView() }
                    if let failure = friends.error { SettingsErrorRow(message: failure.message) }
                }.disabled(pending != nil)
                if let error { SettingsErrorRow(message: error) }
                Section {
                    Button(pending == nil ? "Создать" : "Повторить создание") { create() }
                        .disabled(isWorking || !app.isOnline || (pending == nil && (SettingsText.length(title) < 2 || SettingsText.length(title) > 80 || SettingsText.length(description) > 500 || selected.count > 30)))
                    if isWorking { ProgressView() }
                } footer: {
                    Text(publicGroup ? "Открытую группу смогут найти и вступить другие игроки." : "Закрытая группа доступна только участникам. Пригласить можно ваших друзей.")
                }
            }
            .navigationTitle("Новая группа")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
            .task { await friends.load(using: app) }
        }
    }
    private func create() {
        guard !isWorking else { return }
        if pending == nil {
            let submission = ConversationCreate(kind: "group", title: SettingsText.trimmed(title), description: SettingsText.trimmed(description),
                visibility: publicGroup ? "public" : "private", playerIds: selected.sorted { $0.uuidString < $1.uuidString }, cityId: app.me?.profile?.city?.id)
            if let lastSubmission, lastSubmission != submission { requestId = UUID() }
            lastSubmission = submission
            pending = submission
        }
        guard let pending else { return }
        isWorking = true; error = nil
        Task {
            defer { isWorking = false }
            do {
                _ = try await app.api.send(.json(.post, "v1/conversations", pending, idempotencyKey: requestId), as: Conversation.self)
                app.dataDidChange(); dismiss()
            } catch let failure as APIError {
                error = failure.message
                if failure.permitsSubmissionCorrection {
                    self.pending = nil
                }
            }
            catch { self.error = "Не удалось подтвердить создание группы." }
        }
    }
}
