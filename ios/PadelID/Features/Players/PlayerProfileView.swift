import SwiftUI

/// Public profile of any player: level, compatibility with the viewer,
/// Padel DNA, statistics, recent matches and coach assessments.
struct PlayerProfileView: View {
    let playerId: UUID

    @Environment(AppModel.self) private var app
    @State private var profile: Resource<PlayerProfileResponse>
    @State private var myDNA: [DNADimensionState]?
    @State private var isAssessing = false
    @State private var showsTitle = false
    @State private var savedAssessments = 0

    init(playerId: UUID) {
        self.playerId = playerId
        let path = "v1/players/\(playerId.uuidString.lowercased())"
        _profile = State(initialValue: Resource(cacheKey: CacheKey.player(playerId)) { .get(path) })
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) { actionArea }
            .task(id: app.dataRevision) {
                loadMyDNA()
                await profile.load(using: app)
            }
            .sheet(isPresented: $isAssessing) { assessmentSheet }
            .sensoryFeedback(.success, trigger: savedAssessments)
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        if let value = profile.value {
            if value.deleted {
                deletedState
            } else {
                loaded(value)
            }
        } else if let error = profile.error {
            ErrorStateView(error: error) {
                Task { await profile.load(using: app) }
            }
        } else {
            LoadingView()
        }
    }

    private var deletedState: some View {
        ContentUnavailableView {
            Label("Удалённый игрок", systemImage: "person.crop.circle.badge.xmark")
        } description: {
            Text("Аккаунт этого игрока удалён. Сыгранные с ним матчи остаются в истории участников, но профиль больше недоступен.")
        }
    }

    private func loaded(_ value: PlayerProfileResponse) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                if profile.isStale, profile.error?.isNetwork == true {
                    OfflineBanner()
                }
                PlayerProfileHeader(profile: value.profile)
                levelBlock(value)
                if !isMe(value), let compatibility = value.compatibility {
                    compatibilityBlock(compatibility, name: value.profile.displayName)
                }
                if let dna = value.dna {
                    dnaBlock(dna, value: value)
                }
                if let stats = value.stats {
                    statsBlock(stats)
                }
                if let matches = value.recentMatches, !matches.isEmpty {
                    recentMatchesBlock(matches)
                }
                if let assessments = value.coachAssessments, !assessments.isEmpty {
                    assessmentsBlock(assessments)
                }
            }
            .padding(.horizontal, Theme.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 150
        } action: { _, isPastHeader in
            showsTitle = isPastHeader
        }
        .refreshable { await profile.load(using: app) }
    }

    // MARK: - Level

    @ViewBuilder
    private func levelBlock(_ value: PlayerProfileResponse) -> some View {
        let level = value.rating?.mu ?? value.profile.level
        let reliability = value.rating?.reliability ?? value.profile.reliability
        NavigationLink(value: Route.rating(playerId)) {
            SectionContainer {
                VStack(alignment: .leading, spacing: 14) {
                    PlayerProfileBlockTitle(title: "Рейтинг", navigates: true)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 16) {
                            levelSummary(level)
                            Spacer(minLength: 8)
                            reliabilitySummary(reliability)
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            levelSummary(level)
                            reliabilitySummary(reliability)
                        }
                    }
                    if let rating = value.rating {
                        if rating.provisional {
                            Label {
                                Text("Предварительный рейтинг: пока мало рейтинговых матчей, уровень может заметно меняться.")
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "info.circle")
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        if abs(rating.trend30d) >= 0.005 || rating.rankedMatches > 0 {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                DeltaText(delta: rating.trend30d)
                                Text("за 30 дней")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .tappableCard()
        }
        .buttonStyle(.plain)
    }

    private func levelSummary(_ level: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LevelNumeral(level: level, size: 44)
            if let level {
                Text(LevelBand(level: level).title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func reliabilitySummary(_ reliability: Int?) -> some View {
        if let reliability {
            HStack(spacing: 10) {
                ReliabilityRing(reliability: reliability, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Надёжность " + String(reliability) + "%")
                        .font(.subheadline.weight(.medium))
                    Text(ReliabilityBand(reliability).title)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Compatibility

    private func compatibilityBlock(_ compatibility: Compatibility, name: String) -> some View {
        let reasons = Narratives.compatibilityReasons(compatibility, otherName: Self.firstName(name))
        let components = compatibility.components.filter { $0.weight > 0 && Self.componentTitle($0.key) != nil }
        return SectionContainer {
            VStack(alignment: .leading, spacing: 14) {
                PlayerProfileBlockTitle(title: "Совместимость с вами", navigates: false)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(String(compatibility.score) + "%")
                        .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Self.compatibilityTint(compatibility.score))
                    Text(Self.verdict(compatibility.score))
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(compatibilityAccessibilityLabel(compatibility.score))
                if !reasons.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(reasons, id: \.self) { reason in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                Text(reason)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.subheadline)
                        }
                    }
                }
                if !components.isEmpty {
                    PlayerProfileCompatibilityBars(components: components)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profile.compatibility")
    }

    private func compatibilityAccessibilityLabel(_ score: Int) -> String {
        "Совместимость " + String(score) + "%, " + Self.verdict(score)
    }

    static func verdict(_ score: Int) -> String {
        if score >= 75 { return "Отличный партнёр" }
        if score >= 55 { return "Хорошая совместимость" }
        return "Совместимость ниже средней"
    }

    private static func compatibilityTint(_ score: Int) -> Color {
        if score >= 75 { return Theme.positive }
        if score >= 55 { return Theme.accent }
        return Theme.attention
    }

    static func componentTitle(_ key: String) -> String? {
        switch key {
        case "level": "Уровень"
        case "sides": "Стороны"
        case "style": "Стиль"
        case "chemistry": "Сыгранность"
        case "logistics": "География"
        default: nil
        }
    }

    private static func firstName(_ displayName: String) -> String {
        displayName.split(separator: " ").first.map(String.init) ?? displayName
    }

    // MARK: - Padel DNA

    private func dnaBlock(_ dna: PadelDNA, value: PlayerProfileResponse) -> some View {
        let comparison = comparisonDimensions(for: value)
        let archetype = DNAArchetype(rawValue: dna.archetype)
        let hasShape = dna.dimensions.count == DNADimension.allCases.count
        return NavigationLink(value: Route.dna(playerId)) {
            SectionContainer {
                VStack(alignment: .leading, spacing: 12) {
                    PlayerProfileBlockTitle(title: "Padel DNA", navigates: true)
                    if let archetype {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(archetype.title)
                                .font(.title3.weight(.semibold))
                            Text(archetype.summary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if hasShape {
                        DNAHexagon(dimensions: dna.dimensions, comparison: comparison)
                            .frame(maxWidth: 300)
                            .frame(maxWidth: .infinity)
                        if comparison != nil {
                            dnaLegend(name: Self.firstName(value.profile.displayName))
                        }
                    }
                }
            }
            .tappableCard()
        }
        .buttonStyle(.plain)
    }

    private func dnaLegend(name: String) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 3))
                    path.addLine(to: CGPoint(x: 18, y: 3))
                }
                .stroke(Theme.accent, lineWidth: 2)
                .frame(width: 18, height: 6)
                Text(name)
            }
            HStack(spacing: 6) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 3))
                    path.addLine(to: CGPoint(x: 18, y: 3))
                }
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .frame(width: 18, height: 6)
                Text("Вы")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Сплошная линия — \(name), пунктир — вы")
    }

    private func comparisonDimensions(for value: PlayerProfileResponse) -> [DNADimensionState]? {
        guard !isMe(value), let mine = myDNA, mine.count == DNADimension.allCases.count else { return nil }
        return mine
    }

    // MARK: - Statistics

    @ViewBuilder
    private func statsBlock(_ stats: PlayerStats) -> some View {
        if stats.matches > 0 {
            NavigationLink(value: Route.stats(playerId)) {
                SectionContainer {
                    VStack(alignment: .leading, spacing: 14) {
                        PlayerProfileBlockTitle(title: "Статистика", navigates: true)
                        HStack(alignment: .top, spacing: 12) {
                            statTile(value: String(stats.matches),
                                     title: Format.plural(stats.matches, "матч", "матча", "матчей"))
                            statTile(value: Format.percent(Double(stats.wins) / Double(stats.matches)),
                                     title: "побед")
                        }
                        if !stats.form.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Форма")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                PlayerProfileFormRow(form: stats.form)
                            }
                        }
                    }
                }
                .tappableCard()
            }
            .buttonStyle(.plain)
        } else {
            SectionContainer {
                VStack(alignment: .leading, spacing: 8) {
                    PlayerProfileBlockTitle(title: "Статистика", navigates: false)
                    Text("Подтверждённых матчей пока нет.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statTile(value: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Matches

    private func recentMatchesBlock(_ matches: [MatchListItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Последние матчи") {
                NavigationLink(value: Route.playerMatches(playerId)) {
                    Text("Все матчи")
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
            }
            SectionContainer {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Divider()
                        }
                        NavigationLink(value: Route.match(item.id)) {
                            MatchRowView(item: item, perspectiveTeam: item.subjectTeam)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Coach assessments

    private func assessmentsBlock(_ assessments: [CoachAssessment]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Оценки тренеров")
            ForEach(assessments) { assessment in
                PlayerProfileAssessmentCard(assessment: assessment)
            }
            Text("Оценки тренеров подтверждают навыки в Padel DNA и учитываются 180 дней.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    // MARK: - Actions

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let value = profile.value, !value.deleted, !isMe(value) {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        app.matchEditor = MatchEditorRequest(mode: .create(partner: nil, opponents: [value.profile.card]))
                    } label: {
                        Label("Внести матч против игрока", systemImage: "sportscourt")
                    }
                    if value.viewer?.canAssess == true {
                        Button {
                            isAssessing = true
                        } label: {
                            Label("Оценить навыки", systemImage: "checkmark.seal")
                        }
                    }
                } label: {
                    Label("Действия", systemImage: "ellipsis")
                }
            }
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        if let value = profile.value, !value.deleted, !isMe(value) {
            GlassEffectContainer {
                Button {
                    app.matchEditor = MatchEditorRequest(mode: .create(partner: value.profile.card, opponents: []))
                } label: {
                    Label("Внести матч вместе", systemImage: "plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .accessibilityIdentifier("profile.newMatch")
            }
            .padding(.horizontal, Theme.horizontalPadding)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var assessmentSheet: some View {
        if let value = profile.value {
            CoachAssessmentView(player: value.profile.card, dna: value.dna) { response in
                profile.replace(with: response)
                savedAssessments += 1
                app.dataDidChange()
            }
        }
    }

    // MARK: - Helpers

    private var titleText: String {
        guard showsTitle, let value = profile.value, !value.deleted else { return "" }
        return value.profile.displayName
    }

    private func isMe(_ value: PlayerProfileResponse) -> Bool {
        value.viewer?.isMe ?? (playerId == app.me?.userId)
    }

    /// The viewer's own DNA (from the cached home response) for comparison.
    private func loadMyDNA() {
        guard playerId != app.me?.userId else {
            myDNA = nil
            return
        }
        myDNA = app.cache.value(HomeResponse.self, for: CacheKey.home)?.dna?.dimensions
    }
}

// MARK: - Components

private struct PlayerProfileHeader: View {
    let profile: Profile

    var body: some View {
        VStack(spacing: 12) {
            AvatarView(profile: profile, size: 88)
            VStack(spacing: 4) {
                Text(profile.displayName)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                if let username = profile.username {
                    Text("@" + username)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let place = placeLine {
                    Text(place)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let facts = factsLine {
                    Text(facts)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            if profile.isCoach {
                StatusPill(text: "Тренер", color: Theme.accent, symbol: "checkmark.seal.fill")
            }
            if let bio = profile.bio?.trimmingCharacters(in: .whitespacesAndNewlines), !bio.isEmpty {
                Text(bio)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    private var placeLine: String? {
        let parts = [profile.city?.name, profile.club?.name].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var factsLine: String? {
        var parts: [String] = []
        if let side = profile.preferredSide {
            parts.append(Narratives.sideName(side))
        }
        if let hand = profile.dominantHand {
            parts.append(hand == .right ? "правша" : "левша")
        }
        if let since = profile.playingSince {
            parts.append("в паделе с \(since) года")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct PlayerProfileBlockTitle: View {
    let title: String
    let navigates: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if navigates {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Compact bars of the compatibility components that carry weight.
private struct PlayerProfileCompatibilityBars: View {
    let components: [CompatibilityComponent]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(components: [CompatibilityComponent]) {
        self.components = components
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(components, id: \.key) { component in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(PlayerProfileView.componentTitle(component.key) ?? "")
                            .font(.subheadline)
                        bar(component)
                        Text(Format.percent(clamped(component.value)))
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(PlayerProfileView.componentTitle(component.key) ?? "")
                    .accessibilityValue(Format.percent(clamped(component.value)))
                }
            }
        } else {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                ForEach(components, id: \.key) { component in
                    GridRow {
                        Text(PlayerProfileView.componentTitle(component.key) ?? "")
                            .font(.subheadline)
                            .accessibilityHidden(true)
                        bar(component)
                            .accessibilityLabel(PlayerProfileView.componentTitle(component.key) ?? "")
                            .accessibilityValue(Format.percent(clamped(component.value)))
                        Text(Format.percent(clamped(component.value)))
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private func bar(_ component: CompatibilityComponent) -> some View {
        ProgressView(value: clamped(component.value))
            .tint(Theme.accent)
    }

    private func clamped(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}

/// Results of the last confirmed matches as green/red dots, oldest on the
/// left (`form` arrives newest first as "W" / "L").
private struct PlayerProfileFormRow: View {
    let form: [String]
    @ScaledMetric(relativeTo: .body) private var dotSize: CGFloat = 10

    init(form: [String]) {
        self.form = form
    }

    var body: some View {
        let recent = Array(form.prefix(10))
        HStack(spacing: 4) {
            ForEach(Array(recent.reversed().enumerated()), id: \.offset) { _, result in
                Circle()
                    .fill(result == "W" ? Theme.positive : Theme.negative)
                    .frame(width: dotSize, height: dotSize)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Форма")
        .accessibilityValue(accessibilitySummary(recent))
    }

    /// "6 побед, 4 поражения. Последний матч — победа".
    private func accessibilitySummary(_ recent: [String]) -> String {
        guard let last = recent.first else { return "Нет матчей" }
        let wins = recent.filter { $0 == "W" }.count
        let losses = recent.count - wins
        let totals = Format.count(wins, "победа", "победы", "побед") + ", "
            + Format.count(losses, "поражение", "поражения", "поражений")
        return totals + (last == "W" ? ". Последний матч — победа" : ". Последний матч — поражение")
    }
}

private struct PlayerProfileAssessmentCard: View {
    let assessment: CoachAssessment

    var body: some View {
        SectionContainer {
            VStack(alignment: .leading, spacing: 12) {
                NavigationLink(value: Route.player(assessment.coach.id)) {
                    PlayerRow(card: assessment.coach, subtitle: Format.date(assessment.createdAt)) {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(assessment.coach.deleted)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    let scores = scoresByDimension
                    ForEach(DNADimension.allCases) { dimension in
                        if let score = scores[dimension] {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(dimension.title)
                                Spacer(minLength: 8)
                                Text(Format.level(score))
                                    .fontWeight(.semibold)
                                    .monospacedDigit()
                            }
                            .font(.subheadline)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                if let note = assessment.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(note)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Label("Видно только игроку и тренеру", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var scoresByDimension: [DNADimension: Double] {
        var result: [DNADimension: Double] = [:]
        for (key, value) in assessment.scores {
            if let dimension = DNADimension(apiKey: key) {
                result[dimension] = value
            }
        }
        return result
    }
}
