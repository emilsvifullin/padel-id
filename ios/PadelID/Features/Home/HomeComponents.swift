import SwiftUI

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

/// Results of the most recent confirmed matches as green/red dots, oldest on
/// the left. `form` arrives newest first ("W" / "L").
struct HomeFormDots: View {
    let form: [String]
    @ScaledMetric(relativeTo: .body) private var dotSize: CGFloat = 10

    init(form: [String]) {
        self.form = form
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(recent.reversed().enumerated()), id: \.offset) { _, result in
                Circle()
                    .fill(result == "W" ? Theme.positive : Theme.negative)
                    .frame(width: dotSize, height: dotSize)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Форма")
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
