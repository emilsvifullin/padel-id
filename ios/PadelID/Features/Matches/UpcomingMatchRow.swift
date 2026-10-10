import SwiftUI

struct UpcomingMatchRow: View {
    let match: UpcomingMatch

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(match.startsAt, format: .dateTime.day().month(.wide).hour().minute())
                .font(.title3.bold()).foregroundStyle(Theme.accent)
            Text([match.city.name, match.club?.name, match.location].compactMap { $0 }.joined(separator: " · "))
                .font(.body).fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack { status; Spacer(minLength: 8); level }
                VStack(alignment: .leading, spacing: 6) { status; level }
            }
            Text(match.participants.map { $0.player.displayName }.joined(separator: ", "))
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("upcoming.row")
    }

    private var status: some View {
        StatusPill(text: match.status == .open ? "Свободно мест: \(match.spotsLeft)" : match.statusTitle,
                   color: match.status == .cancelled ? Theme.negative : Theme.accent)
    }
    private var level: some View {
        Text("\(match.matchType == .ranked ? "Рейтинговый" : "Товарищеский") · \(Format.level(match.minLevel))–\(Format.level(match.maxLevel))")
            .font(.footnote.weight(.medium)).monospacedDigit()
    }
}
