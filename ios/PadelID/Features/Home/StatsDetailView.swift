import SwiftUI

/// Detailed match statistics of any player.
struct StatsDetailView: View {
    let playerId: UUID
    @Environment(AppModel.self) private var app
    @State private var player: Resource<PlayerProfileResponse>

    init(playerId: UUID) {
        self.playerId = playerId
        let path = "v1/players/\(playerId.uuidString.lowercased())"
        _player = State(initialValue: Resource<PlayerProfileResponse>(cacheKey: CacheKey.player(playerId)) { .get(path) })
    }

    var body: some View {
        ZStack {
            if let value = player.value {
                content(value)
            } else if let error = player.error {
                ErrorStateView(error: error) {
                    Task { await player.load(using: app) }
                }
            } else {
                LoadingView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Статистика")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: app.dataRevision) { await player.load(using: app) }
    }

    private var isMe: Bool { app.me?.userId == playerId }

    @ViewBuilder
    private func content(_ value: PlayerProfileResponse) -> some View {
        if value.deleted {
            ContentUnavailableView {
                Label("Профиль удалён", systemImage: "person.crop.circle.badge.xmark")
            } description: {
                Text("Игрок удалил аккаунт, его статистика недоступна.")
            }
        } else if let stats = value.stats, stats.matches > 0 {
            List {
                if player.isStale, let error = player.error {
                    Section {
                        StaleDataBanner(error: error)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
                StatsDetailSections(stats: stats, isMe: isMe)
            }
            .listStyle(.insetGrouped)
            .refreshable { [player = self.player, app = self.app] in
                await player.load(using: app)
            }
        } else {
            ContentUnavailableView {
                Label("Пока нет матчей", systemImage: "chart.bar")
            } description: {
                Text(isMe
                     ? "Статистика появится после первого подтверждённого матча."
                     : "У игрока пока нет подтверждённых матчей.")
            } actions: {
                if isMe {
                    Button("Внести первый матч") {
                        app.matchEditor = .blank
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

// MARK: - Sections

private struct StatsDetailSections: View {
    let stats: PlayerStats
    /// The statistics are the current user's own (the copy says «ваша пара»).
    let isMe: Bool

    var body: some View {
        Section("Итоги") {
            StatsDetailRow(title: "Матчи", value: "\(stats.matches)")
            StatsDetailRow(title: "Победы", value: "\(stats.wins)")
            StatsDetailRow(title: "Поражения", value: "\(stats.losses)")
            StatsDetailRow(title: "Процент побед", value: StatsDetailFormat.share(stats.wins, of: stats.matches))
        }

        Section("Рейтинговые и товарищеские") {
            StatsDetailRow(title: "Рейтинговые", detail: StatsDetailFormat.winsDetail(stats.ranked),
                           value: StatsDetailFormat.winRate(stats.ranked))
            StatsDetailRow(title: "Товарищеские", detail: StatsDetailFormat.winsDetail(stats.friendly),
                           value: StatsDetailFormat.winRate(stats.friendly))
        }

        Section {
            StatsDetailRow(title: "Сеты", detail: StatsDetailFormat.wonLostDetail(stats.sets),
                           value: StatsDetailFormat.share(stats.sets))
            StatsDetailRow(title: "Геймы", detail: StatsDetailFormat.wonLostDetail(stats.games),
                           value: StatsDetailFormat.share(stats.games))
        } header: {
            Text("Сеты и геймы")
        } footer: {
            Text("Процент — доля выигранных сетов и геймов.")
        }

        if StatsDetailFormat.total(stats.tiebreaks) > 0 || StatsDetailFormat.total(stats.decidingSets) > 0 {
            Section {
                if StatsDetailFormat.total(stats.tiebreaks) > 0 {
                    StatsDetailRow(title: "Тай-брейки", detail: StatsDetailFormat.wonLostDetail(stats.tiebreaks),
                                   value: StatsDetailFormat.share(stats.tiebreaks))
                }
                if StatsDetailFormat.total(stats.decidingSets) > 0 {
                    StatsDetailRow(title: "Решающие сеты", detail: StatsDetailFormat.wonLostDetail(stats.decidingSets),
                                   value: StatsDetailFormat.share(stats.decidingSets))
                }
            } header: {
                Text("Тай-брейки и решающие сеты")
            } footer: {
                Text("Тай-брейк — сет 7:6, решающий — третий сет матча.")
            }
        }

        if stats.sides.left.matches + stats.sides.right.matches > 0 {
            Section("Стороны корта") {
                if stats.sides.right.matches > 0 {
                    StatsDetailRow(title: Narratives.sideName(.right), detail: StatsDetailFormat.winsDetail(stats.sides.right),
                                   value: StatsDetailFormat.winRate(stats.sides.right))
                }
                if stats.sides.left.matches > 0 {
                    StatsDetailRow(title: Narratives.sideName(.left), detail: StatsDetailFormat.winsDetail(stats.sides.left),
                                   value: StatsDetailFormat.winRate(stats.sides.left))
                }
            }
        }

        Section("Форма и серия") {
            if !stats.form.isEmpty {
                StatsDetailFormRow(form: stats.form)
            }
            if let streak = stats.streak {
                StatsDetailRow(title: "Текущая серия", value: HomeStreakText.text(streak),
                               valueColor: HomeStreakText.color(streak))
            }
            if let lastPlayedAt = stats.lastPlayedAt {
                StatsDetailRow(title: "Последний матч", value: Format.relativeDay(lastPlayedAt))
            }
        }

        if !stats.partners.isEmpty {
            Section("Партнёры") {
                ForEach(stats.partners) { partner in
                    StatsDetailPlayerRow(stat: partner, subtitle: StatsDetailFormat.partnerSubtitle(partner))
                }
            }
        }

        if !stats.rivals.isEmpty {
            Section {
                ForEach(stats.rivals) { rival in
                    StatsDetailPlayerRow(stat: rival, subtitle: StatsDetailFormat.rivalSubtitle(rival))
                }
            } header: {
                Text("Соперники")
            } footer: {
                Text(isMe
                     ? "Победы — матчи, которые выиграла ваша пара против этого игрока."
                     : "Победы — матчи, в которых пара игрока обыграла этого соперника.")
            }
        }
    }
}

// MARK: - Rows

private struct StatsDetailRow: View {
    let title: String
    var detail: String? = nil
    let value: String
    var valueColor: Color = .primary
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    titleBlock
                    valueText
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    titleBlock
                    Spacer(minLength: 8)
                    valueText
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var valueText: some View {
        Text(value)
            .font(.body.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(valueColor)
    }
}

private struct StatsDetailFormRow: View {
    let form: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                label
                Spacer(minLength: 8)
                HomeFormDots(form: form)
            }
            VStack(alignment: .leading, spacing: 8) {
                label
                HomeFormDots(form: form)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Последние матчи")
        .accessibilityValue(HomeFormDots.spokenSummary(form))
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Последние матчи")
            Text("Слева направо — от давних к последнему")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct StatsDetailPlayerRow: View {
    let stat: PartnerStat
    let subtitle: String

    var body: some View {
        if stat.player.deleted {
            row
        } else {
            NavigationLink(value: Route.player(stat.player.id)) {
                row
            }
        }
    }

    private var row: some View {
        PlayerRow(card: stat.player, subtitle: subtitle) {
            LevelChip(level: stat.player.level, reliability: stat.player.reliability)
        }
    }
}

// MARK: - Formatting

private enum StatsDetailFormat {
    static func total(_ value: WonLost) -> Int { value.won + value.lost }

    static func share(_ part: Int, of total: Int) -> String {
        guard total > 0 else { return "—" }
        return Format.percent(Double(part) / Double(total))
    }

    static func share(_ value: WonLost) -> String {
        share(value.won, of: Self.total(value))
    }

    static func winRate(_ value: WinCount) -> String {
        share(value.wins, of: value.matches)
    }

    /// "12 матчей, 7 побед" or "Нет матчей".
    static func winsDetail(_ value: WinCount) -> String {
        guard value.matches > 0 else { return "Нет матчей" }
        return "\(Format.matches(value.matches)), \(Format.count(value.wins, "победа", "победы", "побед"))"
    }

    /// "Выиграно 24 из 39" or "Не было".
    static func wonLostDetail(_ value: WonLost) -> String {
        let played = Self.total(value)
        guard played > 0 else { return "Не было" }
        return "Выиграно \(value.won) из \(played)"
    }

    static func partnerSubtitle(_ stat: PartnerStat) -> String {
        "Вместе \(Format.matches(stat.matches)), \(Format.count(stat.wins, "победа", "победы", "побед"))"
    }

    static func rivalSubtitle(_ stat: PartnerStat) -> String {
        "\(Format.matches(stat.matches)) против, \(Format.count(stat.wins, "победа", "победы", "побед"))"
    }
}
