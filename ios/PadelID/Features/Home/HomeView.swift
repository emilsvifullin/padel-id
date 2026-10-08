import SwiftUI

/// The "Padel ID" tab: the player's identity, level, rating trend, Padel DNA,
/// insights and statistics at a glance.
struct HomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            ZStack {
                if let me = app.me {
                    HomeDashboard(meId: me.userId)
                        .id(me.userId)
                } else {
                    LoadingView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Padel ID")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    accountButton
                }
            }
            .padelRoutes()
        }
    }

    private var accountButton: some View {
        Button {
            app.isAccountPresented = true
        } label: {
            if let profile = app.me?.profile {
                AvatarView(profile: profile, size: 30)
            } else {
                Image(systemName: "person.crop.circle")
            }
        }
        .accessibilityLabel("Аккаунт")
        .accessibilityIdentifier("home.account")
    }
}

// MARK: - Data

/// Owns the two resources of the home screen and the post-load side effects
/// (tab badge and local notifications).
private final class HomeScreenModel {
    let home: Resource<HomeResponse>
    let history: Resource<RatingHistory>

    init(meId: UUID) {
        home = Resource<HomeResponse>(cacheKey: CacheKey.home) { .get("v1/home") }
        let path = "v1/players/\(meId.uuidString.lowercased())/rating-history"
        history = Resource<RatingHistory>(cacheKey: CacheKey.ratingHistory(meId, days: 90)) {
            .get(path, query: [URLQueryItem(name: "days", value: "90")])
        }
    }

    func loadHome(app: AppModel) async {
        await home.load(using: app)
        guard home.error == nil, !home.isStale, let value = home.value else { return }
        app.actionCount = value.actionItems.count
        await NotificationService.shared.process(actionItems: value.actionItems)
    }

    func loadHistory(app: AppModel) async {
        await history.load(using: app)
    }

    func refresh(app: AppModel) async {
        let historyLoad = Task { await self.history.load(using: app) }
        await loadHome(app: app)
        await historyLoad.value
    }
}

// MARK: - Dashboard

private struct HomeDashboard: View {
    let meId: UUID
    @Environment(AppModel.self) private var app
    @State private var model: HomeScreenModel

    init(meId: UUID) {
        self.meId = meId
        _model = State(initialValue: HomeScreenModel(meId: meId))
    }

    var body: some View {
        ZStack {
            if let home = model.home.value {
                ScrollView {
                    sections(home)
                }
                .refreshable { [model = self.model, app = self.app] in
                    await model.refresh(app: app)
                }
            } else if let error = model.home.error {
                ErrorStateView(error: error) {
                    Task { await model.refresh(app: app) }
                }
            } else {
                LoadingView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: app.dataRevision) { await model.loadHome(app: app) }
        .task(id: app.dataRevision) { await model.loadHistory(app: app) }
    }

    private func sections(_ home: HomeResponse) -> some View {
        let matches = home.stats?.matches ?? 0
        let isNewUser = matches == 0
        let insights = home.insights.compactMap { Narratives.insight($0) }
        return VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            VStack(alignment: .leading, spacing: 14) {
                if model.home.isStale, model.home.error?.isNetwork == true {
                    OfflineBanner()
                }
                HomeIdentityHeader(profile: home.profile)
                HomeLevelHero(meId: meId, profile: home.profile, rating: home.rating, matches: matches)
                if !home.actionItems.isEmpty {
                    HomeActionsRow(count: home.actionItems.count) {
                        app.selectedTab = .matches
                    }
                }
            }
            if isNewUser {
                HomeWelcomeBlock {
                    app.matchEditor = .blank
                }
            } else {
                HomeRatingBlock(meId: meId, history: model.history)
            }
            if let dna = home.dna {
                HomeDNABlock(meId: meId, dna: dna)
            }
            if !isNewUser {
                if !insights.isEmpty {
                    HomeInsightsBlock(insights: insights)
                }
                if let stats = home.stats {
                    HomeStatsBlock(meId: meId, stats: stats)
                }
            }
        }
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.top, 4)
        .padding(.bottom, 32)
    }
}

// MARK: - Identity

private struct HomeIdentityHeader: View {
    let profile: Profile

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(profile.displayName)
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                if profile.isCoach {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel("Тренер")
                }
            }
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let username = profile.username, !username.isEmpty { parts.append("@" + username) }
        if let city = profile.city?.name { parts.append(city) }
        if let club = profile.club?.name { parts.append(club) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Level hero

private struct HomeLevelHero: View {
    let meId: UUID
    let profile: Profile
    let rating: RatingSummary?
    let matches: Int

    var body: some View {
        NavigationLink(value: Route.rating(meId)) {
            SectionContainer(padding: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    HomeCardHeader(title: "Уровень")
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 16) {
                            levelBlock
                            Spacer(minLength: 12)
                            reliabilityBlock
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            levelBlock
                            reliabilityBlock
                        }
                    }
                    if let rating, showsTrend {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            DeltaText(delta: rating.trend30d)
                            Text("за 30 дней")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .tappableCard()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Открывает историю рейтинга")
        .accessibilityIdentifier("home.level")
    }

    private var level: Double? { rating?.mu ?? profile.level }

    private var showsTrend: Bool {
        guard let rating else { return false }
        return abs(rating.trend30d) >= 0.005 || matches > 0
    }

    private var levelBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            LevelNumeral(level: level, size: 64)
                .padding(.bottom, 6)
                .overlay(alignment: .bottomLeading) {
                    Capsule()
                        .fill(Theme.ball)
                        .frame(width: 40, height: 4)
                }
            if let level {
                Text(LevelBand(level: level).title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var reliabilityBlock: some View {
        if let rating {
            HStack(spacing: 12) {
                ReliabilityRing(reliability: rating.reliability, size: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Надёжность \(rating.reliability)%")
                        .font(.subheadline.weight(.semibold))
                    if rating.provisional {
                        Text("Предварительный рейтинг")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var accessibilityText: String {
        var parts = ["Уровень \(Format.level(level))"]
        if let level { parts.append(LevelBand(level: level).title) }
        if let rating {
            parts.append("Надёжность \(rating.reliability)%")
            if rating.provisional { parts.append("Предварительный рейтинг") }
            if showsTrend { parts.append("За 30 дней \(Format.delta(rating.trend30d))") }
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Matches awaiting a response

private struct HomeActionsRow: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "bell.badge.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.attention)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Theme.attention.opacity(0.14), in: .rect(cornerRadius: Theme.smallCornerRadius, style: .continuous))
            .contentShape(.rect(cornerRadius: Theme.smallCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Открывает раздел «Матчи»")
        .accessibilityIdentifier("home.actions")
    }

    private var title: String {
        "\(Format.matches(count)) \(Format.plural(count, "ждёт", "ждут", "ждут")) вашего ответа"
    }
}

// MARK: - Card header

private struct HomeCardHeader: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Rating

private struct HomeRatingBlock: View {
    let meId: UUID
    let history: Resource<RatingHistory>

    var body: some View {
        NavigationLink(value: Route.rating(meId)) {
            SectionContainer {
                VStack(alignment: .leading, spacing: 12) {
                    HomeCardHeader(title: "Рейтинг", detail: "90 дней")
                    chartArea
                }
            }
            .tappableCard()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Открывает историю рейтинга")
        .accessibilityIdentifier("home.rating")
    }

    @ViewBuilder
    private var chartArea: some View {
        if let value = history.value {
            if value.points.count >= 2 {
                RatingChart(points: value.points, compact: true)
                    .frame(height: 150)
            } else {
                Text(emptyText(value))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if history.error != nil {
            Text("Не удалось загрузить график. Потяните экран вниз, чтобы обновить.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .frame(height: 150)
        }
    }

    private func emptyText(_ history: RatingHistory) -> String {
        if history.points.contains(where: { $0.kind == "match" }) {
            return "За последние 90 дней рейтинговых матчей не было."
        }
        return "График начнётся после первого подтверждённого рейтингового матча."
    }
}

// MARK: - Padel DNA

private struct HomeDNABlock: View {
    let meId: UUID
    let dna: PadelDNA

    var body: some View {
        NavigationLink(value: Route.dna(meId)) {
            SectionContainer {
                VStack(alignment: .leading, spacing: 16) {
                    HomeCardHeader(title: "Padel DNA")
                    if !dna.dimensions.isEmpty {
                        DNAHexagon(dimensions: dna.dimensions)
                            .frame(maxWidth: 240)
                            .frame(maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(archetype.title)
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(archetype.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    extremes
                    if isCoachVerified {
                        Label("Подтверждено тренером", systemImage: "checkmark.seal.fill")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            .tappableCard()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Открывает подробности Padel DNA")
        .accessibilityIdentifier("home.dna")
    }

    private var archetype: DNAArchetype { DNAArchetype(rawValue: dna.archetype) ?? .forming }

    private var isCoachVerified: Bool { dna.dimensions.contains { $0.coachVerifiedAt != nil } }

    private var confident: [DNADimensionState] {
        dna.dimensions.filter { $0.confidence >= 0.3 && $0.dimension != nil }
    }

    @ViewBuilder
    private var extremes: some View {
        let states = confident
        if states.count >= 2,
           let strongest = states.max(by: { $0.offset < $1.offset }),
           let weakest = states.min(by: { $0.offset < $1.offset }),
           strongest.key != weakest.key,
           let strongDimension = strongest.dimension,
           let weakDimension = weakest.dimension {
            VStack(alignment: .leading, spacing: 10) {
                HomeDNAExtremeLine(caption: "Сильная сторона", dimension: strongDimension, offset: strongest.offset,
                                   symbol: "arrow.up.circle.fill", tint: Theme.positive)
                HomeDNAExtremeLine(caption: "Зона роста", dimension: weakDimension, offset: weakest.offset,
                                   symbol: "arrow.down.circle.fill", tint: Theme.attention)
            }
        } else if archetype != .forming {
            Text("Профиль уточнится, когда партнёры и соперники отметят ваши сильные стороны после подтверждённых матчей.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct HomeDNAExtremeLine: View {
    let caption: String
    let dimension: DNADimension
    let offset: Double
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(dimension.title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            DeltaText(delta: offset)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(Format.delta(offset)) к общему уровню")
    }
}

// MARK: - Insights

private struct HomeInsightsBlock: View {
    let insights: [InsightText]

    var body: some View {
        SectionContainer {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Анализ")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    if insights.count > 3 {
                        NavigationLink(value: Route.insights) {
                            Text("Все")
                                .font(.subheadline.weight(.semibold))
                                .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                                .contentShape(.rect)
                        }
                        .accessibilityLabel("Весь анализ")
                    }
                }
                ForEach(Array(insights.prefix(3).enumerated()), id: \.offset) { index, insight in
                    if index > 0 {
                        Divider()
                    }
                    HomeInsightRow(insight: insight)
                }
            }
        }
    }
}

// MARK: - Statistics

private struct HomeStatsBlock: View {
    let meId: UUID
    let stats: PlayerStats
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationLink(value: Route.stats(meId)) {
            SectionContainer {
                VStack(alignment: .leading, spacing: 14) {
                    HomeCardHeader(title: "Статистика")
                    tiles
                }
            }
            .tappableCard()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Открывает подробную статистику")
    }

    @ViewBuilder
    private var tiles: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 14) {
                matchesTile
                winRateTile
                formTile
                streakTile
            }
        } else {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow {
                    matchesTile
                    winRateTile
                }
                GridRow {
                    formTile
                    streakTile
                }
            }
        }
    }

    private var matchesTile: some View {
        HomeStatTile(title: "Матчи") {
            Text(verbatim: "\(stats.matches)")
                .homeStatValueStyle()
        }
    }

    private var winRateTile: some View {
        HomeStatTile(title: "Процент побед") {
            Text(Format.percent(Double(stats.wins) / Double(max(stats.matches, 1))))
                .homeStatValueStyle()
        }
    }

    private var formTile: some View {
        HomeStatTile(title: "Форма") {
            HomeFormDots(form: stats.form)
                .frame(minHeight: 24, alignment: .leading)
        }
    }

    private var streakTile: some View {
        HomeStatTile(title: "Текущая серия") {
            if let streak = stats.streak {
                Text(HomeStreakText.text(streak))
                    .homeStatValueStyle()
                    .foregroundStyle(HomeStreakText.color(streak))
            } else {
                Text(verbatim: "—")
                    .homeStatValueStyle()
            }
        }
    }
}

private struct HomeStatTile<Value: View>: View {
    let title: String
    @ViewBuilder var value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            value
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private extension Text {
    func homeStatValueStyle() -> some View {
        self
            .font(.title3.weight(.semibold))
            .fontDesign(.rounded)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - New player

private struct HomeWelcomeBlock: View {
    let onAddMatch: () -> Void

    var body: some View {
        SectionContainer(padding: 20) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Как начинается рейтинг")
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Стартовый уровень рассчитан по анкете. Дальше его меняют только подтверждённые рейтинговые матчи.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 14) {
                    HomeWelcomePoint(symbol: "checkmark.seal",
                                     text: "Внесите счёт матча 2×2 — он засчитается, когда его подтвердят все четыре игрока.")
                    HomeWelcomePoint(symbol: "chart.line.uptrend.xyaxis",
                                     text: "Каждый рейтинговый матч сдвигает уровень с учётом силы партнёра и соперников.")
                    HomeWelcomePoint(symbol: "gauge.with.dots.needle.67percent",
                                     text: "С каждым матчем растёт надёжность — рейтинг становится точнее.")
                }
                Button(action: onAddMatch) {
                    Text("Внести первый матч")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("home.firstMatch")
            }
        }
    }
}

private struct HomeWelcomePoint: View {
    let symbol: String
    let text: String
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 26

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.accent)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
