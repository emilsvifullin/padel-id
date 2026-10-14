import SwiftUI

/// Personal activity centre. Upcoming games and sport data have independent
/// resources so a failure in one section does not hide the rest of the home.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var home = Resource<HomeResponse>(cacheKey: CacheKey.home) { .get("v1/home") }
    @State private var upcoming = Resource<UpcomingPage>(cacheKey: CacheKey.upcomingHome) {
        .get("v1/upcoming-matches", query: [URLQueryItem(name: "scope", value: "mine"), URLQueryItem(name: "accepted_only", value: "true")])
    }
    @State private var isCreating = false
    @State private var events = Resource<SportEventsPage>(cacheKey: nil) {
        .get("v1/events", query: [URLQueryItem(name: "scope", value: "mine"),
                                 URLQueryItem(name: "upcoming_only", value: "true")])
    }

    var body: some View {
        PadelNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                    VStack(alignment: .leading, spacing: 14) {
                        if home.isStale, let error = home.error { StaleDataBanner(error: error) }
                        if let profile = home.value?.profile ?? app.me?.profile {
                            HomeLevelHero(meId: profile.id, profile: profile,
                                          rating: home.value?.rating ?? app.me?.rating,
                                          matches: home.value?.stats?.matches ?? 0)
                        }
                        quickActions
                    }
                    if let value = home.value, !value.actionItems.isEmpty {
                        pendingActions(value.actionItems)
                    }
                    upcomingSection
                    upcomingEventSection
                    if let value = home.value {
                        progressSection(value)
                    } else if let error = home.error, home.value == nil {
                        SectionContainer {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Спортивный прогресс").font(.headline)
                                Text(error.message).font(.subheadline).foregroundStyle(Theme.supportingText)
                                Button("Повторить") { Task { await loadHome() } }
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.horizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .padelCanvas()
            .refreshable { await refresh() }
            .navigationTitle("Главная")
            .mainTabTitle()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Настройки", systemImage: "gearshape") { app.isAccountPresented = true }
                        .accessibilityIdentifier("home.settings")
                }
                if let profile = home.value?.profile ?? app.me?.profile {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink(value: Route.player(profile.id)) {
                            Label("Ваш профиль", systemImage: "person.crop.circle")
                        }
                        .accessibilityIdentifier("home.profile")
                    }
                }
            }
            .sheet(isPresented: $isCreating) { UpcomingCreateView() }
            .padelRoutes()
        }
        .task(id: app.dataRevision) { await loadHome() }
        .task(id: app.dataRevision) { await upcoming.load(using: app) }
        .task(id: "\(app.dataRevision):\(scenePhase)") {
            guard scenePhase == .active else { return }
            await events.load(using: app)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await events.load(using: app)
            }
        }
    }

    /// Looking for a game leads, creating one sits next to it, and the two
    /// quieter destinations share a row below; one to a row at accessibility sizes.
    @ViewBuilder
    private var quickActions: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 10) { findGame; createGame; sportsEvents; findPlayers }
        } else {
            VStack(spacing: 10) {
                HStack(spacing: 10) { findGame; createGame.fixedSize(horizontal: true, vertical: false) }
                HStack(spacing: 10) { sportsEvents; findPlayers }
            }
        }
    }

    private var findGame: some View {
        NavigationLink(value: Route.upcomingGames) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.lime)
                    .accessibilityHidden(true)
                Text("Найти игру").font(.headline)
                    .lineLimit(dynamicTypeSize > .xLarge ? nil : 1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: HomeActionMetrics.height)
            .inkCard(cornerRadius: HomeActionMetrics.cornerRadius)
            .contentShape(.rect(cornerRadius: HomeActionMetrics.cornerRadius, style: .continuous))
        }
        .buttonStyle(.padelCard)
        .accessibilityIdentifier("home.findGame")
    }

    private var createGame: some View {
        Button { isCreating = true } label: {
            Label("Создать", systemImage: "plus")
                .font(.headline)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 18)
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, minHeight: HomeActionMetrics.height)
                .background(Theme.lime, in: .rect(cornerRadius: HomeActionMetrics.cornerRadius, style: .continuous))
                .contentShape(.rect(cornerRadius: HomeActionMetrics.cornerRadius, style: .continuous))
                .opacity(app.isOnline ? 1 : 0.5)
        }
        .buttonStyle(.padelCard)
        .disabled(!app.isOnline)
        .accessibilityLabel("Создать игру")
        .accessibilityIdentifier("home.createGame")
    }

    private var sportsEvents: some View {
        NavigationLink(value: Route.sportsEvents) {
            HomeActionTile(title: "Тренировки и турниры", symbol: "trophy")
        }
        .buttonStyle(.padelCard)
        .accessibilityIdentifier("home.events")
    }

    private var findPlayers: some View {
        NavigationLink(value: Route.findPlayers) {
            HomeActionTile(title: "Найти игроков", symbol: "person.2", lines: 1)
        }
        .buttonStyle(.padelCard)
        .accessibilityIdentifier("home.findPlayers")
    }

    private func pendingActions(_ items: [MatchListItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Ждут вашего ответа")
            VStack(spacing: 0) {
                ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { index, match in
                    if index > 0 { Divider().padding(.leading, 70) }
                    NavigationLink(value: Route.match(match.id)) {
                        HStack(spacing: 14) {
                            SymbolPlate(symbol: "checkmark.bubble.fill", tint: Theme.attention)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Результат матча").font(.headline)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(match.playedAt, format: .dateTime.day().month(.wide))
                                    .font(.subheadline).foregroundStyle(Theme.supportingText)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
                            Chevron()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.padelCard)
                    .accessibilityIdentifier("home.pendingMatch")
                }
            }
            .background(Theme.surface, in: .rect(cornerRadius: Theme.cornerRadius, style: .continuous))
            if items.count > 3 {
                Button("Все ожидающие результаты (\(items.count))") { app.selectedTab = .matches }
                    .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            }
        }
    }

    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Ближайшая игра") {
                NavigationLink(value: Route.upcomingGames) {
                    Text("Все")
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
            if upcoming.isStale, let error = upcoming.error { StaleDataBanner(error: error) }
            if let page = upcoming.value {
                if let match = page.items.filter({ $0.viewer.participation == "accepted" && $0.startsAt > .now && !$0.isClosed })
                    .min(by: { $0.startsAt < $1.startsAt }) {
                    NavigationLink(value: Route.upcoming(match.id)) {
                        SectionContainer { UpcomingMatchRow(match: match) }
                            .zoomSource(.upcoming(match.id))
                    }
                    .buttonStyle(.padelCard)
                    .accessibilityIdentifier("home.upcoming")
                } else {
                    SectionContainer {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Следующая игра — впереди", image: PadelSymbol.racket)
                                .font(.headline)
                            Text("Найдите открытую игру или соберите свою. Здесь появится ближайший матч, в котором вы участвуете.")
                                .font(.subheadline).foregroundStyle(Theme.supportingText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityIdentifier("home.empty")
                }
            } else if let error = upcoming.error {
                SectionContainer {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(error.message).font(.subheadline).foregroundStyle(Theme.supportingText)
                        Button("Повторить") { Task { await upcoming.load(using: app) } }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
        }
    }

    @ViewBuilder
    private var upcomingEventSection: some View {
        if let next = events.value?.items.filter({
            $0.startsAt > .now && $0.status == .open &&
            ($0.viewer.isOrganizer || $0.viewer.registration == "accepted")
        }).min(by: { $0.startsAt < $1.startsAt }) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Следующее событие") {
                    NavigationLink("Мои", value: Route.myEvents)
                        .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                }
                if events.isStale, let error = events.error { StaleDataBanner(error: error) }
                NavigationLink(value: Route.event(next.id)) {
                    SectionContainer {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(next.kind.singular, systemImage: next.kind.symbol)
                                .font(.caption.bold()).foregroundStyle(Theme.accent)
                            Text(next.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                            Text(next.startsAt, format: .dateTime.day().month(.wide).hour().minute())
                                .font(.subheadline)
                            Text([next.city.name, next.club?.name, next.location].compactMap { $0 }.joined(separator: ", "))
                                .font(.subheadline).foregroundStyle(Theme.supportingText)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(next.viewer.isOrganizer ? "Вы организуете" : "Вы записаны")
                                .font(.caption).foregroundStyle(Theme.supportingText)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.sportEvent")
            }
        } else if let error = events.error {
            SectionContainer {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Тренировки и турниры").font(.headline)
                    Text(error.message).font(.subheadline).foregroundStyle(Theme.supportingText)
                    Button("Обновить события") { Task { await events.load(using: app) } }
                }
            }
        }
    }

    @ViewBuilder
    private func progressSection(_ value: HomeResponse) -> some View {
        if let stats = value.stats, stats.matches > 0 {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Ваш прогресс") {
                    NavigationLink("Подробнее", value: Route.stats(value.profile.id))
                        .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                }
                NavigationLink(value: Route.stats(value.profile.id)) {
                    SectionContainer { RecentFormSummary(stats: stats) }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.progress")
            }
        }
    }

    private func loadHome() async {
        await home.load(using: app)
        guard home.error == nil, !home.isStale, let value = home.value else { return }
        app.actionCount = value.actionItems.count
        await NotificationService.shared.process(actionItems: value.actionItems)
    }

    private func refresh() async {
        // Independent sections refresh together.
        let games = Task { await upcoming.load(using: app) }
        let sports = Task { await events.load(using: app) }
        await loadHome()
        await games.value
        await sports.value
    }
}

private enum HomeActionMetrics {
    static let height: CGFloat = 58
    static let cornerRadius: CGFloat = 22
}

/// A quieter destination on the Home: symbol and title in one line.
private struct HomeActionTile: View {
    let title: String
    let symbol: String
    /// A short title stays on one line, tightened a little on a narrow
    /// screen; a long one may take two.
    var lines = 2
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.leading)
                .lineLimit(dynamicTypeSize > .xLarge ? nil : lines)
                .minimumScaleFactor(lines == 1 && dynamicTypeSize <= .xLarge ? 0.8 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: HomeActionMetrics.height, maxHeight: .infinity)
        .background(Theme.surface, in: .rect(cornerRadius: HomeActionMetrics.cornerRadius, style: .continuous))
        .contentShape(.rect(cornerRadius: HomeActionMetrics.cornerRadius, style: .continuous))
    }
}
