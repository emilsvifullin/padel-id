import SwiftUI

struct FeedView: View {
    var groupId: UUID? = nil
    var clubId: Int? = nil
    var clubName: String? = nil
    /// The root of the Community tab: adds the shortcuts and the tab's title.
    var isHub = false
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var posts: CommunityCollection<CommunityPost>
    @State private var collectionKey: String
    @State private var scope = "all"
    @State private var composing = false
    init(groupId: UUID? = nil, clubId: Int? = nil, clubName: String? = nil, isHub: Bool = false) {
        self.groupId = groupId
        self.clubId = clubId
        self.clubName = clubName
        self.isHub = isHub
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if isHub {
                    CommunityShortcuts().padding(.bottom, 6)
                    SuggestedPlayersRow().padding(.bottom, 6)
                    SectionHeader("Лента")
                }
                if groupId == nil && clubId == nil {
                    Picker("Лента", selection: $scope) {
                        Text("Все").tag("all")
                        Text("Подписки").tag("following")
                    }
                    .pickerStyle(.segmented)
                    .padding(.bottom, 4)
                }
                if let clubName {
                    Text(clubName).font(.display(.title3, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
                ForEach(posts.items) { post in
                    NavigationLink(value: Route.post(post.id)) {
                        PostSummary(post: post, bodyLineLimit: 8)
                            .padding(18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.surface, in: .rect(cornerRadius: Theme.cornerRadius, style: .continuous))
                            .contentShape(.rect(cornerRadius: Theme.cornerRadius, style: .continuous))
                            .zoomSource(.post(post.id))
                    }
                    .buttonStyle(.padelCard)
                    .accessibilityIdentifier("feed.post")
                }
                VStack(spacing: 12) { CommunityCollectionFooter(collection: posts) }
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, Theme.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 28)
            .padelAnimation(value: posts.items.map(\.id))
        }
        .padelCanvas()
        .navigationTitle(isHub ? "Сообщество" : clubId != nil ? "Новости клуба" : groupId == nil ? "Лента" : "Публикации группы")
        .toolbar {
            if isHub {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.socialInbox) { Label("Уведомления", systemImage: "bell") }
                        .accessibilityIdentifier("community.inbox")
                }
            }
            if clubId == nil || app.me?.isAdmin == true {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Публикация", systemImage: "square.and.pencil") { composing = true }
                        .disabled(!app.isOnline).accessibilityIdentifier("feed.publish")
                }
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

/// A post as it reads in the feed and at the top of its own screen.
struct PostSummary: View {
    let post: CommunityPost
    /// The feed shows the start of a long post; the post's own screen shows all of it.
    var bodyLineLimit: Int? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AvatarView(card: post.author, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(post.author.displayName).font(.subheadline.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Text(post.createdAt, format: .dateTime.day().month().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if post.visibility == "friends" {
                    Image(systemName: "person.2.fill").font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Для друзей")
                }
            }
            if let club = post.club {
                StatusPill(text: club.name, color: Theme.accent, symbol: "building.2.fill")
                    .accessibilityIdentifier("post.club")
            }
            Text(post.body)
                .lineLimit(bodyLineLimit)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                Label(String(post.reactionCount), systemImage: post.myReaction == nil ? "heart" : "heart.fill")
                    .foregroundStyle(post.myReaction == nil ? Color.secondary : Theme.negative)
                    .accessibilityLabel("Реакций: \(post.reactionCount)")
                Label(String(post.commentCount), systemImage: "bubble.right")
                    .accessibilityLabel("Комментариев: \(post.commentCount)")
            }
            .font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
        }
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
                        .buttonStyle(.padelPrimary).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let value = post.value {
                    postCard(value)
                    SectionHeader("Комментарии").padding(.top, 4)
                    ForEach(comments.items) { comment in commentRow(comment) }
                    VStack(spacing: 12) { CommunityCollectionFooter(collection: comments) }
                        .frame(maxWidth: .infinity)
                } else if let failure = post.error {
                    ErrorStateView(error: failure) { Task { await load() } }
                } else {
                    LoadingView()
                }
                if let error { SettingsErrorRow(message: error) }
            }
            .padding(.horizontal, Theme.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .padelAnimation(value: comments.items.map(\.id))
        }
        .padelCanvas()
        .safeAreaBar(edge: .bottom) {
            if post.value != nil {
                ComposerBar(placeholder: "Комментарий", text: $draft, isLocked: isWorking,
                            canSend: !isWorking && app.isOnline && (1...1000).contains(SettingsText.length(draft)),
                            draftIdentifier: "post.comment", sendIdentifier: "post.sendComment") { comment() }
            }
        }
        .navigationTitle("Публикация")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
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
        .sheet(item: $report) { ReportContentView(target: $0).compactSheet() }
        .alert("Удалить публикацию?", isPresented: $confirmingDelete) {
            Button("Удалить", role: .destructive) { removePost() }
            Button("Отмена", role: .cancel) {}
        }
    }
    private func postCard(_ value: CommunityPost) -> some View {
        let liked = value.myReaction != nil
        return VStack(alignment: .leading, spacing: 16) {
            PostSummary(post: value)
            Divider()
            HStack(spacing: 10) {
                Button {
                    react(value.myReaction == "like" ? nil : "like")
                } label: {
                    Label(liked ? "Нравится · \(value.reactionCount)" : "Нравится", systemImage: liked ? "heart.fill" : "heart")
                        .symbolEffect(.bounce, value: liked)
                        .contentTransition(.symbolEffect(.replace))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(liked ? Theme.negative : Color.primary)
                        .padding(.horizontal, 14).frame(minHeight: 40)
                        .background(Theme.inset, in: .capsule)
                }
                .buttonStyle(.padelCard)
                .sensoryFeedback(.impact(weight: .light), trigger: liked)
                Menu {
                    Button("Поздравляю", systemImage: "hands.clap") { react("celebrate") }
                    Button("Поддерживаю", systemImage: "hand.thumbsup") { react("support") }
                    Button("Убрать реакцию", systemImage: "xmark") { react(nil) }
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .background(Theme.inset, in: .circle)
                }
                .accessibilityLabel("Другие реакции")
                Spacer(minLength: 8)
                Menu {
                    NavigationLink(value: Route.player(value.author.id)) { Label("Профиль автора", systemImage: "person.crop.circle") }
                    if value.author.id == app.me?.userId {
                        Button("Удалить публикацию", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                    } else {
                        Button("Пожаловаться", systemImage: "flag") { report = ReportTarget(type: "post", id: id.uuidString) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .background(Theme.inset, in: .circle)
                }
                .accessibilityLabel("Ещё")
            }
            .disabled(isWorking || !app.isOnline)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    private func commentRow(_ comment: PostComment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(card: comment.author, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                NavigationLink(value: Route.player(comment.author.id)) {
                    Text(comment.author.displayName).font(.subheadline.bold())
                }
                .buttonStyle(.plain)
                Text(comment.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(comment.createdAt, format: .dateTime.day().month().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                if comment.author.id == app.me?.userId {
                    Button("Удалить", systemImage: "trash", role: .destructive) { removeComment(comment.id) }
                } else {
                    Button("Пожаловаться", systemImage: "flag") { report = ReportTarget(type: "comment", id: comment.id.uuidString) }
                }
            } label: {
                Image(systemName: "ellipsis").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 44, height: 36)
            }
            .disabled(isWorking)
            .accessibilityLabel("Действия с комментарием")
        }
        .padding(14)
        .background(Theme.surface, in: .rect(cornerRadius: 20, style: .continuous))
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
