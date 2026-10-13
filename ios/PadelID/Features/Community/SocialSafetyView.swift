import SwiftUI

nonisolated struct ReportTarget: Identifiable, Sendable {
    let type: String
    let id: String
}

struct ReportContentView: View {
    let target: ReportTarget
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var reason = "spam"
    @State private var detail = ""
    @State private var requestId = UUID()
    @State private var pending: ReportBody?
    @State private var lastSubmission: ReportBody?
    @State private var working = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Причина", selection: $reason) {
                        Text("Спам").tag("spam")
                        Text("Оскорбления и травля").tag("harassment")
                        Text("Недопустимое содержание").tag("inappropriate")
                        Text("Другое").tag("other")
                    }
                    TextField("Подробности", text: $detail, axis: .vertical).lineLimit(3...8)
                    SettingsCharacterCount(count: SettingsText.length(detail), limit: 500)
                }.disabled(pending != nil)
                if let error { SettingsErrorRow(message: error) }
                Section {
                    Button(pending == nil ? "Отправить жалобу" : "Повторить отправку") { send() }
                        .disabled(working || !app.isOnline || SettingsText.length(detail) > 500)
                    if working { ProgressView() }
                } footer: { Text("Жалоба будет доступна модераторам. Её отправка не заменяет блокировку игрока.") }
            }
            .navigationTitle("Жалоба")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        }
    }
    private func send() {
        guard !working else { return }
        if pending == nil {
            let submission = ReportBody(targetType: target.type, targetId: target.id, reason: reason, detail: SettingsText.trimmed(detail))
            if let lastSubmission, lastSubmission != submission { requestId = UUID() }
            lastSubmission = submission
            pending = submission
        }
        guard let pending else { return }
        working = true; error = nil
        Task {
            defer { working = false }
            do { try await app.api.sendVoid(.json(.post, "v1/social/reports", pending, idempotencyKey: requestId)); Announce.post("Жалоба отправлена"); dismiss() }
            catch let failure as APIError {
                error = failure.message
                if failure.permitsSubmissionCorrection {
                    self.pending = nil
                }
            }
            catch { self.error = "Отправка жалобы не подтверждена." }
        }
    }
    private nonisolated struct ReportBody: Encodable, Equatable, Sendable {
        let targetType: String
        let targetId: String
        let reason: String
        let detail: String
    }
}

struct SocialPlayerActions: View {
    let playerId: UUID
    let initialFollowing: Bool
    @Environment(AppModel.self) private var app
    @Environment(NavigationRouter.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @State private var report: ReportTarget?
    @State private var confirmingBlock = false
    @State private var working = false
    @State private var error: String?
    @State private var isFollowing = false
    @State private var requestId = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Написать", systemImage: "bubble.left") { openChat() }
                    .accessibilityIdentifier("profile.message")
                Button(isFollowing ? "Отписаться" : "Подписаться", systemImage: "person.badge.plus") { follow() }
            }.buttonStyle(.bordered).disabled(working || !app.isOnline)
            Menu("Безопасность", systemImage: "shield") {
                Button("Пожаловаться", systemImage: "flag") { report = ReportTarget(type: "player", id: playerId.uuidString) }
                Button("Заблокировать", systemImage: "hand.raised", role: .destructive) { confirmingBlock = true }
            }.disabled(working)
            if let error { SettingsErrorRow(message: error) }
        }
        .sheet(item: $report) { ReportContentView(target: $0).presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
        .alert("Заблокировать игрока?", isPresented: $confirmingBlock) {
            Button("Заблокировать", role: .destructive) { block() }
            Button("Отмена", role: .cancel) {}
        } message: { Text("Дружба и подписки будут удалены. Игрок не сможет писать вам. Спортивные результаты сохранятся.") }
        .task(id: initialFollowing) { isFollowing = initialFollowing }
    }
    private func openChat() {
        let source = navigation.path
        perform {
            let conversation = try await app.api.send(.json(.post, "v1/conversations", ConversationCreate(kind: "direct", playerId: playerId), idempotencyKey: requestId), as: Conversation.self)
            navigation.push(.conversation(conversation.id), from: source)
        }
    }
    private func follow() {
        let method: Endpoint.Method = isFollowing ? .delete : .put
        perform {
            try await app.api.sendVoid(.empty(method, "v1/social/follows/\(playerId)", retryable: true))
            isFollowing.toggle(); app.dataDidChange()
        }
    }
    private func block() {
        perform {
            try await app.api.sendVoid(.empty(.put, "v1/social/blocks/\(playerId)", retryable: true))
            app.cache.purgeAll(); app.cache.activate(userId: app.me?.userId)
            AvatarLoader.cache.removeAllCachedResponses()
            app.dataDidChange(); dismiss()
        }
    }
    private func perform(_ action: @escaping () async throws -> Void) {
        guard !working else { return }
        working = true; error = nil
        Task {
            defer { working = false }
            do { try await action() }
            catch let failure as APIError { error = failure.message }
            catch { self.error = "Действие не подтверждено. Попробуйте снова." }
        }
    }
}

struct SocialPrivacyView: View {
    @Environment(AppModel.self) private var app
    @State private var settings: SocialSettings?
    @State private var working = false
    @State private var error: String?
    var body: some View {
        Form {
            if settings != nil {
                Section("Личные сообщения") {
                    Picker("Кто может писать", selection: Binding(get: { settings?.messagesFrom ?? "friends" }, set: { settings?.messagesFrom = $0 })) {
                        Text("Только друзья").tag("friends")
                        Text("Все игроки").tag("everyone")
                        Text("Никто").tag("nobody")
                    }
                }.disabled(working)
                Section("Уведомления в приложении") {
                    Toggle("Сообщения", isOn: Binding(get: { settings?.notifyMessages ?? true }, set: { settings?.notifyMessages = $0 }))
                    Toggle("Активность", isOn: Binding(get: { settings?.notifyActivity ?? true }, set: { settings?.notifyActivity = $0 }))
                }.disabled(working)
                Button("Сохранить") { Task { await save() } }.disabled(working || !app.isOnline)
            }
            Section {
                NavigationLink(value: Route.socialPlayers(blocked: true)) { Text("Заблокированные игроки") }
                NavigationLink(value: Route.socialPlayers(blocked: false)) { Text("Мои подписки") }
            }
            if working { ProgressView() }
            if let error { SettingsErrorRow(message: error); Button("Повторить") { Task { await load() } } }
        }
        .navigationTitle("Приватность")
        .task { await load() }
    }
    private func load() async {
        do { settings = try await app.api.send(.get("v1/social/settings"), as: SocialSettings.self); error = nil }
        catch let failure as APIError { error = failure.message }
        catch { self.error = "Не удалось загрузить настройки." }
    }
    private func save() async {
        guard !working, let settings else { return }
        working = true; error = nil
        defer { working = false }
        do {
            self.settings = try await app.api.send(.json(.patch, "v1/social/settings", settings, retryable: true), as: SocialSettings.self)
            Announce.post("Настройки сохранены")
        } catch let failure as APIError { error = failure.message }
        catch { self.error = "Сохранение не подтверждено." }
    }
}

struct SocialPlayersListView: View {
    let blocked: Bool
    @Environment(AppModel.self) private var app
    @State private var players: CommunityCollection<PlayerCard>
    @State private var error: String?
    @State private var working = false
    init(blocked: Bool) {
        self.blocked = blocked
        _players = State(initialValue: CommunityCollection(blocked ? "v1/social/blocks" : "v1/social/follows"))
    }
    var body: some View {
        List {
            ForEach(players.items) { player in
                VStack(alignment: .leading, spacing: 8) {
                    if blocked { Text(player.displayName).font(.headline) }
                    else { NavigationLink(value: Route.player(player.id)) { PlayerRow(card: player) } }
                    Button(blocked ? "Разблокировать" : "Отписаться") { remove(player.id) }.disabled(working || !app.isOnline)
                }
            }
            CommunityCollectionFooter(collection: players)
            if let error { SettingsErrorRow(message: error) }
        }
        .navigationTitle(blocked ? "Блокировки" : "Подписки")
        .task { await players.load(using: app) }
    }
    private func remove(_ id: UUID) {
        working = true
        Task {
            defer { working = false }
            do {
                try await app.api.sendVoid(.empty(.delete, "v1/social/\(blocked ? "blocks" : "follows")/\(id)", retryable: true))
                app.dataDidChange(); await players.load(using: app)
            } catch let failure as APIError { error = failure.message }
            catch { self.error = "Действие не подтверждено." }
        }
    }
}
