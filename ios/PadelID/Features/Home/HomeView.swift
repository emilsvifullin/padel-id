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
                VStack(alignment: .leading, spacing: 22) {
                    if home.isStale, let error = home.error { StaleDataBanner(error: error) }
                    if let profile = home.value?.profile ?? app.me?.profile {
                        identity(profile)
                        HomeLevelHero(meId: profile.id, profile: profile,
                                      rating: home.value?.rating ?? app.me?.rating,
                                      matches: home.value?.stats?.matches ?? 0)
                    }
                    quickActions
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
                                Text(error.message).font(.subheadline).foregroundStyle(.secondary)
                                Button("Повторить") { Task { await loadHome() } }
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.horizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(Theme.background)
            .refreshable { await refresh() }
            .navigationTitle("Главная")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Настройки", systemImage: "gearshape") { app.isAccountPresented = true }
                        .accessibilityIdentifier("home.settings")
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

    private func identity(_ profile: Profile) -> some View {
        NavigationLink(value: Route.player(profile.id)) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) {
                        AvatarView(profile: profile, size: 52)
                        identityText(profile)
                    }
                } else {
                    HStack(spacing: 12) {
                        identityText(profile)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        AvatarView(profile: profile, size: 52)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Открывает ваш профиль")
        .accessibilityIdentifier("home.profile")
    }

    private func identityText(_ profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Время для падела").font(.subheadline).foregroundStyle(Theme.supportingText)
            Text(profile.displayName).font(.title2.bold())
            if let city = profile.city {
                Label(city.name, systemImage: "mappin.and.ellipse")
                    .font(.caption).foregroundStyle(Theme.supportingText)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var quickActions: some View {
        VStack(spacing: 10) {
            NavigationLink(value: Route.upcomingGames) {
                actionLabel("Найти игру", symbol: "magnifyingglass")
            }
            .buttonStyle(PadelPrimaryButtonStyle())
            .accessibilityIdentifier("home.findGame")
            Button { isCreating = true } label: {
                SectionContainer(padding: 15) { actionLabel("Создать игру", symbol: "plus") }
            }
            .buttonStyle(.plain)
            .disabled(!app.isOnline)
            .accessibilityIdentifier("home.createGame")
        }
    }

    private func actionLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.headline).accessibilityHidden(true)
            Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).accessibilityHidden(true)
        }
        .frame(minHeight: 20)
    }

    private func pendingActions(_ items: [MatchListItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Ждут вашего ответа")
            ForEach(items.prefix(3)) { match in
                NavigationLink(value: Route.match(match.id)) {
                    SectionContainer {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.bubble").foregroundStyle(Theme.accent)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Результат матча").font(.headline)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(match.playedAt, format: .dateTime.day().month(.wide))
                                    .font(.subheadline).foregroundStyle(Theme.supportingText)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.pendingMatch")
            }
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
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.upcoming")
                } else {
                    SectionContainer {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Следующая игра — впереди", systemImage: "tennis.racket")
                                .font(.headline)
                            Text("Найдите открытую игру или соберите свою. Здесь появится ближайший матч, в котором вы участвуете.")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityIdentifier("home.empty")
                }
            } else if let error = upcoming.error {
                SectionContainer {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(error.message).font(.subheadline).foregroundStyle(.secondary)
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
                            Text([next.city.name, next.club?.name, next.location].compactMap { $0 }.joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(next.viewer.isOrganizer ? "Вы организуете" : "Вы записаны")
                                .font(.caption).foregroundStyle(.secondary)
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
                    Text(error.message).font(.subheadline).foregroundStyle(.secondary)
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
