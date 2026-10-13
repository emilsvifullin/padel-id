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
    @State private var sentCount = 0
    init(id: UUID) { _model = State(initialValue: ChatModel(id: id)) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.before != nil {
                        Button("Ранние сообщения") { Task { await model.load(using: app, older: true) } }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .disabled(model.isLoading)
                    }
                    ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                        let previous = index > 0 ? model.messages[index - 1] : nil
                        let next = index + 1 < model.messages.count ? model.messages[index + 1] : nil
                        let opensDay = previous.map { !Calendar.current.isDate($0.createdAt, inSameDayAs: message.createdAt) } ?? true
                        if opensDay { dayHeader(message.createdAt) }
                        messageRow(message,
                                   opensRun: opensDay || previous?.sender.id != message.sender.id,
                                   closesRun: next.map { $0.sender.id != message.sender.id
                                       || !Calendar.current.isDate($0.createdAt, inSameDayAs: message.createdAt) } ?? true)
                            .id(message.id)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if let error = model.error { SettingsErrorRow(message: error).padding(.top, 10) }
                    if model.isLoading { ProgressView().frame(maxWidth: .infinity).padding(.top, 10) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .padelAnimation(Motion.quick, value: model.messages.last?.id)
            }
            .background(Theme.canvas)
            .onChange(of: model.messages.last?.id) { _, last in
                if let last, model.before == nil || model.messages.last?.sender.id == app.me?.userId {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
            .safeAreaBar(edge: .bottom) {
                ComposerBar(placeholder: "Сообщение", text: $draft, isLocked: model.isSending,
                            canSend: !model.isSending && app.isOnline && (1...4000).contains(SettingsText.length(draft))
                                && model.conversation != nil,
                            draftIdentifier: "chat.draft", sendIdentifier: "chat.send") {
                    Task { if await model.send(draft, using: app) { draft = ""; sentCount += 1 } }
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: sentCount)
        }
        .navigationTitle(model.conversation?.title ?? "Сообщения")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if let conversation = model.conversation {
                // Who the chat is with, and under the name what is known for
                // certain about it.
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(conversation.title).font(.headline).lineLimit(1)
                        if let subtitle = subtitle(conversation) {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.conversationMembers(conversation.id)) {
                        if conversation.kind == "direct", let partner = partner(conversation) {
                            AvatarView(card: partner, size: 30)
                        } else {
                            Image(systemName: "person.2")
                        }
                    }
                    .accessibilityLabel("Участники чата")
                }
            }
        }
        .sheet(item: $report) { ReportContentView(target: $0).compactSheet() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.load(using: app)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                await model.load(using: app, poll: true)
            }
        }
    }

    private func partner(_ conversation: Conversation) -> PlayerCard? {
        conversation.members.first { $0.player.id != app.me?.userId }?.player
    }

    private func subtitle(_ conversation: Conversation) -> String? {
        switch conversation.kind {
        case "direct": partner(conversation)?.username.map { "@" + $0 }
        case "game": "Чат игры"
        default: Format.count(conversation.members.count, "участник", "участника", "участников")
        }
    }

    /// The furthest message anyone else in the chat has read.
    private var readByOthers: Int64 {
        model.conversation?.members.filter { $0.player.id != app.me?.userId }.compactMap(\.lastReadId).max() ?? 0
    }

    /// The day a run of messages belongs to, once, centred above them.
    private func dayHeader(_ date: Date) -> some View {
        Text(Self.dayTitle(date))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Theme.inset, in: .capsule)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .accessibilityAddTraits(.isHeader)
    }

    static func dayTitle(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Сегодня" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Вчера"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let style = sameYear ? Date.FormatStyle().day().month(.wide) : Date.FormatStyle().day().month(.wide).year()
        return date.formatted(style.locale(Format.locale))
    }

    /// The viewer's own lines sit on lime to the right, everyone else's on a
    /// surface to the left; each carries the time it was sent, and the
    /// viewer's own show whether they were read. Lines one person sends in a
    /// row sit close together. A group names the sender above the first of
    /// them and shows the avatar beside the last; a chat between two people
    /// does neither, as its title already says who it is.
    private func messageRow(_ message: ChatMessage, opensRun: Bool, closesRun: Bool) -> some View {
        let mine = message.sender.id == app.me?.userId
        let inGroup = !mine && model.conversation?.kind != "direct"
        let time = message.createdAt.formatted(Date.FormatStyle().hour().minute().locale(Format.locale))
        let read = mine && message.id <= readByOthers
        let detail = mine ? Theme.ink.opacity(0.62) : Color.secondary
        // The time sits at the end of the last line; an invisible copy of it
        // after the text keeps that corner free.
        let reserved = Text(verbatim: "   " + time + (mine ? "     " : "")).font(.caption2).foregroundStyle(.clear)
        return HStack(alignment: .bottom, spacing: 6) {
            if mine { Spacer(minLength: 48) }
            if inGroup {
                if closesRun { AvatarView(card: message.sender, size: 28) } else { Color.clear.frame(width: 28, height: 1) }
            }
            VStack(alignment: .leading, spacing: 3) {
                if inGroup, opensRun {
                    NavigationLink(value: Route.player(message.sender.id)) {
                        Text(message.sender.displayName).font(.caption.bold()).foregroundStyle(Theme.accent).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
                Text("\(Text(message.deleted ? "Сообщение скрыто" : message.body))\(reserved)")
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    // The message itself, without the room kept for the time.
                    .accessibilityLabel(message.deleted ? "Сообщение скрыто" : message.body)
                    .overlay(alignment: .bottomTrailing) {
                        HStack(spacing: 3) {
                            Text(time)
                            if mine {
                                // One mark: the server has it. Two: someone read it.
                                HStack(spacing: -4.5) {
                                    Image(systemName: "checkmark")
                                    if read { Image(systemName: "checkmark") }
                                }
                                .accessibilityElement()
                                .accessibilityLabel(read ? "Прочитано" : "Отправлено")
                            }
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(detail)
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(mine ? Theme.ink : Color.primary)
            .background(mine ? AnyShapeStyle(Theme.lime) : AnyShapeStyle(Theme.surface),
                        in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: mine || !closesRun ? 18 : 6,
                                                   bottomTrailingRadius: mine && closesRun ? 6 : 18, topTrailingRadius: 18,
                                                   style: .continuous))
            .contextMenu {
                if !mine {
                    Button("Пожаловаться", systemImage: "flag") { report = ReportTarget(type: "message", id: String(message.id)) }
                }
            }
            if !mine { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(.top, opensRun ? 8 : 2)
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
            SheetNavigationStack {
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
