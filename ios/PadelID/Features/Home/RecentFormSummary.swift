import SwiftUI

struct RecentFormSummary: View {
    let stats: PlayerStats
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(Format.count(stats.recentRecord.wins, "победа", "победы", "побед") + " / " +
                 Format.count(stats.recentRecord.losses, "поражение", "поражения", "поражений"))
                .font(.headline).monospacedDigit()
            HomeFormDots(form: stats.form)
            Text("От давних к последнему").font(.caption).foregroundStyle(.secondary)
            if let streak = stats.streak {
                Text("Текущая серия: " + HomeStreakText.text(streak))
                    .font(.subheadline.weight(.medium)).foregroundStyle(HomeStreakText.color(streak))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stats.recentForm")
    }

    private var title: String {
        let count = stats.recentRecord.matches
        guard count > 0 else { return "Подтверждённых матчей пока нет" }
        return (count == 1 ? "Последний " : "Последние ") +
            Format.count(count, "подтверждённый матч", "подтверждённых матча", "подтверждённых матчей")
    }
}
