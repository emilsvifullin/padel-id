import SwiftUI
import Observation

@Observable
final class ChatModel {
    let id: UUID
    private(set) var conversation: Conversation?
    private(set) var messages: [ChatMessage] = []
    private(set) var before: Int64?
    private(set) var isLoading = false
    private(set) var isSending = false
    private var loadError: String?
    private var sendError: String?
    // A successful history refresh does not confirm a failed submission.
    // Keep its feedback visible until the user retries or access is revoked.
    var error: String? { sendError ?? loadError }
    private var sendingKey = UUID()
    private var pendingBody: String?
    // A confirmed send invalidates older history snapshots. Revoked access
    // additionally fences pending sends, so late replies cannot reopen a chat.
    private var contentRevision: UInt64 = 0
    private var accessGeneration: UInt64 = 0
    init(id: UUID) { self.id = id }
    var path: String { "v1/conversations/" + id.uuidString.lowercased() }

    func load(using app: AppModel, older: Bool = false, poll: Bool = false) async {
        guard !isLoading else { return }
        let revision = contentRevision
        isLoading = true
        defer { isLoading = false }
        do {
            let detail = try await app.api.send(.get(path), as: Conversation.self)
            guard !Task.isCancelled, revision == contentRevision else { return }
            var query = [URLQueryItem(name: "limit", value: "50")]
            if older, let before { query.append(URLQueryItem(name: "before_id", value: String(before))) }
            // Reconcile the visible history as well as new deliveries: moderation
            // and bilateral blocks can change messages that were already loaded.
            else if poll, let first = messages.first { query.append(URLQueryItem(name: "after_id", value: String(first.id - 1))) }
            var page = try await app.api.send(.get(path + "/messages", query: query), as: MessagePage.self)
            guard !Task.isCancelled, revision == contentRevision else { return }
            var loadedMessages: [ChatMessage]
            if poll, !messages.isEmpty {
                var authoritative = page.items
                while page.items.count == 50, let last = page.items.last {
                    page = try await app.api.send(.get(path + "/messages", query: [
                        URLQueryItem(name: "limit", value: "50"),
                        URLQueryItem(name: "after_id", value: String(last.id))
                    ]), as: MessagePage.self)
                    guard !Task.isCancelled, revision == contentRevision else { return }
                    authoritative += page.items
                }
                loadedMessages = authoritative
            }
            else if !older { loadedMessages = page.items; if poll { before = page.nextBefore } }
            else {
                let merged = Dictionary((messages + page.items).map { ($0.id, $0) }, uniquingKeysWith: { _, fresh in fresh })
                loadedMessages = merged.values.sorted { $0.id < $1.id }
            }
            conversation = detail
            messages = loadedMessages
            if !poll { before = page.nextBefore }
            loadError = nil
            if let last = messages.last {
                // Read acknowledgements never block rendering delivered messages.
                try? await app.api.sendVoid(.json(.post, path + "/read", ["message_id": last.id], retryable: true))
            }
        } catch let failure as APIError {
            guard !Task.isCancelled else { return }
            if failure.status == 403 || failure.status == 404 || failure.status == 401 {
                revokeAccess()
                sendError = nil
                loadError = failure.message
            } else if revision == contentRevision { loadError = failure.message }
        } catch {
            if !Task.isCancelled, revision == contentRevision { loadError = "Не удалось загрузить чат." }
        }
    }

    func send(_ raw: String, using app: AppModel) async -> Bool {
        guard !isSending else { return false }
        let body = SettingsText.trimmed(raw)
        guard (1...4000).contains(body.unicodeScalars.count) else { return false }
        if pendingBody != body { sendingKey = UUID(); pendingBody = body }
        let generation = accessGeneration
        isSending = true; sendError = nil
        defer { isSending = false }
        do {
            let message = try await app.api.send(.json(.post, path + "/messages", ["body": body], idempotencyKey: sendingKey), as: ChatMessage.self)
            guard !Task.isCancelled, generation == accessGeneration else { return false }
            contentRevision &+= 1
            if !messages.contains(where: { $0.id == message.id }) { messages.append(message); messages.sort { $0.id < $1.id } }
            pendingBody = nil
            sendError = nil
            return true
        } catch let failure as APIError {
            guard !Task.isCancelled, generation == accessGeneration else { return false }
            sendError = failure.message
            if failure.status == 403 || failure.status == 404 || failure.status == 401 {
                revokeAccess()
            }
        }
        catch {
            if !Task.isCancelled, generation == accessGeneration {
                sendError = "Отправка не подтверждена. Повторите с тем же текстом."
            }
        }
        return false
    }

    private func revokeAccess() {
        contentRevision &+= 1
        accessGeneration &+= 1
        conversation = nil; messages = []; before = nil
    }
}

struct ChatView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ChatModel
    @State private var draft = ""
    @State private var report: ReportTarget?
    init(id: UUID) { _model = State(initialValue: ChatModel(id: id)) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if model.before != nil {
                        Button("Ранние сообщения") { Task { await model.load(using: app, older: true) } }.disabled(model.isLoading)
                    }
                    ForEach(model.messages) { message in
                        messageRow(message).id(message.id)
                    }
                    if let error = model.error { SettingsErrorRow(message: error) }
                    if model.isLoading { ProgressView() }
                }
                .padding(Theme.horizontalPadding)
            }
            .background(Theme.background)
            .onChange(of: model.messages.last?.id) { _, last in
                if let last, model.before == nil || model.messages.last?.sender.id == app.me?.userId {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(alignment: .bottom, spacing: 12) {
                    TextField("Сообщение", text: $draft, axis: .vertical)
                        .lineLimit(1...5).textFieldStyle(.roundedBorder)
                        .disabled(model.isSending)
                        .accessibilityIdentifier("chat.draft")
                    Button("Отправить", systemImage: "arrow.up.circle.fill") {
                        Task { if await model.send(draft, using: app) { draft = "" } }
                    }
                    .labelStyle(.iconOnly).font(.title2)
                    .disabled(model.isSending || !app.isOnline || !(1...4000).contains(SettingsText.length(draft)) || model.conversation == nil)
                    .accessibilityIdentifier("chat.send")
                }
                .padding().background(.bar)
            }
        }
        .navigationTitle(model.conversation?.title ?? "Сообщения")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let conversation = model.conversation {
                NavigationLink(value: Route.conversationMembers(conversation.id)) {
                    Image(systemName: "person.2")
                }.accessibilityLabel("Участники чата")
            }
        }
        .sheet(item: $report) { ReportContentView(target: $0) }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.load(using: app)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                await model.load(using: app, poll: true)
            }
        }
    }

    private func messageRow(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            NavigationLink(value: Route.player(message.sender.id)) {
                Text(message.sender.displayName).font(.caption.bold()).foregroundStyle(Theme.accent)
            }
            Text(message.deleted ? "Сообщение скрыто" : message.body).textSelection(.enabled)
            Text(message.createdAt, format: .dateTime.day().month().hour().minute())
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        .contextMenu {
            if message.sender.id != app.me?.userId {
                Button("Пожаловаться", systemImage: "flag") { report = ReportTarget(type: "message", id: String(message.id)) }
            }
        }
    }
}

struct ConversationMembersView: View {
    let conversationId: UUID
    @State private var current: Resource<Conversation>
    @State private var friends = Resource<FriendsResponse>(cacheKey: nil) { .get("v1/friends") }
    @State private var adding = false
    @State private var removing: ConversationMember?
    @State private var transferring: ConversationMember?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var working = false
    init(conversationId: UUID) {
        self.conversationId = conversationId
        _current = State(initialValue: Resource(cacheKey: nil) { .get("v1/conversations/\(conversationId.uuidString.lowercased())") })
    }
    private var detail: Conversation? { current.value }
    var body: some View {
        List {
            if let description = detail?.description { Section { Text(description) } }
            if let failure = current.error { SettingsErrorRow(message: failure.message) }
            if current.isLoading { ProgressView() }
            Section("Участники") {
                ForEach(detail?.members ?? []) { member in
                    HStack {
                        NavigationLink(value: Route.player(member.id)) {
                            PlayerRow(card: member.player, subtitle: member.role == "owner" ? "Организатор" : "Участник")
                        }
                        if detail?.kind == "group", detail?.ownerId == app.me?.userId, member.role != "owner" {
                            Menu("Управление участником", systemImage: "ellipsis") {
                                Button("Передать управление группой") { transferring = member }
                                Button("Удалить", systemImage: "person.badge.minus", role: .destructive) { removing = member }
                            }.labelStyle(.iconOnly).disabled(working || !app.isOnline)
                        }
                    }
                }
            }
            if let detail, detail.kind == "group" {
                Section {
                    NavigationLink(value: Route.groupFeed(detail.id)) { Label("Публикации группы", systemImage: "text.bubble") }
                    if detail.ownerId == app.me?.userId {
                        Button("Добавить друзей", systemImage: "person.badge.plus") { adding = true }
                            .disabled(working || !app.isOnline)
                    }
                }
            }
            if let detail, detail.kind == "group", detail.ownerId != app.me?.userId {
                Section {
                    Button("Покинуть группу", role: .destructive) {
                        working = true
                        Task {
                            defer { working = false }
                            do { try await app.api.sendVoid(.json(.post, "v1/conversations/\(conversationId)/leave", [String:String](), retryable: true)); app.dataDidChange(); dismiss() }
                            catch let failure as APIError { error = failure.message }
                            catch { self.error = "Не удалось покинуть группу." }
                        }
                    }.disabled(working || !app.isOnline)
                }
            }
            if let error { SettingsErrorRow(message: error) }
        }
        .navigationTitle("Участники")
        .task(id: app.dataRevision) { await current.load(using: app) }
        .sheet(isPresented: $adding) {
            NavigationStack {
                List {
                    ForEach(friends.value?.accepted ?? []) { friend in
                        if !(detail?.members.contains { $0.id == friend.id } ?? true) {
                            Button { changeMember(friend.id, action: "add") } label: { PlayerRow(card: friend.player) }
                                .disabled(working || !app.isOnline)
                        }
                    }
                    if friends.isLoading { ProgressView() }
                    if let failure = friends.error { SettingsErrorRow(message: failure.message) }
                    if let error { SettingsErrorRow(message: error) }
                }
                .navigationTitle("Добавить друзей")
                .toolbar { Button("Готово") { adding = false } }
                .task { await friends.load(using: app) }
            }
        }
        .alert("Удалить участника?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Удалить", role: .destructive) {
                if let removing { changeMember(removing.id, action: "remove") }
                removing = nil
            }
            Button("Отмена", role: .cancel) { removing = nil }
        }
        .confirmationDialog("Передать управление группой?", isPresented: Binding(get: { transferring != nil }, set: { if !$0 { transferring = nil } }), titleVisibility: .visible) {
            Button("Передать управление") {
                if let transferring { changeMember(transferring.id, action: "transfer_owner") }
                transferring = nil
            }
            Button("Отмена", role: .cancel) { transferring = nil }
        } message: { Text("Вы останетесь участником и сможете покинуть группу. Новый организатор будет управлять её составом.") }
    }
    private func changeMember(_ id: UUID, action: String) {
        guard !working else { return }
        working = true; error = nil
        Task {
            defer { working = false }
            do {
                try await app.api.sendVoid(.json(.post, "v1/conversations/\(conversationId)/members",
                    ["player_id": id.uuidString, "action": action], retryable: true))
                app.dataDidChange(); await current.load(using: app)
            } catch let failure as APIError { error = failure.message }
            catch { self.error = "Изменение состава не подтверждено." }
        }
    }
}
