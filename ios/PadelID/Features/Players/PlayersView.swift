import SwiftUI

/// The "Игроки" tab: partner suggestions, recent partners and player search
/// with filters, sorting and pagination.
struct PlayersView: View {
    @Environment(AppModel.self) private var app
    @State private var model = PlayersDirectoryModel()
    @State private var searchText = ""
    @State private var filter = PlayersFilter()
    @State private var sort: PlayersSort = .compatibility
    @State private var isFilterPresented = false

    init() {}

    var body: some View {
        NavigationStack {
            List {
                if isResultsMode {
                    resultsSection
                } else {
                    browseSections
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if !isResultsMode {
                    browseOverlay
                }
            }
            .navigationTitle("Игроки")
            .searchable(text: $searchText, prompt: "Имя или @username")
            .autocorrectionDisabled()
            .toolbar { toolbarContent }
            .task(id: taskID) { await run(taskID) }
            .refreshable { await refresh() }
            .sheet(isPresented: $isFilterPresented) {
                PlayersFilterSheet(filter: filter, myCity: myCity) { newFilter in
                    filter = newFilter
                }
            }
            .sensoryFeedback(.selection, trigger: sort)
            .padelRoutes()
        }
    }

    // MARK: - State

    private var myCity: NamedRef? { app.me?.profile?.city }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var activeFilterCount: Int { filter.activeCount(myCity: myCity) }

    /// Default state (no query, default filters and sort) shows suggestions.
    private var isResultsMode: Bool {
        !trimmedQuery.isEmpty || activeFilterCount > 0 || sort != .compatibility
    }

    private var searchKey: PlayersSearchKey {
        PlayersSearchKey(text: trimmedQuery, filter: filter, myCity: myCity, sort: sort)
    }

    private var taskID: PlayersTaskID {
        isResultsMode
            ? .results(searchKey, revision: app.dataRevision)
            : .browse(cityId: myCity?.id, revision: app.dataRevision)
    }

    private func run(_ id: PlayersTaskID) async {
        switch id {
        case .browse(let cityId, let revision):
            model.clearResults()
            await model.loadBrowse(cityId: cityId, revision: revision, using: app, force: false)
        case .results(let key, let revision):
            guard !model.isCurrent(key, revision: revision) else { return }
            // Debounce typing; a newer key cancels this task.
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            await model.search(key, revision: revision, using: app)
        }
    }

    private func refresh() async {
        switch taskID {
        case .browse(let cityId, let revision):
            await model.loadBrowse(cityId: cityId, revision: revision, using: app, force: true)
        case .results(let key, let revision):
            await model.search(key, revision: revision, using: app)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Сортировка", selection: $sort) {
                    ForEach(PlayersSort.allCases) { option in
                        Label(option.title, systemImage: option.symbol)
                            .tag(option)
                    }
                }
            } label: {
                Label("Сортировка", systemImage: "arrow.up.arrow.down")
            }
            .accessibilityValue(sort.title)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isFilterPresented = true
            } label: {
                filterButtonLabel
            }
            .accessibilityLabel(filterButtonAccessibilityLabel)
            .accessibilityIdentifier("players.filters")
        }
    }

    @ViewBuilder
    private var filterButtonLabel: some View {
        let count = activeFilterCount
        if count > 0 {
            Text("\(Image(systemName: "line.3.horizontal.decrease")) \(count)")
                .monospacedDigit()
                .foregroundStyle(Theme.accent)
        } else {
            Image(systemName: "line.3.horizontal.decrease")
        }
    }

    private var filterButtonAccessibilityLabel: String {
        let count = activeFilterCount
        return count > 0 ? "Фильтры, активных: \(count)" : "Фильтры"
    }

    // MARK: - Default state

    /// Suggestions without players already listed under "Вы играли вместе".
    private var suggestedCards: [PlayerCard] {
        guard let items = model.suggested.value?.items else { return [] }
        let recentIds = Set((model.recent.value ?? []).map(\.id))
        return items.filter { !recentIds.contains($0.id) }
    }

    private var hasBrowseContent: Bool {
        !suggestedCards.isEmpty || !(model.recent.value ?? []).isEmpty
    }

    private var showsBrowseOfflineBanner: Bool {
        hasBrowseContent
            && ((model.suggested.isStale && model.suggested.error?.isNetwork == true)
                || (model.recent.isStale && model.recent.error?.isNetwork == true))
    }

    @ViewBuilder
    private var browseSections: some View {
        if showsBrowseOfflineBanner {
            Section {
                OfflineBanner()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
        let suggestions = suggestedCards
        if !suggestions.isEmpty {
            Section {
                ForEach(suggestions) { card in
                    playerLink(card)
                }
            } header: {
                Text("Подходят вам")
            } footer: {
                Text(myCity == nil
                     ? "Подбор по уровню, сторонам корта и стилю игры."
                     : "Игроки из вашего города: подбор по уровню, сторонам корта и стилю игры.")
            }
        }
        if let recent = model.recent.value, !recent.isEmpty {
            Section("Вы играли вместе") {
                ForEach(recent) { card in
                    playerLink(card, subtitle: recentSubtitle(card))
                }
            }
        }
    }

    /// Error of a default-state request that has nothing to show.
    private var browseError: APIError? {
        if model.suggested.value == nil, let error = model.suggested.error { return error }
        if model.recent.value == nil, let error = model.recent.error { return error }
        return nil
    }

    @ViewBuilder
    private var browseOverlay: some View {
        if hasBrowseContent {
            EmptyView()
        } else if model.suggested.value != nil && model.recent.value != nil {
            ContentUnavailableView {
                Label("Найдите партнёров", systemImage: "person.2")
            } description: {
                Text("Ищите игроков по имени или @username. Фильтры помогут подобрать уровень и сторону корта.")
            }
        } else if let error = browseError {
            ErrorStateView(error: error) {
                Task {
                    await model.loadBrowse(cityId: myCity?.id, revision: app.dataRevision, using: app, force: true)
                }
            }
        } else {
            LoadingView()
        }
    }

    private func recentSubtitle(_ card: PlayerCard) -> String? {
        guard let together = card.matchesTogether, together > 0 else { return nil }
        var parts: [String] = []
        if let username = card.username { parts.append("@" + username) }
        parts.append(Format.count(together, "общий матч", "общих матча", "общих матчей"))
        return parts.joined(separator: " · ")
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsSection: some View {
        let key = searchKey
        Section {
            if !model.items.isEmpty {
                if model.key == key, let error = model.error {
                    resultsErrorNotice(error)
                }
                ForEach(model.items) { card in
                    playerLink(card)
                        .onAppear {
                            if card.id == model.items.last?.id {
                                Task { await model.loadMore(using: app) }
                            }
                        }
                }
                if model.isLoadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                } else if let loadMoreError = model.loadMoreError {
                    loadMoreRetryRow(loadMoreError)
                }
            } else if model.key == key, let error = model.error, !model.isLoading {
                ErrorStateView(error: error) {
                    Task { await model.search(key, revision: app.dataRevision, using: app) }
                }
                .listRowBackground(Color.clear)
            } else if model.loadedKey == key, !model.isLoading {
                emptyResults
                    .listRowBackground(Color.clear)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .listRowBackground(Color.clear)
                    .accessibilityLabel("Поиск игроков")
            }
        } header: {
            filterSummaryHeader
        }
    }

    @ViewBuilder
    private func resultsErrorNotice(_ error: APIError) -> some View {
        if error.isNetwork {
            OfflineBanner(message: "Нет подключения. Показаны прежние результаты.")
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        } else {
            Label(error.message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func loadMoreRetryRow(_ error: APIError) -> some View {
        Button {
            Task { await model.loadMore(using: app) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Показать ещё")
                    .foregroundStyle(Theme.accent)
                Text(error.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var emptyResults: some View {
        if trimmedQuery.isEmpty {
            ContentUnavailableView {
                Label("Никого не нашли", systemImage: "person.2.slash")
            } description: {
                Text(activeFilterCount > 0 ? "Попробуйте изменить фильтры." : "Здесь пока никого нет.")
            } actions: {
                if activeFilterCount > 0 {
                    Button("Сбросить фильтры") {
                        filter = PlayersFilter()
                    }
                    .buttonStyle(.bordered)
                }
            }
        } else {
            VStack(spacing: 0) {
                ContentUnavailableView.search(text: trimmedQuery)
                if filter.cityScope.resolve(myCity: myCity) != nil {
                    Button("Искать во всех городах") {
                        filter.cityScope = .all
                    }
                    .buttonStyle(.bordered)
                    .padding(.bottom, 16)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Filter summary

    private var filterSummary: String {
        var parts: [String] = [filter.cityScope.resolve(myCity: myCity)?.name ?? "Все города"]
        if filter.hasLevelRange {
            parts.append("уровень \(Format.level(filter.minLevel))–\(Format.level(filter.maxLevel))")
        }
        switch filter.side {
        case .anySide: break
        case .right: parts.append("справа")
        case .left: parts.append("слева")
        }
        if filter.reliableOnly { parts.append("надёжный рейтинг") }
        if filter.coachesOnly { parts.append("тренеры") }
        return parts.joined(separator: " · ")
    }

    private var resultsCountText: String? {
        guard model.loadedKey == searchKey, model.total > 0 else { return nil }
        return Format.count(model.total, "игрок", "игрока", "игроков")
    }

    private var filterSummaryHeader: some View {
        Button {
            isFilterPresented = true
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                Text(filterSummary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if let count = resultsCountText {
                    Text(count)
                        .monospacedDigit()
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .accessibilityLabel(filterSummaryAccessibilityLabel)
        .accessibilityHint("Открывает фильтры")
    }

    private var filterSummaryAccessibilityLabel: String {
        var text = "Фильтры: \(filterSummary)"
        if let count = resultsCountText { text += ". Найдено: \(count)" }
        return text
    }

    // MARK: - Rows

    private func playerLink(_ card: PlayerCard, subtitle: String? = nil) -> some View {
        NavigationLink(value: Route.player(card.id)) {
            PlayerRow(card: card, subtitle: subtitle) {
                PlayersRowTrailing(card: card)
            }
        }
        .accessibilityIdentifier("playerRow")
    }
}

/// Level chip and, when known, compatibility with the current user.
private struct PlayersRowTrailing: View {
    let card: PlayerCard

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            LevelChip(level: card.level, reliability: card.reliability)
            if let compatibility = card.compatibility {
                Text(String(compatibility) + "%")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(compatibilityLabel(compatibility))
            }
        }
    }

    private func compatibilityLabel(_ value: Int) -> String {
        "Совместимость " + String(value) + "%"
    }
}
