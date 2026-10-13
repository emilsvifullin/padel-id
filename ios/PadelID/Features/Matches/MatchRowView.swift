import SwiftUI

/// Compact match summary for every match list. The container adds navigation
/// (`NavigationLink(value: Route.match(item.id)) { MatchRowView(…) }`).
struct MatchRowView: View {
    let item: MatchListItem
    /// The team whose result and rating change are shown ("Победа", "+0.05").
    let perspectiveTeam: Int?
    /// False where the list section already says that the match waits for
    /// confirmation; VoiceOver still hears the status in the row label.
    var showsPendingStatus = true

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var setColumnWidth: CGFloat = 30

    init(item: MatchListItem, perspectiveTeam: Int?, showsPendingStatus: Bool = true) {
        self.item = item
        self.perspectiveTeam = perspectiveTeam
        self.showsPendingStatus = showsPendingStatus
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            VStack(alignment: .leading, spacing: 6) {
                teamLine(1)
                teamLine(2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("matchRow")
    }

    // MARK: - Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                dateText
                typePill
                statusPill
                Spacer(minLength: 8)
                outcome
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    dateText
                    typePill
                    statusPill
                }
                outcome
            }
            VStack(alignment: .leading, spacing: 6) {
                dateText
                typePill
                statusPill
                outcome
            }
        }
    }

    private var dateText: some View {
        Text(Format.relativeDay(item.playedAt).capitalizedFirst)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private var typePill: some View {
        StatusPill(text: Narratives.matchType(item.matchType),
                   color: item.matchType == .ranked ? Theme.accent : Color.secondary)
    }

    @ViewBuilder
    private var statusPill: some View {
        if let color = statusColor {
            StatusPill(text: Narratives.status(item.status), color: color)
        }
    }

    private var statusColor: Color? {
        switch item.status {
        case .pending: return showsPendingStatus ? Theme.attention : nil
        case .disputed: return Theme.negative
        case .cancelled, .expired: return Color.secondary
        case .confirmed: return nil
        }
    }

    @ViewBuilder
    private var outcome: some View {
        if let won {
            HStack(spacing: 6) {
                Text(won ? "Победа" : "Поражение")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(won ? Theme.positive : Color.secondary)
                if let delta {
                    DeltaText(delta: delta)
                }
            }
        }
    }

    // MARK: - Teams

    /// Names and set scores of one pair; at accessibility sizes the names get
    /// the full width and the scores go below them.
    @ViewBuilder
    private func teamLine(_ team: Int) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                pairNames(team)
                setScores(team)
            }
        } else {
            HStack(alignment: .center, spacing: 8) {
                pairNames(team)
                    .frame(maxWidth: .infinity, alignment: .leading)
                setScores(team)
            }
        }
    }

    private func pairNames(_ team: Int) -> some View {
        let isWinner = item.winnerTeam == team
        return Text(MatchesNames.shortPair(cards(team)))
            .font(isWinner ? Font.body.weight(.semibold) : Font.body)
            .foregroundStyle(isWinner ? Color.primary : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The scoreboard: a set the pair won sits on lime, a set it lost stays quiet.
    private func setScores(_ team: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(item.sets.enumerated()), id: \.offset) { _, set in
                setCell(set, team: team)
            }
        }
    }

    private func setCell(_ set: SetScore, team: Int) -> some View {
        let wonSet = set.winner == team
        return Text("\(team == 1 ? set.t1 : set.t2)")
            .font(.display(.subheadline, weight: wonSet ? .bold : .medium))
            .monospacedDigit()
            .foregroundStyle(wonSet ? Theme.ink : Color.secondary)
            .frame(width: setColumnWidth, height: setColumnWidth)
            .background(wonSet ? AnyShapeStyle(Theme.lime) : AnyShapeStyle(Theme.inset),
                        in: .rect(cornerRadius: 8, style: .continuous))
    }

    private func cards(_ team: Int) -> [PlayerCard] {
        item.players.filter { $0.team == team }.map(\.player)
    }

    // MARK: - Perspective

    private var won: Bool? {
        guard let perspectiveTeam else { return nil }
        return item.winnerTeam == perspectiveTeam
    }

    /// The rating change of the perspective player: the list subject's change
    /// for player histories, the viewer's own change otherwise.
    private var delta: Double? {
        guard let perspectiveTeam else { return nil }
        if let subjectTeam = item.subjectTeam, subjectTeam == perspectiveTeam {
            return item.subjectRatingDelta ?? (item.myTeam == perspectiveTeam ? item.ratingDelta : nil)
        }
        if item.myTeam == perspectiveTeam {
            return item.ratingDelta ?? item.subjectRatingDelta
        }
        return nil
    }

    // MARK: - Accessibility

    private var accessibilityText: String {
        let first = perspectiveTeam == 2 ? 2 : 1
        let second = first == 1 ? 2 : 1
        var parts: [String] = []
        parts.append("\(Narratives.matchType(item.matchType)) матч, \(Format.relativeDay(item.playedAt).lowercased())")
        parts.append("\(MatchesNames.fullPair(cards(first))) — \(MatchesNames.fullPair(cards(second)))")
        parts.append("Счёт \(item.sets.map { Format.setScore($0, perspective: first) }.joined(separator: ", "))")
        if let won {
            var result = won ? "Победа" : "Поражение"
            if let delta {
                if delta > 0.0005 {
                    result += ", рейтинг вырос на \(Format.level(delta))"
                } else if delta < -0.0005 {
                    result += ", рейтинг снизился на \(Format.level(abs(delta)))"
                } else {
                    result += ", рейтинг не изменился"
                }
            }
            parts.append(result)
        } else {
            parts.append("Победа: \(MatchesNames.fullPair(cards(item.winnerTeam)))")
        }
        if item.status != .confirmed {
            parts.append(Narratives.status(item.status))
        }
        return parts.joined(separator: ". ")
    }
}
