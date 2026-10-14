import SwiftUI

/// A planned game at a glance: when, where, who is in and how many places are left.
struct UpcomingMatchRow: View {
    let match: UpcomingMatch
    /// The game's own screen leads with a larger date.
    var prominent = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(match.startsAt, format: .dateTime.day().month(.wide).hour().minute())
                    .font(.display(prominent ? .title2 : .title3, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text([match.city.name, match.club?.name, match.location].compactMap { $0 }.joined(separator: ", "))
                    .font(.subheadline).foregroundStyle(Theme.supportingText)
                    .rowText()
            }
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) { lineUp; status; level }
            } else {
                HStack(spacing: 10) {
                    lineUp
                    Spacer(minLength: 8)
                    status
                }
                level
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("upcoming.row")
    }

    /// The four places of a padel game: taken ones show the player, free ones a dashed ring.
    private var lineUp: some View {
        HStack(spacing: 6) {
            HStack(spacing: -8) {
                ForEach(Array(match.participants.prefix(4).enumerated()), id: \.offset) { _, participant in
                    AvatarView(card: participant.player, size: 34)
                        .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2))
                }
            }
            HStack(spacing: 4) {
                ForEach(0..<max(0, min(4, match.spotsLeft)), id: \.self) { _ in
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        .frame(width: 30, height: 30)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var status: some View {
        StatusPill(text: match.status == .open ? "Свободно мест: \(match.spotsLeft)" : match.statusTitle,
                   color: match.status == .cancelled ? Theme.negative : Theme.accent)
    }

    private var level: some View {
        Text("\(match.matchType == .ranked ? "Рейтинговый" : "Товарищеский"), уровень \(Format.level(match.minLevel))–\(Format.level(match.maxLevel))")
            .font(.footnote.weight(.medium)).monospacedDigit().foregroundStyle(Theme.supportingText)
    }

    private var accessibilityText: String {
        let place = [match.city.name, match.club?.name, match.location].compactMap { $0 }.joined(separator: ", ")
        let players = match.participants.map { $0.player.displayName }.joined(separator: ", ")
        let state = match.status == .open ? "Свободно мест: \(match.spotsLeft)" : match.statusTitle
        let kind = match.matchType == .ranked ? "Рейтинговый" : "Товарищеский"
        return [match.startsAt.formatted(.dateTime.day().month(.wide).hour().minute()), place, state,
                "\(kind), уровень \(Format.level(match.minLevel))–\(Format.level(match.maxLevel))", players]
            .filter { !$0.isEmpty }.joined(separator: ". ")
    }
}
