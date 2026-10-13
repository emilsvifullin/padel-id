import SwiftUI
import Charts

// Components shared by the Home area screens (HomeView, InsightsView,
// StatsDetailView).

/// One analytic insight: sentiment-tinted symbol, title and explanation.
struct HomeInsightRow: View {
    let insight: InsightText
    @ScaledMetric(relativeTo: .title3) private var iconWidth: CGFloat = 30

    init(insight: InsightText) {
        self.insight = insight
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: insight.symbol)
                .font(.title3)
                .foregroundStyle(Theme.sentimentColor(insight.sentiment))
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(insight.title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(insight.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Results of the most recent confirmed matches, oldest on the left: filled
/// green dots for wins, hollow red rings for losses. `form` arrives newest
/// first ("W" / "L"). The containing tile or row supplies the title.
struct HomeFormDots: View {
    let form: [String]
    @ScaledMetric(relativeTo: .body) private var dotSize: CGFloat = 10

    init(form: [String]) {
        self.form = form
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(recent.reversed().enumerated()), id: \.offset) { _, result in
                FormResultDot(won: result == "W", size: dotSize)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue(HomeFormDots.spokenSummary(form))
    }

    private var recent: [String] { Array(form.prefix(10)) }

    /// "6 побед, 4 поражения. Последний матч — победа".
    static func spokenSummary(_ form: [String]) -> String {
        let recent = Array(form.prefix(10))
        guard let last = recent.first else { return "Нет матчей" }
        let wins = recent.filter { $0 == "W" }.count
        let losses = recent.count - wins
        let totals = Format.count(wins, "победа", "победы", "побед") + ", "
            + Format.count(losses, "поражение", "поражения", "поражений")
        return totals + (last == "W" ? ". Последний матч — победа" : ". Последний матч — поражение")
    }
}

/// Text for the current win/loss streak: "3 победы", "2 поражения".
enum HomeStreakText {
    static func text(_ streak: Streak) -> String {
        streak.type == "win"
            ? Format.count(streak.count, "победа", "победы", "побед")
            : Format.count(streak.count, "поражение", "поражения", "поражений")
    }

    static func color(_ streak: Streak) -> Color {
        streak.type == "win" ? Theme.positive : Theme.negative
    }
}

/// Only confirmed results from PlayerStats enter the balance chart.
struct MatchBalanceSummary: View {
    let stats: PlayerStats
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 16) { chart; legend }
            } else {
                HStack(spacing: 20) { chart; legend }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Баланс подтверждённых матчей")
        .accessibilityValue("\(Format.matches(stats.matches)), \(stats.wins) побед, \(stats.losses) поражений. Доля побед \(Format.percent(Double(stats.wins) / Double(max(stats.matches, 1))))")
        .accessibilityIdentifier("stats.balance")
    }

    private var chart: some View {
        Chart {
            SectorMark(angle: .value("Победы", stats.wins), innerRadius: .ratio(0.76), angularInset: 2)
                .foregroundStyle(Theme.accent)
            SectorMark(angle: .value("Поражения", stats.losses), innerRadius: .ratio(0.76), angularInset: 2)
                .foregroundStyle(Color.secondary.opacity(0.35))
        }
        .frame(width: 118, height: 118)
        .overlay {
            VStack(spacing: 2) {
                Text("\(stats.matches)").font(.display(.title2, weight: .bold)).monospacedDigit()
                Text("матчей").font(.caption).foregroundStyle(.secondary)
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .accessibilityHidden(true)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Победы: \(stats.wins)", systemImage: "circle.fill")
                .foregroundStyle(Theme.accent)
            Label("Поражения: \(stats.losses)", systemImage: "circle")
            Text("\(Format.percent(Double(stats.wins) / Double(max(stats.matches, 1)))) побед")
                .font(.headline).monospacedDigit()
        }
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
