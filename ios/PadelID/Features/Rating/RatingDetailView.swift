import SwiftUI
import Observation

/// Rating history of any player: chart for a chosen period, summary with
/// reliability and the list of rating changes.
struct RatingDetailView: View {
    let playerId: UUID
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                .accessibilityIdentifier("rating.period")
                .transaction { if reduceMotion { $0.animation = nil } }
            }
            content(histories[range])
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Рейтинг")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: range)
        .task(id: RatingDetailLoadKey(range: range, revision: app.dataRevision)) {
            await histories.load(range, using: app, revision: app.dataRevision)
        }
        .task(id: app.dataRevision) { await loadPlayer() }
        .refreshable { [histories = self.histories, range = self.range, player = self.player, app = self.app] in
            await histories.load(range, using: app, revision: app.dataRevision, force: true)
            await player.load(using: app)
            if let error = player.error, error.code == "player_not_found" {
                histories.revokeAccess(error, cache: app.cache)
            }
        }
    }

    @ViewBuilder
    private func content(_ resource: RatingDetailHistory) -> some View {
        if let error = player.error, error.code == "player_not_found" {
            Section {
                ErrorStateView(error: error) {
                    Task {
                        await loadPlayer()
                        await histories.load(range, using: app, revision: app.dataRevision, force: true)
                    }
                }
            }
        } else if let history = resource.value {
            if resource.isStale, let error = resource.error {
                Section {
                    StaleDataBanner(error: error)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            RatingDetailSections(snapshot: history, range: range, rating: player.value?.rating,
                                 isMe: app.me?.userId == playerId)
                // Periods have different domains and lists of events. They
                // replace data immediately; only the system picker animates.
                .transaction { $0.animation = nil }
        } else if let error = resource.error {
            Section {
                ErrorStateView(error: error) {
                    Task {
                        await histories.load(range, using: app, revision: app.dataRevision, force: true)
                        await loadPlayer()
                    }
                }
            }
        } else {
            Section {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 260)
            }
        }
    }

    private func loadPlayer() async {
        await player.load(using: app)
        if let error = player.error, error.code == "player_not_found" {
            histories.revokeAccess(error, cache: app.cache)
        }
    }
}

// MARK: - Period

nonisolated enum RatingDetailRange: String, CaseIterable, Identifiable, Hashable, Sendable {
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
struct RatingDetailHistories {
    let playerId: UUID
    let month: RatingDetailHistory
    let quarter: RatingDetailHistory
    let year: RatingDetailHistory
    let all: RatingDetailHistory

    init(playerId: UUID) {
        self.playerId = playerId
        month = RatingDetailHistory(playerId: playerId, range: .month)
        quarter = RatingDetailHistory(playerId: playerId, range: .quarter)
        year = RatingDetailHistory(playerId: playerId, range: .year)
        all = RatingDetailHistory(playerId: playerId, range: .all)
    }

    func load(_ range: RatingDetailRange, using app: AppModel, revision: Int, force: Bool = false) async {
        let history = self[range]
        if let error = await history.load(using: app, revision: revision, force: force), error.code == "player_not_found" {
            revokeAccess(error, cache: app.cache)
        }
    }

    func revokeAccess(_ error: APIError, cache: ResponseCache) {
        for range in RatingDetailRange.allCases { self[range].revokeAccess(error) }
        cache.removePlayerData(playerId)
    }

    subscript(range: RatingDetailRange) -> RatingDetailHistory {
        switch range {
        case .month: month
        case .quarter: quarter
        case .year: year
        case .all: all
        }
    }

}

/// A period remains fresh until a domain mutation or explicit refresh. Every
/// load owns a token, so an older/cancelled response cannot replace a newer
/// refresh, clear its loading state, or overwrite its cache.
@Observable
final class RatingDetailHistory {
    private(set) var value: RatingDetailSnapshot?
    private(set) var error: APIError?
    private(set) var isLoading = false
    private(set) var isStale = false
    private let cacheKey: String
    private let endpoint: Endpoint
    private let range: RatingDetailRange
    private var loadedRevision: Int?
    private var requestToken: UUID?

    init(playerId: UUID, range: RatingDetailRange) {
        self.range = range
        cacheKey = CacheKey.ratingHistory(playerId, days: range.days)
        let query = range.days.map { [URLQueryItem(name: "days", value: String($0))] } ?? []
        endpoint = .get("v1/players/\(playerId.uuidString.lowercased())/rating-history", query: query)
    }

    @discardableResult
    func load(using app: AppModel, revision: Int, force: Bool = false) async -> APIError? {
        await load(revision: revision, force: force,
                   cached: { app.cache.data(for: self.cacheKey) },
                   fetch: { try await app.api.data(self.endpoint) },
                   store: { app.cache.store($0, for: self.cacheKey) },
                   remove: { app.cache.remove(self.cacheKey) })
    }

    // Separate transport from state management to exercise cancellations and
    // out-of-order replies without a real network or authentication secrets.
    @discardableResult
    func load(revision: Int, force: Bool = false, cached: () -> Data?,
              fetch: () async throws -> Data, store: (Data) -> Void, remove: () -> Void = {}) async -> APIError? {
        guard force || loadedRevision != revision else { return nil }
        let token = UUID()
        requestToken = token
        isLoading = true
        defer { if requestToken == token { isLoading = false } }
        if value == nil, let data = cached(),
           let snapshot = try? await RatingDetailSnapshot.decode(data, range: range) {
            guard requestToken == token, !Task.isCancelled else { return nil }
            value = snapshot
            isStale = true
        }
        do {
            try Task.checkCancellation()
            let data = try await fetch()
            let snapshot = try await RatingDetailSnapshot.decode(data, range: range)
            guard requestToken == token, !Task.isCancelled else { return nil }
            value = snapshot
            error = nil
            isStale = false
            loadedRevision = revision
            store(data)
        } catch is CancellationError {
            return nil
        } catch {
            guard requestToken == token, !Task.isCancelled else { return nil }
            self.error = error as? APIError ?? APIError(kind: .decoding, code: "decoding", serverMessage: nil)
            if self.error?.code == "player_not_found" {
                value = nil
                isStale = false
                loadedRevision = nil
                remove()
            } else {
                isStale = value != nil
            }
            return self.error
        }
        return nil
    }

    func revokeAccess(_ error: APIError) {
        requestToken = UUID()
        value = nil
        self.error = error
        isLoading = false
        isStale = false
        loadedRevision = nil
    }
}

/// Prepared once per response, away from the main actor. All original chart
/// points are retained, including the server's predecessor before the range;
/// only the period totals and event list exclude that predecessor.
nonisolated struct RatingDetailSnapshot: Sendable {
    let history: RatingHistory
    let chart: RatingChartData
    let matchPoints: [RatingPoint]
    let wins: Int
    let periodChange: Double
    let changes: [RatingPoint]

    init(history: RatingHistory, range: RatingDetailRange, now: Date = .now) {
        self.history = history
        chart = RatingChartData(points: history.points)
        let start = range.days.map { now.addingTimeInterval(-Double($0) * 86_400) }
        let points = history.points.filter { point in
            guard let start else { return true }
            return point.at >= start
        }
        matchPoints = points.filter { $0.kind == "match" }
        wins = matchPoints.filter { $0.won == true }.count
        periodChange = matchPoints.reduce(0) { $0 + ($1.delta ?? 0) }
        changes = Array(points.reversed())
    }

    @concurrent
    static func decode(_ data: Data, range: RatingDetailRange) async throws -> RatingDetailSnapshot {
        let history = try JSONCoding.decoder.decode(RatingHistory.self, from: data)
        return RatingDetailSnapshot(history: history, range: range)
    }
}

// MARK: - Content

private struct RatingDetailSections: View {
    let snapshot: RatingDetailSnapshot
    let range: RatingDetailRange
    let rating: RatingSummary?
    /// The screen shows the current user's own rating (the copy says «ваша пара»).
    let isMe: Bool

    var body: some View {
        Section {
            if history.points.count >= 2 {
                RatingChart(data: snapshot.chart)
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
                Text("Линия — уровень, полоса вокруг — погрешность. Значки — рейтинговые матчи: зелёные кружки — победы, красные крестики — поражения.")
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
                Text(isMe
                     ? "«Шансы» — вероятность победы вашей пары по оценке модели до матча. Чем ниже шансы, тем сильнее победа поднимает рейтинг."
                     : "«Шансы» — вероятность победы пары игрока по оценке модели до матча. Чем ниже шансы, тем сильнее победа поднимает рейтинг.")
            }
        }
    }

    private var history: RatingHistory { snapshot.history }
    private var matchPoints: [RatingPoint] { snapshot.matchPoints }
    private var wins: Int { snapshot.wins }
    private var periodChange: Double { snapshot.periodChange }
    private var changes: [RatingPoint] { snapshot.changes }

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
        // Without ranked matches `idle_days` counts from sign-up, and the
        // starting uncertainty is already above the inactivity cap.
        if rating.idleDays > 14, rating.rankedMatches > 0 {
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
