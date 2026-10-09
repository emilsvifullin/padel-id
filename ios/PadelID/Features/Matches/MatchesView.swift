import SwiftUI

/// History filter of the Matches tab (maps to the `type` query parameter).
private nonisolated enum MatchesHistoryFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all, ranked, friendly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Все"
        case .ranked: "Рейтинговые"
        case .friendly: "Товарищеские"
        }
    }

    var matchType: MatchType? {
        switch self {
        case .all: nil
        case .ranked: .ranked
        case .friendly: .friendly
        }
    }
}

/// Matches tab: unsent changes, matches awaiting the user's answer, matches
/// awaiting the other players and the confirmed history.
struct MatchesView: View {
    @Environment(AppModel.self) private var app

    @State private var open = Resource<MatchPage>(cacheKey: CacheKey.openMatches) {
        Endpoint.get("v1/matches", query: [URLQueryItem(name: "scope", value: "open")])
    }
    @State private var history = MatchesListPager.history(type: nil)
    @State private var filter: MatchesHistoryFilter = .all

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Матчи")
                .toolbar { toolbarContent }
                .padelRoutes()
        }
        .task(id: app.dataRevision) {
            await loadOpen()
        }
        .task(id: "\(app.dataRevision).\(filter.rawValue)") {
            if history.type != filter.matchType {
                history = MatchesListPager.history(type: filter.matchType)
            }
            await history.load(using: app)
        }
        .onChange(of: app.outbox.operations) {
            updateActionCount()
        }
        .sensoryFeedback(.selection, trigger: filter)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if hasContent {
            list
        } else if let error = blockingError {
            ErrorStateView(error: error) {
                Task { await reload() }
            }
            .background(Color(.systemGroupedBackground))
        } else {
            LoadingView()
                .background(Color(.systemGroupedBackground))
        }
    }

    private var list: some View {
        List {
            if let error = staleError {
                StaleDataBanner(error: error)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if !app.outbox.operations.isEmpty {
                outboxSection
            }
            if !actionItems.isEmpty {
                Section {
                    ForEach(actionItems) { item in
                        matchLink(item, note: actionNote(item), showsPendingStatus: false)
                    }
                } header: {
                    Text("Нужен ваш ответ")
                }
            }
            if !waitingItems.isEmpty {
                Section {
                    ForEach(waitingItems) { item in
                        matchLink(item, note: waitingNote(item), showsPendingStatus: false)
                    }
                } header: {
                    Text("Ждут подтверждения")
                }
            } else if open.value == nil, let error = open.error {
                Section {
                    loadFailureRow(error) {
                        Task { await loadOpen() }
                    }
                } header: {
                    Text("Ждут подтверждения")
                }
            }
            if !isEverythingEmpty {
                historySection
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await reload() }
        .overlay {
            if isEverythingEmpty {
                ContentUnavailableView {
                    Label("Пока нет матчей", systemImage: "sportscourt")
                } description: {
                    Text("Внесите первый матч — после подтверждения всеми игроками он появится в истории.")
                } actions: {
                    Button("Внести матч") {
                        app.matchEditor = .blank
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("История", selection: $filter) {
                    ForEach(MatchesHistoryFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Фильтр истории",
                      systemImage: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .accessibilityLabel("Фильтр истории")
            .accessibilityValue(filter.title)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                app.matchEditor = .blank
            } label: {
                Label("Новый матч", systemImage: "plus")
            }
            .accessibilityLabel("Новый матч")
            .accessibilityIdentifier("matches.new")
        }
    }

    // MARK: - Rows

    /// `showsPendingStatus: false` in the open sections, whose header already
    /// says that the matches wait for confirmation.
    private func matchLink(_ item: MatchListItem, note: MatchesRowNote?, showsPendingStatus: Bool = true) -> some View {
        NavigationLink(value: Route.match(item.id)) {
            VStack(alignment: .leading, spacing: 8) {
                MatchRowView(item: item, perspectiveTeam: item.myTeam, showsPendingStatus: showsPendingStatus)
                if let note {
                    Label(note.text, systemImage: note.symbol)
                        .font(.footnote)
                        .foregroundStyle(note.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier("matchRow")
    }

    private func loadFailureRow(_ error: APIError, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(error.message, systemImage: error.isNetwork ? "wifi.slash" : "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Повторить", action: retry)
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Outbox

    private var outboxSection: some View {
        Section {
            ForEach(app.outbox.operations) { operation in
                // The operation being sent cannot be withdrawn any more.
                let isSending = operation.id == app.outbox.inFlightId
                outboxRow(operation, isSending: isSending)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !isSending {
                            Button("Удалить", systemImage: "trash", role: .destructive) {
                                app.outbox.discard(operation.id)
                            }
                        }
                    }
                    .contextMenu {
                        Button("Удалить", systemImage: "trash", role: .destructive) {
                            app.outbox.discard(operation.id)
                        }
                        .disabled(isSending)
                    }
            }
            if !app.outbox.pending.isEmpty {
                Button {
                    Task { await app.flushOutbox() }
                } label: {
                    HStack {
                        Label("Отправить сейчас", systemImage: "arrow.up.circle")
                        Spacer()
                        if app.outbox.isProcessing {
                            ProgressView()
                        }
                    }
                    .frame(minHeight: 44)
                }
                .disabled(!app.isOnline || app.outbox.isProcessing)
            }
        } header: {
            Text("Не отправлено")
        } footer: {
            Text(outboxFooter)
        }
    }

    private func outboxRow(_ operation: PendingOperation, isSending: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol(for: operation.kind))
                .font(.body)
                .foregroundStyle(operation.failure == nil ? Theme.accent : Theme.attention)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(operation.title)
                    .font(.body.weight(.medium))
                Text(operation.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let failure = operation.failure {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(Theme.negative)
                } else {
                    Text(isSending ? "Отправляется" : pendingStateText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if operation.failure != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.attention)
                    .accessibilityHidden(true)
            } else if isSending {
                ProgressView()
            } else {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var pendingStateText: String {
        app.isOnline ? "Ожидает отправки" : "Отправится при подключении"
    }

    private func symbol(for kind: PendingOperation.Kind) -> String {
        switch kind {
        case .createMatch: "square.and.pencil"
        case .confirmMatch: "checkmark.circle"
        case .disputeMatch: "exclamationmark.bubble"
        case .submitFeedback: "hand.thumbsup"
        }
    }

    private var outboxFooter: String {
        var lines: [String] = []
        if !app.outbox.failed.isEmpty {
            lines.append("Сервер не принял отмеченные изменения. Удалите их и при необходимости выполните действие ещё раз.")
        }
        if !app.outbox.pending.isEmpty {
            lines.append(app.isOnline
                ? "Изменения отправляются автоматически."
                : "Изменения сохранены на устройстве и отправятся автоматически, когда появится интернет.")
        }
        return lines.joined(separator: " ")
    }

    // MARK: - History

    private var historySection: some View {
        Section {
            let items = history.items
            if items.isEmpty {
                if history.hasValue {
                    Text(historyEmptyText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else if let error = history.firstPage.error {
                    loadFailureRow(error) {
                        Task { await history.load(using: app) }
                    }
                } else {
                    progressRow
                }
            } else {
                ForEach(items) { item in
                    matchLink(item, note: nil)
                }
                if history.canLoadMore {
                    if let error = history.loadMoreError {
                        loadFailureRow(error) {
                            Task { await history.loadMore(using: app) }
                        }
                    } else {
                        progressRow
                            .task(id: history.nextBefore) {
                                await history.loadMore(using: app)
                            }
                    }
                }
            }
        } header: {
            Text(historyTitle)
        }
    }

    private var progressRow: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .frame(minHeight: 44)
        .accessibilityLabel("Загрузка")
    }

    private var historyTitle: String {
        filter == .all ? "История" : "История · \(filter.title.lowercased())"
    }

    private var historyEmptyText: String {
        switch filter {
        case .all: "Здесь появятся матчи, подтверждённые всеми игроками."
        case .ranked: "Подтверждённых рейтинговых матчей пока нет."
        case .friendly: "Подтверждённых товарищеских матчей пока нет."
        }
    }

    // MARK: - Data

    private var openItems: [MatchListItem] { open.value?.items ?? [] }

    private var actionItems: [MatchListItem] {
        openItems.filter { $0.needsAction && !MatchActions.hasQueuedAnswer(for: $0.id, app: app) }
    }

    private var waitingItems: [MatchListItem] {
        openItems.filter { !$0.needsAction || MatchActions.hasQueuedAnswer(for: $0.id, app: app) }
    }

    private var hasContent: Bool {
        open.value != nil || history.hasValue || !app.outbox.operations.isEmpty
    }

    private var blockingError: APIError? {
        guard !open.isLoading, !history.firstPage.isLoading else { return nil }
        return open.error ?? history.firstPage.error
    }

    private var isEverythingEmpty: Bool {
        guard let openPage = open.value, let historyPage = history.firstPage.value else { return false }
        return filter == .all && openPage.items.isEmpty && historyPage.items.isEmpty
            && app.outbox.operations.isEmpty
    }

    /// Why cached matches are shown (offline, or a server error).
    private var staleError: APIError? {
        if open.isStale, let error = open.error { return error }
        if history.firstPage.isStale, let error = history.firstPage.error { return error }
        return nil
    }

    private func loadOpen() async {
        await open.load(using: app)
        updateActionCount()
    }

    /// Pull to refresh and retry: everything from the first page.
    private func reload() async {
        await app.flushOutbox()
        await loadOpen()
        await history.load(using: app, reset: true)
    }

    private func updateActionCount() {
        guard open.value != nil else { return }
        app.actionCount = actionItems.count
    }

    // MARK: - Notes

    private func actionNote(_ item: MatchListItem) -> MatchesRowNote? {
        if item.status == .disputed && item.isCreator {
            let who = disputeText(item).map { "\($0). " } ?? ""
            return MatchesRowNote(text: who + "Исправьте счёт или отмените матч.", symbol: "exclamationmark.bubble",
                                  color: Theme.negative)
        }
        if let expiresAt = item.expiresAt {
            return MatchesRowNote(text: "Ответьте до \(Format.shortDate(expiresAt))", symbol: "clock",
                                  color: Color.secondary)
        }
        return nil
    }

    private func waitingNote(_ item: MatchListItem) -> MatchesRowNote? {
        if MatchActions.hasQueuedAnswer(for: item.id, app: app) {
            return MatchesRowNote(text: "Ваш ответ отправится при подключении", symbol: "icloud.and.arrow.up",
                                  color: Color.secondary)
        }
        if item.status == .disputed {
            return MatchesRowNote(text: disputeText(item) ?? "Результат оспорен",
                                  symbol: "exclamationmark.bubble", color: Theme.negative)
        }
        let waiting = item.players.filter { $0.response == .pending }
        guard !waiting.isEmpty else { return nil }
        let text = waiting.count <= 2
            ? "Ждём ответа: \(waiting.map { MatchesNames.short($0.player) }.joined(separator: ", "))"
            : "Ждём ответа: \(Format.count(waiting.count, "игрок", "игрока", "игроков"))"
        return MatchesRowNote(text: text, symbol: "clock", color: Color.secondary)
    }

    /// "Оспаривает: Иван П." / "Оспаривают: Иван П., Мария С."
    private func disputeText(_ item: MatchListItem) -> String? {
        let names = item.players.filter { $0.response == .disputed }.map { MatchesNames.short($0.player) }
        guard !names.isEmpty else { return nil }
        let verb = names.count == 1 ? "Оспаривает" : "Оспаривают"
        return "\(verb): \(names.joined(separator: ", "))"
    }
}

/// A short status line under a match row.
private struct MatchesRowNote {
    let text: String
    let symbol: String
    let color: Color
}
