import SwiftUI

struct FeedView: View {
    var groupId: UUID? = nil
    var clubId: Int? = nil
    var clubName: String? = nil
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var posts: CommunityCollection<CommunityPost>
    @State private var collectionKey: String
    @State private var scope = "all"
    @State private var composing = false
    init(groupId: UUID? = nil, clubId: Int? = nil, clubName: String? = nil) {
        self.groupId = groupId
        self.clubId = clubId
        self.clubName = clubName
        _posts = State(initialValue: Self.collection(groupId: groupId, clubId: clubId, scope: "all"))
        _collectionKey = State(initialValue: Self.key(groupId: groupId, clubId: clubId, scope: "all"))
    }
    private static func key(groupId: UUID?, clubId: Int?, scope: String) -> String { "\(groupId?.uuidString ?? "feed"):\(clubId.map(String.init) ?? "all"):\(scope)" }
    private static func collection(groupId: UUID?, clubId: Int?, scope: String) -> CommunityCollection<CommunityPost> {
        var query = [URLQueryItem(name: "scope", value: scope)]
        if let groupId { query.append(URLQueryItem(name: "group_id", value: groupId.uuidString)) }
        if let clubId { query.append(URLQueryItem(name: "club_id", value: String(clubId))) }
        return CommunityCollection("v1/social/feed", query: query, windowLimit: 150)
    }
    var body: some View {
        List {
            if groupId == nil && clubId == nil { Section {
                Picker("Лента", selection: $scope) {
                    Text("Все").tag("all")
                    Text("Подписки").tag("following")
                }.pickerStyle(.segmented)
            } }
            if let clubName {
                Section { Text(clubName).font(.headline).fixedSize(horizontal: false, vertical: true) }
            }
            ForEach(posts.items) { post in
                NavigationLink(value: Route.post(post.id)) { PostSummary(post: post) }
                    .accessibilityIdentifier("feed.post")
            }
            CommunityCollectionFooter(collection: posts)
        }
        .navigationTitle(clubId != nil ? "Новости клуба" : groupId == nil ? "Лента" : "Публикации группы")
        .toolbar {
            if clubId == nil || app.me?.isAdmin == true {
                Button("Публикация", systemImage: "square.and.pencil") { composing = true }
                    .disabled(!app.isOnline).accessibilityIdentifier("feed.publish")
            }
        }
        .sheet(isPresented: $composing) { PostCreateView(groupId: groupId, clubId: clubId, clubName: clubName) }
        .task(id: "\(Self.key(groupId: groupId, clubId: clubId, scope: scope)):\(app.dataRevision):\(scenePhase):\(app.isOnline)") {
            let key = Self.key(groupId: groupId, clubId: clubId, scope: scope)
            if collectionKey != key {
                posts = Self.collection(groupId: groupId, clubId: clubId, scope: scope)
                collectionKey = key
            }
            guard scenePhase == .active, app.isOnline else { return }
            await posts.refreshVisibleWindow(using: app)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard scenePhase == .active, app.isOnline else { return }
                await posts.refreshVisibleWindow(using: app)
            }
        }
        .refreshable { await posts.load(using: app) }
    }
}

struct PostSummary: View {
    let post: CommunityPost
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AvatarView(card: post.author, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(post.author.displayName).font(.subheadline.bold())
                    Text(post.createdAt, format: .dateTime.day().month().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let club = post.club {
                Label(club.name, systemImage: "building.2")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("post.club")
            }
            Text(post.body).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                Label(String(post.reactionCount), systemImage: "heart")
                Label(String(post.commentCount), systemImage: "text.bubble")
                if post.visibility == "friends" { Label("Для друзей", systemImage: "person.2") }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 6)
    }
}

struct PostCreateView: View {
    var groupId: UUID? = nil
    var clubId: Int? = nil
    var clubName: String? = nil
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var bodyText = ""
    @State private var visibility = "public"
    @State private var isWorking = false
    @State private var error: String?
    @State private var pending: PostCreateBody?
    @State private var lastSubmission: PostCreateBody?
    @State private var requestId = UUID()
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let clubName { Label(clubName, systemImage: "building.2").font(.headline) }
                    TextField("Расскажите о паделе", text: $bodyText, axis: .vertical)
                        .lineLimit(5...15)
                        .accessibilityIdentifier("post.draft")
                    SettingsCharacterCount(count: SettingsText.length(bodyText), limit: 4000)
                    if groupId == nil && clubId == nil { Picker("Кто увидит", selection: $visibility) {
                        Text("Все игроки").tag("public")
                        Text("Друзья").tag("friends")
                    } }
                }.disabled(pending != nil)
                if let error { SettingsErrorRow(message: error) }
                Section {
                    Button(pending == nil ? "Опубликовать" : "Повторить публикацию") { publish() }
                        .disabled(isWorking || !app.isOnline || (clubId != nil && app.me?.isAdmin != true) || (pending == nil && !(1...4000).contains(SettingsText.length(bodyText))))
                        .accessibilityIdentifier("post.publish")
                    if isWorking { ProgressView() }
                }
            }
            .navigationTitle(clubId == nil ? "Публикация" : "Новость клуба")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        }
    }
    private func publish() {
        guard !isWorking, clubId == nil || app.me?.isAdmin == true else { return }
        if pending == nil {
            let submission = PostCreateBody(body: SettingsText.trimmed(bodyText), visibility: clubId == nil ? visibility : "public", groupId: groupId, clubId: clubId)
            if let lastSubmission, lastSubmission != submission { requestId = UUID() }
            lastSubmission = submission
            pending = submission
        }
        guard let pending else { return }
        isWorking = true; error = nil
        Task {
            defer { isWorking = false }
            do {
                _ = try await app.api.send(.json(.post, "v1/social/posts", pending, idempotencyKey: requestId), as: CommunityPost.self)
                app.dataDidChange(); dismiss()
            } catch let failure as APIError {
                error = failure.message
                if failure.permitsSubmissionCorrection {
                    self.pending = nil
                }
            }
            catch { self.error = "Не удалось подтвердить публикацию." }
        }
    }
    private nonisolated struct PostCreateBody: Encodable, Equatable, Sendable {
        let body: String
        let visibility: String
        let groupId: UUID?
        let clubId: Int?
    }
}

struct PostDetailView: View {
    let id: UUID
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var post: Resource<CommunityPost>
    @State private var comments: CommunityCollection<PostComment>
    @State private var draft = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var report: ReportTarget?
    @State private var commentKey = UUID()
    @State private var pendingComment: String?
    @State private var confirmingDelete = false
    init(id: UUID) {
        self.id = id
        _post = State(initialValue: Resource(cacheKey: nil) { .get("v1/social/posts/\(id)") })
        _comments = State(initialValue: CommunityCollection("v1/social/posts/\(id)/comments", windowLimit: 150))
    }
    var body: some View {
        List {
            if let value = post.value {
                Section {
                    NavigationLink(value: Route.player(value.author.id)) { PlayerRow(card: value.author) }
                    PostSummary(post: value)
                    HStack {
                        Button(value.myReaction == "like" ? "Нравится · \(value.reactionCount)" : "Нравится", systemImage: value.myReaction == "like" ? "heart.fill" : "heart") {
                            react(value.myReaction == "like" ? nil : "like")
                        }
                        Menu("Другие реакции") {
                            Button("Поздравляю") { react("celebrate") }
                            Button("Поддерживаю") { react("support") }
                            Button("Убрать реакцию") { react(nil) }
                        }
                    }.disabled(isWorking || !app.isOnline)
                    if value.author.id == app.me?.userId {
                        Button("Удалить публикацию", role: .destructive) { confirmingDelete = true }
                    } else {
                        Button("Пожаловаться", systemImage: "flag") { report = ReportTarget(type: "post", id: id.uuidString) }
                    }
                }
                Section("Комментарии") {
                    ForEach(comments.items) { comment in
                        VStack(alignment: .leading, spacing: 6) {
                            NavigationLink(value: Route.player(comment.author.id)) { Text(comment.author.displayName).font(.subheadline.bold()) }
                            Text(comment.body).textSelection(.enabled)
                            if comment.author.id == app.me?.userId {
                                Button("Удалить", role: .destructive) { removeComment(comment.id) }.font(.caption).disabled(isWorking)
                            } else {
                                Button("Пожаловаться") { report = ReportTarget(type: "comment", id: comment.id.uuidString) }.font(.caption)
                            }
                        }
                    }
                    CommunityCollectionFooter(collection: comments)
                    TextField("Комментарий", text: $draft, axis: .vertical).lineLimit(2...5).disabled(isWorking)
                    Button("Отправить") { comment() }
                        .disabled(isWorking || !app.isOnline || !(1...1000).contains(SettingsText.length(draft)))
                }
            } else if let failure = post.error {
                ErrorStateView(error: failure) { Task { await load() } }
            } else { ProgressView() }
            if let error { SettingsErrorRow(message: error) }
        }
        .navigationTitle("Публикация")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(app.dataRevision):\(scenePhase):\(app.isOnline)") {
            guard scenePhase == .active, app.isOnline else { return }
            await load(preserveWindow: true)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard scenePhase == .active, app.isOnline else { return }
                if !isWorking { await load(preserveWindow: true) }
            }
        }
        .onChange(of: comments.error) { _, failure in
            // A pagination request can detect lost access before the post GET.
            if let failure, CommunityCollection<PostComment>.deniesAccess(failure) {
                revokePost(failure)
            }
        }
        .refreshable { await load() }
        .sheet(item: $report) { ReportContentView(target: $0) }
        .alert("Удалить публикацию?", isPresented: $confirmingDelete) {
            Button("Удалить", role: .destructive) { removePost() }
            Button("Отмена", role: .cancel) {}
        }
    }
    private func load(preserveWindow: Bool = false) async {
        await post.load(using: app)
        guard !Task.isCancelled else { return }
        if let failure = post.error, CommunityCollection<PostComment>.deniesAccess(failure) {
            revokePost(failure)
            return
        }
        guard post.value != nil else { return }
        if preserveWindow { await comments.refreshVisibleWindow(using: app) }
        else { await comments.load(using: app) }
        if let failure = comments.error, CommunityCollection<PostComment>.deniesAccess(failure) { revokePost(failure) }
    }
    private func revokePost(_ failure: APIError) {
        // A missing comments collection means its parent post is unavailable.
        let denial = failure.status == 404
            ? APIError(kind: .server(status: 404), code: "post_not_found", serverMessage: nil) : failure
        post.revokeAccess(denial, using: app)
        comments.revokeAccess(denial)
    }
    private func react(_ reaction: String?) {
        mutate(.json(.put, "v1/social/posts/\(id)/reaction", ReactionBody(reaction: reaction), retryable: true))
    }
    private func comment() {
        let body = SettingsText.trimmed(draft)
        if pendingComment != body { commentKey = UUID(); pendingComment = body }
        mutate(.json(.post, "v1/social/posts/\(id)/comments", ["body": body], idempotencyKey: commentKey), clearDraft: true)
    }
    private func removeComment(_ comment: UUID) { mutate(.empty(.delete, "v1/social/comments/\(comment)", retryable: true)) }
    private func removePost() { mutate(.empty(.delete, "v1/social/posts/\(id)", retryable: true), close: true) }
    private func mutate(_ endpoint: Endpoint, clearDraft: Bool = false, close: Bool = false) {
        guard !isWorking else { return }
        isWorking = true; error = nil
        Task {
            defer { isWorking = false }
            do {
                try await app.api.sendVoid(endpoint)
                if clearDraft { draft = ""; pendingComment = nil }
                app.dataDidChange()
                if close { dismiss() } else { await load(preserveWindow: true) }
            } catch let failure as APIError {
                if failure.status == 401 || failure.status == 403 || failure.code == "post_not_found" { revokePost(failure) }
                error = failure.message
            }
            catch { self.error = "Изменение не подтверждено. Попробуйте снова." }
        }
    }
    private nonisolated struct ReactionBody: Encodable, Sendable {
        let reaction: String?
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if let reaction { try container.encode(reaction, forKey: .reaction) }
            else { try container.encodeNil(forKey: .reaction) }
        }
        enum CodingKeys: String, CodingKey { case reaction }
    }
}
