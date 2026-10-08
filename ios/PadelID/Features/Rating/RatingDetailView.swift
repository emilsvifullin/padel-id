import SwiftUI

/// Rating history of any player: chart for a chosen period, summary with
/// reliability and the list of rating changes.
struct RatingDetailView: View {
    let playerId: UUID
    @Environment(AppModel.self) private var app
    @State private var range: RatingDetailRange = .quarter
    @State private var histories: RatingDetailHistories
    @State private var player: Resource<PlayerProfileResponse>

    init(playerId: UUID) {
        self.playerId = playerId
        _histories = State(initialValue: RatingDetailHistories(playerId: playerId))
        let path = "v1/players/\(playerId.uuidString.lowercased())"
        _player = State(initialValue: Resource<PlayerProfileResponse>(cacheKey: CacheKey.player(playerId)) { .get(path) })
    }

    var body: some View {
        List {
            Section {
                Picker("Период", selection: $range) {
                    ForEach(RatingDetailRange.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            content(histories[range])
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Рейтинг")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: range)
        .task(id: RatingDetailLoadKey(range: range, revision: app.dataRevision)) {
            await histories[range].load(using: app)
        }
        .task(id: app.dataRevision) { await player.load(using: app) }
        .refreshable { [history = histories[range], player = self.player, app = self.app] in
            await history.load(using: app)
            await player.load(using: app)
        }
    }

    @ViewBuilder
    private func content(_ resource: Resource<RatingHistory>) -> some View {
        if let history = resource.value {
            if resource.isStale, resource.error?.isNetwork == true {
                Section {
                    OfflineBanner()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            RatingDetailSections(history: history, range: range, rating: player.value?.rating)
        } else if let error = resource.error {
            Section {
                ErrorStateView(error: error) {
                    Task { await resource.load(using: app) }
                }
            }
        } else {
            Section {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 260)
            }
        }
    }
}

// MARK: - Period

private nonisolated enum RatingDetailRange: String, CaseIterable, Identifiable, Hashable, Sendable {
    case month, quarter, year, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .month: "30 дней"
        case .quarter: "90 дней"
        case .year: "Год"
        case .all: "Всё"
        }
    }

    var days: Int? {
        switch self {
        case .month: 30
        case .quarter: 90
        case .year: 365
        case .all: nil
        }
    }

    /// "за 30 дней", "за год", "за всё время".
    var period: String {
        switch self {
        case .month: "за 30 дней"
        case .quarter: "за 90 дней"
        case .year: "за год"
        case .all: "за всё время"
        }
    }
}

private nonisolated struct RatingDetailLoadKey: Hashable, Sendable {
    let range: RatingDetailRange
    let revision: Int
}

/// One cache-first resource per period, created up front so switching periods
/// keeps already loaded data.
private struct RatingDetailHistories {
    let month: Resource<RatingHistory>
    let quarter: Resource<RatingHistory>
    let year: Resource<RatingHistory>
    let all: Resource<RatingHistory>

    init(playerId: UUID) {
        month = Self.make(playerId, range: .month)
        quarter = Self.make(playerId, range: .quarter)
        year = Self.make(playerId, range: .year)
        all = Self.make(playerId, range: .all)
    }

    subscript(range: RatingDetailRange) -> Resource<RatingHistory> {
        switch range {
        case .month: month
        case .quarter: quarter
        case .year: year
        case .all: all
        }
    }

    private static func make(_ playerId: UUID, range: RatingDetailRange) -> Resource<RatingHistory> {
        let path = "v1/players/\(playerId.uuidString.lowercased())/rating-history"
        let days = range.days
        let query: [URLQueryItem] = days.map { [URLQueryItem(name: "days", value: String($0))] } ?? []
        return Resource<RatingHistory>(cacheKey: CacheKey.ratingHistory(playerId, days: days)) {
            .get(path, query: query)
        }
    }
}

// MARK: - Content

private struct RatingDetailSections: View {
    let history: RatingHistory
    let range: RatingDetailRange
    let rating: RatingSummary?

    var body: some View {
        Section {
            if history.points.count >= 2 {
                RatingChart(points: history.points)
                    .frame(height: 260)
                    .padding(.vertical, 8)
            } else {
                Text(emptyChartText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            }
        } footer: {
            if history.points.count >= 2 {
                Text("Линия — уровень, полоса вокруг — погрешность. Точки — рейтинговые матчи: зелёные — победы, красные — поражения.")
            }
        }

        Section {
            RatingDetailSummary(level: currentLevel, sigma: currentSigma, rating: rating)
            if !matchPoints.isEmpty {
                LabeledContent {
                    DeltaText(delta: periodChange, font: .body.weight(.semibold))
                } label: {
                    Text("Изменение \(range.period)")
                }
                LabeledContent {
                    Text(verbatim: "\(matchPoints.count)")
                        .monospacedDigit()
                } label: {
                    Text("Рейтинговые матчи")
                }
                LabeledContent {
                    Text(verbatim: "\(wins) из \(matchPoints.count) · \(Format.percent(Double(wins) / Double(matchPoints.count)))")
                        .monospacedDigit()
                } label: {
                    Text("Победы")
                }
            }
            if let peak = history.peakMu ?? rating?.peakMu {
                LabeledContent {
                    Text(Format.level(peak))
                        .monospacedDigit()
                } label: {
                    Text("Лучший уровень")
                }
            }
        } header: {
            Text("Итоги")
        }

        if !changes.isEmpty {
            Section {
                ForEach(Array(changes.enumerated()), id: \.offset) { _, point in
                    RatingDetailChangeRow(point: point)
                }
            } header: {
                Text("Изменения")
            } footer: {
                Text("«Шансы» — вероятность победы вашей пары по оценке модели до матча. Чем ниже шансы, тем сильнее победа поднимает рейтинг.")
            }
        }
    }

    /// Points inside the selected period. The server also returns the last
    /// event before the period as the starting value of the chart.
    private var pointsInRange: [RatingPoint] {
        guard let days = range.days else { return history.points }
        let start = Date.now.addingTimeInterval(-Double(days) * 86_400)
        return history.points.filter { $0.at >= start }
    }

    private var matchPoints: [RatingPoint] { pointsInRange.filter { $0.kind == "match" } }

    private var wins: Int { matchPoints.filter { $0.won == true }.count }

    private var periodChange: Double { matchPoints.reduce(0) { $0 + ($1.delta ?? 0) } }

    private var changes: [RatingPoint] { Array(pointsInRange.reversed()) }

    private var currentLevel: Double? { rating?.mu ?? history.points.last?.mu }

    private var currentSigma: Double? { rating?.sigma ?? history.points.last?.sigma }

    private var emptyChartText: String {
        if history.points.contains(where: { $0.kind == "match" }) {
            return "За этот период рейтинговых матчей не было."
        }
        return "График начнётся после первого подтверждённого рейтингового матча."
    }
}

private struct RatingDetailSummary: View {
    let level: Double?
    let sigma: Double?
    let rating: RatingSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    levelColumn
                    Spacer(minLength: 12)
                    reliabilityColumn
                }
                VStack(alignment: .leading, spacing: 14) {
                    levelColumn
                    reliabilityColumn
                }
            }
            if let rating {
                Text(RatingDetailSummary.explanation(rating))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }

    private var levelColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Текущий уровень")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            LevelNumeral(level: level, size: 48)
            if let level {
                Text(LevelBand(level: level).title)
                    .font(.headline)
            }
            if let sigma {
                Text(verbatim: "Погрешность ±\(Format.level(sigma))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var reliabilityColumn: some View {
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
            .accessibilityElement(children: .combine)
        }
    }

    static func explanation(_ rating: RatingSummary) -> String {
        var text: String
        switch ReliabilityBand(rating.reliability) {
        case .low:
            text = "Низкая надёжность: данных пока мало, поэтому каждый рейтинговый матч заметно меняет уровень."
        case .medium:
            text = "Средняя надёжность: уровень уточняется — ещё несколько рейтинговых матчей сделают его устойчивым."
        case .high:
            text = "Высокая надёжность: уровень подтверждён многими матчами и меняется плавно."
        }
        if rating.idleDays > 14 {
            text += " Без рейтинговых матчей \(Format.days(rating.idleDays)) — во время перерыва надёжность постепенно снижается."
        }
        return text
    }
}

private struct RatingDetailChangeRow: View {
    let point: RatingPoint

    var body: some View {
        if point.kind == "match", let matchId = point.matchId {
            NavigationLink(value: Route.match(matchId)) {
                matchRow
            }
        } else {
            calibrationRow
        }
    }

    private var matchRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(resultTitle)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                DeltaText(delta: point.delta, font: .body.weight(.semibold))
                Text(Format.level(point.mu))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Уровень после матча \(Format.level(point.mu))")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var calibrationRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Стартовый уровень по анкете")
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(Format.shortDate(point.at))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(Format.level(point.mu))
                .font(.body.weight(.semibold))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private var resultTitle: String {
        switch point.won {
        case .some(true): "Победа"
        case .some(false): "Поражение"
        case .none: "Рейтинговый матч"
        }
    }

    private var detail: String {
        var parts = [Format.shortDate(point.at)]
        if let expected = point.expectedWin {
            parts.append("Шансы были \(Format.percent(expected))")
        }
        return parts.joined(separator: " · ")
    }
}
