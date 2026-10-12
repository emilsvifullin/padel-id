import SwiftUI

struct GroupsView: View {
    @Environment(AppModel.self) private var app
    @Environment(NavigationRouter.self) private var navigation
    @State private var groups = CommunityCollection<SocialGroup>("v1/social/groups")
    @State private var query = ""
    @State private var creating = false
    @State private var working = false
    @State private var error: String?
    var body: some View {
        List {
            ForEach(groups.items) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.title).font(.headline)
                    if let description = group.description { Text(description).font(.subheadline).foregroundStyle(.secondary) }
                    Text("Участников: \(group.memberCount)").font(.caption).foregroundStyle(.secondary)
                    if group.joined {
                        NavigationLink("Открыть чат", value: Route.conversation(group.id))
                    } else { Button("Вступить") { join(group.id) }.disabled(working || !app.isOnline) }
                }
            }
            CommunityCollectionFooter(collection: groups)
            if let error { SettingsErrorRow(message: error) }
        }
        .navigationTitle("Сообщества")
        .searchable(text: $query, prompt: "Найти группу")
        .toolbar { Button("Создать", systemImage: "plus") { creating = true } }
        .sheet(isPresented: $creating) { ConversationCreateView() }
        .task(id: "\(query):\(app.dataRevision)") {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            groups = CommunityCollection("v1/social/groups", query: [URLQueryItem(name: "query", value: query)])
            await groups.load(using: app)
        }
    }
    private func join(_ id: UUID) {
        let source = navigation.path
        working = true; error = nil
        Task {
            defer { working = false }
            do { try await app.api.sendVoid(.json(.post, "v1/conversations/\(id)/join", [String:String](), retryable: true)); app.dataDidChange(); navigation.push(.conversation(id), from: source) }
            catch let failure as APIError { error = failure.message }
            catch { self.error = "Не удалось подтвердить вступление." }
        }
    }
}

struct SocialInboxView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var notifications = CommunityCollection<SocialNotification>("v1/notifications", windowLimit: 150)
    @State private var error: String?
    @State private var working = false
    var body: some View {
        List {
            ForEach(notifications.items) { notification in
                VStack(alignment: .leading, spacing: 6) {
                    Label(notification.title, systemImage: notification.readAt == nil ? "circle.fill" : "circle")
                    Text(notification.createdAt, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    if let id = notification.resourceId {
                        if notification.kind == "message" { NavigationLink("Открыть чат", value: Route.conversation(id)) }
                        else if notification.kind == "comment" || notification.kind == "reaction" { NavigationLink("Открыть публикацию", value: Route.post(id)) }
                        else if notification.kind.hasPrefix("game_") { NavigationLink("Открыть игру", value: Route.upcoming(id)) }
                        else if notification.kind.hasPrefix("friend_") { NavigationLink("Открыть профиль", value: Route.player(id)) }
                        else if notification.kind == "match" { NavigationLink("Открыть матч", value: Route.match(id)) }
                        else if notification.kind == "event" { NavigationLink("Открыть событие", value: Route.event(id)) }
                    }
                }
            }
            CommunityCollectionFooter(collection: notifications)
            if let error { SettingsErrorRow(message: error) }
        }
        .navigationTitle("Уведомления")
        .toolbar { Button("Прочитать все") { markRead() }.disabled(working || !app.isOnline) }
        .task(id: "\(app.dataRevision):\(scenePhase):\(app.isOnline)") {
            guard scenePhase == .active, app.isOnline else { return }
            await notifications.refreshVisibleWindow(using: app)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard scenePhase == .active, app.isOnline else { return }
                await notifications.refreshVisibleWindow(using: app)
            }
        }
        .refreshable { await notifications.load(using: app) }
    }
    private func markRead() {
        working = true
        Task {
            defer { working = false }
            do { try await app.api.sendVoid(.json(.post, "v1/notifications/read", [String:String](), retryable: true)); await notifications.refreshVisibleWindow(using: app) }
            catch let failure as APIError { error = failure.message }
            catch { self.error = "Не удалось отметить уведомления прочитанными." }
        }
    }
}

struct ModerationReportsView: View {
    @Environment(AppModel.self) private var app
    @State private var reports = CommunityCollection<ModerationReport>("v1/admin/reports")
    @State private var working = false
    @State private var error: String?
    @State private var hiding: ModerationReport?
    @State private var confirmingHide = false
    var body: some View {
        List {
            ForEach(reports.items) { report in
                VStack(alignment: .leading, spacing: 8) {
                    Text(targetTitle(report.targetType) + " · " + reasonTitle(report.reason)).font(.headline)
                    if let author = report.content?.authorName { Text(author).font(.subheadline.bold()) }
                    if let body = report.content?.body {
                        Text(body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    } else if report.content == nil {
                        Text("Содержание уже удалено или недоступно.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if report.targetType == "player", let id = UUID(uuidString: report.targetId) {
                        NavigationLink("Профиль игрока", value: Route.player(id))
                    }
                    if let detail = report.detail, !detail.isEmpty { Text("Описание жалобы: " + detail).font(.subheadline) }
                    Text("Ожидает проверки").font(.caption).foregroundStyle(.secondary)
                    if report.status == "pending" {
                        VStack(alignment: .leading) {
                            if report.targetType != "player", report.content != nil {
                                Button("Скрыть содержание", role: .destructive) {
                                    hiding = report; confirmingHide = true
                                }
                            }
                            Button("Отклонить жалобу") { resolve(report.id, "dismiss") }
                        }.disabled(working || !app.isOnline)
                    }
                }
            }
            CommunityCollectionFooter(collection: reports)
            if let error { SettingsErrorRow(message: error) }
        }
        .navigationTitle("Жалобы")
        .task { await reports.load(using: app) }
        .refreshable { await reports.load(using: app) }
        .confirmationDialog("Скрыть содержание для всех участников?", isPresented: $confirmingHide,
                            titleVisibility: .visible, presenting: hiding) { report in
            Button("Скрыть содержание", role: .destructive) { resolve(report.id, "hide") }
        }
    }
    private func targetTitle(_ type: String) -> String {
        switch type {
        case "player": "Игрок"
        case "post": "Публикация"
        case "comment": "Комментарий"
        case "message": "Сообщение"
        default: "Содержание"
        }
    }
    private func reasonTitle(_ reason: String) -> String {
        switch reason {
        case "spam": "Спам"
        case "harassment": "Оскорбления и травля"
        case "inappropriate": "Недопустимое содержание"
        default: "Другое"
        }
    }
    private func resolve(_ id: UUID, _ decision: String) {
        working = true
        Task {
            defer { working = false }
            do { try await app.api.sendVoid(.json(.post, "v1/admin/reports/\(id)", ["decision":decision], retryable: true)); app.dataDidChange(); await reports.load(using: app) }
            catch let failure as APIError { error = failure.message }
            catch { self.error = "Решение не подтверждено." }
        }
    }
}
