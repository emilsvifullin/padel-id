import SwiftUI

/// Chooses a player for a line-up position: recent partners and opponents,
/// all players alphabetically, or a search by name and username.
struct EditorPlayerPicker: View {
    let title: String
    let current: PlayerCard?
    let excluded: Set<UUID>
    var allowedPlayers: [PlayerCard]?
    let onSelect: (PlayerCard?) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var recent = Resource<[PlayerCard]>(cacheKey: CacheKey.recentPlayers) {
        .get("v1/players/recent", query: [URLQueryItem(name: "limit", value: "20")])
    }
    @State private var friends = Resource<FriendsResponse>(cacheKey: CacheKey.friends) { .get("v1/friends") }
    @State private var directory = EditorPlayerDirectory()

    init(title: String, current: PlayerCard?, excluded: Set<UUID>, allowedPlayers: [PlayerCard]? = nil, onSelect: @escaping (PlayerCard?) -> Void) {
        self.title = title
        self.current = current
        self.excluded = excluded
        self.allowedPlayers = allowedPlayers
        self.onSelect = onSelect
    }

    private var searchText: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        let text = searchText
        NavigationStack {
            List {
                if !app.isOnline {
                    OfflineBanner(message: "Нет подключения. Поиск заработает, когда появится сеть.")
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                if current != nil {
                    clearSection
                }
                if let allowedPlayers {
                    Section("Участники игры") {
                        ForEach(allowedPlayers.filter { !excluded.contains($0.id) && (text.isEmpty || $0.displayName.localizedCaseInsensitiveContains(text)) }) { card in
                            playerButton(card, subtitle: nil)
                        }
                    }
                } else if text.isEmpty {
                    browseContent
                } else {
                    searchContent(for: text)
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.immediately)
            .safeAreaBar(edge: .top, spacing: 0) {
                searchField
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
        .task { if allowedPlayers == nil { await recent.load(using: app) } }
        .task { if allowedPlayers == nil { await friends.load(using: app) } }
        .task(id: text) {
            guard allowedPlayers == nil else { return }
            if !text.isEmpty {
                do {
                    try await Task.sleep(for: .milliseconds(300))
                } catch {
                    return
                }
            }
            await directory.load(query: text, app: app)
        }
    }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Имя или @имя_пользователя", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityLabel("Поиск игрока")
                .accessibilityIdentifier("picker.search")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Очистить поиск")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(minHeight: 44)
        .background(Color(.tertiarySystemFill), in: .capsule)
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: Sections

    private var clearSection: some View {
        Section {
            Button(role: .destructive) {
                onSelect(nil)
                dismiss()
            } label: {
                Label("Убрать из состава", systemImage: "person.crop.circle.badge.minus")
            }
            .accessibilityIdentifier("picker.clear")
        }
    }

    /// Empty query: recent partners and opponents, then everyone else A–Z.
    @ViewBuilder
    private var browseContent: some View {
        let accepted = (friends.value?.accepted ?? []).map(\.player).filter { !excluded.contains($0.id) }
        let friendIds = Set(accepted.map(\.id))
        let recents = (recent.value ?? []).filter { !excluded.contains($0.id) && !friendIds.contains($0.id) }
        let recentIds = Set(recents.map(\.id))
        let others = directory.loadedQuery == ""
            ? directory.items.filter { !excluded.contains($0.id) && !recentIds.contains($0.id) && !friendIds.contains($0.id) }
            : []
        if !accepted.isEmpty {
            Section("Друзья") { ForEach(accepted) { card in playerButton(card, subtitle: nil) } }
        }
        if !recents.isEmpty {
            Section("Недавние") {
                ForEach(recents) { card in
                    playerButton(card, subtitle: recentSubtitle(card))
                }
            }
        }
        if !others.isEmpty {
            Section("Все игроки") {
                ForEach(others) { card in
                    playerButton(card, subtitle: nil)
                        .onAppear {
                            if card.id == others.last?.id { loadMore() }
                        }
                }
                loadMoreRow
            }
        }
        if accepted.isEmpty && recents.isEmpty && others.isEmpty {
            browseStatus
        }
    }

    @ViewBuilder
    private var browseStatus: some View {
        if directory.loadedQuery != "" || directory.isLoading || recent.isLoading {
            loadingRow
        } else if let error = directory.error ?? recent.error {
            ErrorStateView(error: error, retry: retry)
                .listRowBackground(Color.clear)
        } else {
            ContentUnavailableView("Пока некого выбрать", systemImage: "person.2",
                                   description: Text("Найдите игрока по имени или имени пользователя."))
                .listRowBackground(Color.clear)
        }
    }

    /// Search results; the previous results stay visible (dimmed) while the
    /// next query loads.
    @ViewBuilder
    private func searchContent(for text: String) -> some View {
        let isCurrent = directory.loadedQuery == text
        let hasSearchResults = !(directory.loadedQuery ?? "").isEmpty
        let results = hasSearchResults ? directory.items.filter { !excluded.contains($0.id) } : []
        if !results.isEmpty {
            Section {
                ForEach(results) { card in
                    playerButton(card, subtitle: nil)
                        .opacity(isCurrent ? 1 : 0.5)
                        .onAppear {
                            if isCurrent && card.id == results.last?.id { loadMore() }
                        }
                }
                if isCurrent {
                    loadMoreRow
                }
            }
        } else if !isCurrent || directory.isLoading {
            loadingRow
        } else if let error = directory.error {
            ErrorStateView(error: error, retry: retry)
                .listRowBackground(Color.clear)
        } else {
            ContentUnavailableView("Никого не нашли", systemImage: "magnifyingglass",
                                   description: Text("Проверьте имя или имя пользователя. Скрытые профили видны только тем, с кем игрок уже играл."))
                .listRowBackground(Color.clear)
        }
    }

    // MARK: Rows

    private func playerButton(_ card: PlayerCard, subtitle: String?) -> some View {
        Button {
            onSelect(card)
            dismiss()
        } label: {
            PlayerRow(card: card, subtitle: subtitle) {
                LevelChip(level: card.level, reliability: card.reliability)
            }
            // A concrete colour: `.primary` would resolve to the button's
            // tint and paint the names in the accent colour.
            .foregroundStyle(Color.primary)
            .contentShape(.rect)
        }
        .accessibilityIdentifier("picker.player")
    }

    private var loadingRow: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .padding(.vertical, 12)
        .listRowBackground(Color.clear)
        .accessibilityLabel("Загрузка")
    }

    @ViewBuilder
    private var loadMoreRow: some View {
        if directory.isLoadingMore {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .accessibilityLabel("Загрузка")
        } else if directory.loadMoreFailed {
            Button("Загрузить ещё", action: loadMore)
        }
    }

    private func recentSubtitle(_ card: PlayerCard) -> String? {
        var parts: [String] = []
        if let username = card.username { parts.append("@\(username)") }
        if let together = card.matchesTogether, together > 0 {
            parts.append("\(Format.matches(together)) вместе")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func loadMore() {
        Task { await directory.loadMore(app: app) }
    }

    private func retry() {
        let text = searchText
        Task {
            if recent.value == nil {
                await recent.load(using: app)
            }
            await directory.load(query: text, app: app)
        }
    }
}

/// Paged player search (`v1/players/search`): alphabetical for an empty
/// query, by relevance otherwise.
@Observable
final class EditorPlayerDirectory {
    private(set) var items: [PlayerCard] = []
    /// The query the items belong to (nil until the first response).
    private(set) var loadedQuery: String?
    private(set) var nextOffset: Int?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var loadMoreFailed = false
    private(set) var error: APIError?

    @ObservationIgnored private var generation = 0

    func load(query: String, app: AppModel) async {
        generation += 1
        let current = generation
        isLoading = true
        do {
            let page = try await app.api.send(Self.endpoint(query: query, offset: 0), as: SearchResult.self)
            guard current == generation else { return }
            items = page.items
            nextOffset = page.nextOffset
            error = nil
        } catch is CancellationError {
            if current == generation { isLoading = false }
            return
        } catch let apiError as APIError {
            guard current == generation else { return }
            items = []
            nextOffset = nil
            error = apiError
        } catch {
            guard current == generation else { return }
            items = []
            nextOffset = nil
            self.error = APIError(kind: .decoding, code: "decoding", serverMessage: nil)
        }
        loadedQuery = query
        loadMoreFailed = false
        isLoading = false
    }

    func loadMore(app: AppModel) async {
        guard !isLoading, !isLoadingMore, let offset = nextOffset, let query = loadedQuery else { return }
        let current = generation
        isLoadingMore = true
        loadMoreFailed = false
        defer { isLoadingMore = false }
        do {
            let page = try await app.api.send(Self.endpoint(query: query, offset: offset), as: SearchResult.self)
            guard current == generation else { return }
            let known = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !known.contains($0.id) })
            nextOffset = page.nextOffset
        } catch is CancellationError {
            return
        } catch {
            guard current == generation else { return }
            loadMoreFailed = true
        }
    }

    private static func endpoint(query: String, offset: Int) -> Endpoint {
        var items = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "20"),
        ]
        if query.isEmpty {
            items.append(URLQueryItem(name: "sort", value: "name"))
        }
        if offset > 0 {
            items.append(URLQueryItem(name: "offset", value: String(offset)))
        }
        return .get("v1/players/search", query: items)
    }
}
