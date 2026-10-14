import SwiftUI

/// The "Padel ID" tab: the player's identity, level, rating trend, Padel DNA,
/// insights and statistics at a glance.
struct AnalysisView: View {
    var embedded = false
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if embedded { dashboard }
            else { NavigationStack { dashboard } }
        }
    }

    private var dashboard: some View {
            ZStack {
                if let me = app.me {
                    HomeDashboard(meId: me.userId)
                        .id(me.userId)
                } else {
                    LoadingView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
            .navigationTitle("Анализ")
            .navigationBarTitleDisplayMode(.large)
            .padelRoutes()
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
            // The player card and what awaits an answer live on the Home;
            // this screen starts with the analysis itself.
            if model.home.isStale, let error = model.home.error {
                StaleDataBanner(error: error)
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

// MARK: - Level hero

/// The player's ID: who they are and what level they play at, on the lime of
/// the app icon. Opens the rating history.
struct HomeLevelHero: View {
    let meId: UUID
    let profile: Profile
    let rating: RatingSummary?
    let matches: Int
    var body: some View {
        NavigationLink(value: Route.rating(meId)) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(profile.displayName)
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            if profile.isCoach {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.subheadline)
                                    .accessibilityLabel("Тренер")
                            }
                        }
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right")
                        .font(.footnote.weight(.bold))
                        .frame(width: 32, height: 32)
                        .background(Theme.ink.opacity(0.1), in: .circle)
                        .accessibilityHidden(true)
                }

                Text("Ваш уровень")
                    .font(.subheadline.weight(.medium))
                    .padding(.top, 26)
                LevelNumeral(level: level, size: 76)
                if let level {
                    // One word: shrink it to the card rather than break it.
                    Text(LevelBand(level: level).title)
                        .font(.display(.title3, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }

                if rating != nil {
                    Rectangle().fill(Theme.ink.opacity(0.12)).frame(height: 1)
                        .padding(.top, 20).padding(.bottom, 14)
                    footer
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .limeCard(cornerRadius: 30)
            .contentShape(.rect(cornerRadius: 30, style: .continuous))
            .zoomSource(.rating(meId))
        }
        .buttonStyle(.padelCard)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Открывает историю рейтинга")
        .accessibilityIdentifier("home.level")
    }

    private var level: Double? { rating?.mu ?? profile.level }

    private var subtitle: String {
        var parts: [String] = []
        if let username = profile.username, !username.isEmpty { parts.append("@" + username) }
        if let city = profile.city?.name { parts.append(city) }
        return parts.joined(separator: ", ")
    }

    private var showsTrend: Bool {
        guard let rating else { return false }
        return abs(rating.trend30d) >= 0.005 || matches > 0
    }

    /// Side by side while both fit on one line; one above the other at
    /// larger text sizes, so nothing pushes the card wider than the screen.
    @ViewBuilder
    private var footer: some View {
        if let rating {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    reliability(rating)
                    Spacer(minLength: 8)
                    trend(rating)
                }
                VStack(alignment: .leading, spacing: 12) { reliability(rating); trend(rating) }
            }
        }
    }

    private func reliability(_ rating: RatingSummary) -> some View {
        HStack(spacing: 10) {
            PerforationGrid(filled: PerforationGrid.holes(for: rating.reliability), dot: 8, gap: 4, fillsIn: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "Надёжность \(rating.reliability)%")
                    .font(.subheadline.weight(.semibold))
                if rating.provisional {
                    Text("Предварительный рейтинг")
                        .font(.footnote)
                        .foregroundStyle(Theme.inkSoft)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func trend(_ rating: RatingSummary) -> some View {
        if showsTrend {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(Format.delta(rating.trend30d, digits: 2))
                    .font(.subheadline.weight(.bold)).monospacedDigit()
                Text("за 30 дней")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessibilityText: String {
        var parts = [profile.displayName, "Уровень \(Format.level(level))"]
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

// MARK: - Card header

private struct HomeCardHeader: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.display(.headline, weight: .semibold))
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
                    .fixedSize(horizontal: false, vertical: true)
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
                        .accessibilityIdentifier("home.insights")
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
                    RecentFormSummary(stats: stats)
                }
            }
            .tappableCard()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Открывает подробную статистику")
        .accessibilityIdentifier("home.stats")
    }

    @ViewBuilder
    private var tiles: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 14) {
                matchesTile
                winRateTile
            }
        } else {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow {
                    matchesTile
                    winRateTile
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
            .fontWidth(.expanded)
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
                .buttonStyle(.padelProminent)
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
