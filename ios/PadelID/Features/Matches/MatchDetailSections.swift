import SwiftUI

/// Titled block of the match screen: header, grouped container, optional footnote.
struct MatchDetailSection<Content: View>: View {
    let title: String
    let footer: String?
    let content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title)
            SectionContainer {
                content
            }
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

// MARK: - Scoreboard

/// Both pairs with their players and set-by-set score.
struct MatchDetailScoreboard: View {
    let match: MatchDetail
    let viewerId: UUID?

    @ScaledMetric(relativeTo: .title2) private var setColumnWidth: CGFloat = 36
    @ScaledMetric(relativeTo: .body) private var markWidth: CGFloat = 24

    init(match: MatchDetail, viewerId: UUID?) {
        self.match = match
        self.viewerId = viewerId
    }

    var body: some View {
        SectionContainer {
            VStack(alignment: .leading, spacing: 16) {
                header
                teamBlock(1)
                Divider()
                teamBlock(2)
            }
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                headline
                Spacer(minLength: 8)
                statusPill
            }
            VStack(alignment: .leading, spacing: 8) {
                headline
                statusPill
            }
        }
    }

    private var headline: some View {
        Text(headlineText)
            .font(.title2.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("\(headlineText). Счёт \(Format.score(match.sets, perspective: match.viewer.team ?? 1))")
            .accessibilityAddTraits(.isHeader)
    }

    private var headlineText: String {
        if let team = match.viewer.team {
            return match.winnerTeam == team ? "Победа вашей пары" : "Поражение"
        }
        return "Победа: \(MatchesNames.shortPair(match.team(match.winnerTeam).map(\.player)))"
    }

    @ViewBuilder
    private var statusPill: some View {
        switch match.status {
        case .pending:
            StatusPill(text: Narratives.status(.pending), color: Theme.attention, symbol: "clock")
        case .disputed:
            StatusPill(text: Narratives.status(.disputed), color: Theme.negative, symbol: "exclamationmark.bubble")
        case .cancelled, .expired:
            StatusPill(text: Narratives.status(match.status), color: Color.secondary)
        case .confirmed:
            EmptyView()
        }
    }

    private func teamBlock(_ team: Int) -> some View {
        let players = match.team(team)
        let isWinner = match.winnerTeam == team
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                playersColumn(players, isWinner: isWinner)
                Spacer(minLength: 8)
                scoreColumns(team)
            }
            VStack(alignment: .leading, spacing: 10) {
                playersColumn(players, isWinner: isWinner)
                scoreColumns(team)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func playersColumn(_ players: [MatchPlayer], isWinner: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(players) { player in
                playerLink(player, isWinner: isWinner)
            }
        }
    }

    @ViewBuilder
    private func playerLink(_ player: MatchPlayer, isWinner: Bool) -> some View {
        if player.player.deleted {
            playerLabel(player, isWinner: isWinner)
        } else {
            NavigationLink(value: Route.player(player.player.id)) {
                playerLabel(player, isWinner: isWinner)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Открыть профиль")
        }
    }

    private func playerLabel(_ player: MatchPlayer, isWinner: Bool) -> some View {
        HStack(spacing: 10) {
            AvatarView(card: player.player, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(player.player.displayName)
                    .font(isWinner ? Font.body.weight(.semibold) : Font.body)
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    LevelChip(level: player.player.level, reliability: player.player.reliability)
                    Text(sideText(player))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private func sideText(_ player: MatchPlayer) -> String {
        let side = Narratives.sideShort(player.courtSide)
        return player.player.id == viewerId ? "\(side) · вы" : side
    }

    private func scoreColumns(_ team: Int) -> some View {
        let isWinner = match.winnerTeam == team
        return HStack(spacing: 0) {
            ForEach(Array(match.sets.enumerated()), id: \.offset) { _, set in
                setCell(set, team: team)
            }
            Image(systemName: "checkmark.circle.fill")
                .font(.body)
                .foregroundStyle(Theme.accent)
                .frame(width: markWidth)
                .opacity(isWinner ? 1 : 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(scoreAccessibility(team))
    }

    private func setCell(_ set: SetScore, team: Int) -> some View {
        let games = team == 1 ? set.t1 : set.t2
        let wonSet = set.winner == team
        // Tennis notation: the set loser's tie-break points as a superscript.
        let tiebreak: Int? = wonSet ? nil : (team == 1 ? set.tb1 : set.tb2)
        return HStack(alignment: .top, spacing: 1) {
            Text("\(games)")
                .font(.system(.title2, design: .rounded, weight: wonSet ? Font.Weight.semibold : Font.Weight.regular))
                .monospacedDigit()
                .foregroundStyle(wonSet ? Color.primary : Color.secondary)
            if let tiebreak {
                Text("\(tiebreak)")
                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: setColumnWidth)
    }

    private func scoreAccessibility(_ team: Int) -> String {
        let games = match.sets.map { set -> String in
            let value = team == 1 ? set.t1 : set.t2
            return set.superTiebreak ? "супертай-брейк \(value)" : "\(value)"
        }
        let result = match.winnerTeam == team ? ", победа" : ""
        return "Геймы по сетам: \(games.joined(separator: ", "))\(result)"
    }
}

// MARK: - Confirmations

/// Responses of the four players while the match is open, or why it is closed.
struct MatchDetailStatusSection: View {
    let match: MatchDetail
    let viewerId: UUID?
    let failedAnswer: String?
    let isOnline: Bool

    private var isOpen: Bool { match.status == .pending || match.status == .disputed }

    var body: some View {
        MatchDetailSection(isOpen ? "Подтверждения" : "Статус", footer: footer) {
            VStack(alignment: .leading, spacing: 14) {
                if isOpen {
                    ForEach(match.players) { player in
                        responseRow(player)
                    }
                    if match.status == .disputed && match.viewer.isCreator {
                        Divider()
                        Label(creatorHint, systemImage: "pencil.circle")
                            .font(.subheadline)
                            .foregroundStyle(Theme.accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(closedText)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let failedAnswer {
                    Label("Ответ не отправлен: \(failedAnswer)", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Theme.negative)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func responseRow(_ player: MatchPlayer) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(card: player.player, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(player.player.id == viewerId ? "\(player.player.displayName) (вы)" : player.player.displayName)
                    .font(.subheadline.weight(.medium))
                let state = responseState(player)
                Label(state.text, systemImage: state.symbol)
                    .font(.subheadline)
                    .foregroundStyle(state.color)
                if player.response == .disputed {
                    if let reason = player.disputeReason {
                        Text(Narratives.disputeReason(reason))
                            .font(.subheadline)
                    }
                    if let comment = player.disputeComment, !comment.isEmpty {
                        Text("«\(comment)»")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func responseState(_ player: MatchPlayer) -> (text: String, symbol: String, color: Color) {
        if player.player.id == match.createdBy {
            return ("Автор матча", "checkmark.circle.fill", Theme.positive)
        }
        switch player.response {
        case .confirmed:
            return ("Подтверждено", "checkmark.circle.fill", Theme.positive)
        case .pending:
            return ("Ждём ответа", "clock", Color.secondary)
        case .disputed:
            return ("Оспаривает", "exclamationmark.bubble.fill", Theme.negative)
        }
    }

    private var creatorHint: String {
        var text = "Исправьте счёт или состав — после изменения остальные игроки подтвердят матч заново. Если матч не состоялся, отмените его."
        if !isOnline {
            text += " Для этого нужно подключение к интернету."
        }
        return text
    }

    private var closedText: String {
        switch match.status {
        case .cancelled: "Автор отменил матч — он не учитывается ни в истории, ни в рейтинге."
        case .expired: "Не все игроки подтвердили результат за 7 дней, поэтому матч не учтён."
        case .pending, .disputed, .confirmed: Narratives.status(match.status)
        }
    }

    private var footer: String? {
        guard isOpen else { return nil }
        var lines: [String] = []
        if let expiresAt = match.expiresAt {
            lines.append("Подтвердить нужно до \(Format.date(expiresAt)).")
        }
        lines.append(match.matchType == .ranked
            ? "Матч попадёт в историю и рейтинг, когда его подтвердят все четыре игрока."
            : "Матч попадёт в историю, когда его подтвердят все четыре игрока.")
        return lines.joined(separator: " ")
    }
}

// MARK: - Rating

/// Expected rating change for the viewer while a ranked match awaits confirmation.
struct MatchDetailProjectionSection: View {
    let projection: ProjectedChange

    private var numeralFont: Font { Font.system(.title2, design: .rounded, weight: .semibold) }

    var body: some View {
        MatchDetailSection("Рейтинг") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Если результат подтвердят")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    DeltaText(delta: projection.delta, font: numeralFont)
                    Image(systemName: "arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Text(Format.level(projection.muAfter))
                        .font(numeralFont)
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
        }
    }

    private var accessibilityText: String {
        let change: String
        if projection.delta > 0.0005 {
            change = "вырастет на \(Format.level(projection.delta))"
        } else if projection.delta < -0.0005 {
            change = "снизится на \(Format.level(abs(projection.delta)))"
        } else {
            change = "не изменится"
        }
        return "Если результат подтвердят, ваш рейтинг \(change) и составит \(Format.level(projection.muAfter))"
    }
}

/// Rating changes of all four players after a confirmed ranked match.
struct MatchDetailRatingSection: View {
    let match: MatchDetail
    let viewerId: UUID?

    @State private var isExplanationExpanded = false

    init(match: MatchDetail, viewerId: UUID?) {
        self.match = match
        self.viewerId = viewerId
    }

    var body: some View {
        MatchDetailSection("Изменение рейтинга", footer: weightNote) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(orderedPlayers.enumerated()), id: \.element.id) { index, player in
                    if index > 0 {
                        Divider()
                    }
                    row(player)
                }
            }
        }
    }

    /// The viewer first, then the partner, then the opponents.
    private var orderedPlayers: [MatchPlayer] {
        let team = match.viewer.team ?? 1
        let mine = match.team(team)
        let theirs = match.team(team == 1 ? 2 : 1)
        let ordered = mine.filter { $0.id == viewerId } + mine.filter { $0.id != viewerId } + theirs
        return ordered.filter { $0.ratingChange != nil }
    }

    @ViewBuilder
    private func row(_ player: MatchPlayer) -> some View {
        if let change = player.ratingChange {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    AvatarView(card: player.player, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.id == viewerId ? "Вы" : player.player.displayName)
                            .font(.subheadline.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(Format.level(change.muBefore)) → \(Format.level(change.muAfter))")
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Было \(Format.level(change.muBefore)), стало \(Format.level(change.muAfter))")
                    }
                    Spacer(minLength: 8)
                    DeltaText(delta: change.delta)
                }
                .accessibilityElement(children: .combine)
                if player.id == viewerId {
                    let lines = Narratives.ratingExplanation(change)
                    if !lines.isEmpty {
                        explanation(lines)
                    }
                }
            }
            .padding(.vertical, 10)
        }
    }

    private func explanation(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) {
                    isExplanationExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text("Как рассчитано")
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .rotationEffect(.degrees(isExplanationExpanded ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .accessibilityValue(isExplanationExpanded ? "Развёрнуто" : "Свёрнуто")

            if isExplanationExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(line)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
    }

    private var weightNote: String? {
        guard let weight = match.ratingWeight, weight < 0.999 else { return nil }
        return "Повторный рейтинговый матч тем же составом за 30 дней учтён с весом \(Format.percent(weight))."
    }
}

// MARK: - Analysis

private struct MatchDetailFact: Identifiable {
    let symbol: String
    let text: String
    var id: String { text }
}

/// Pre-match chances and notable facts of the match.
struct MatchDetailAnalysisSection: View {
    let match: MatchDetail

    var body: some View {
        MatchDetailSection("Разбор матча") {
            VStack(alignment: .leading, spacing: 18) {
                chances
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(facts) { fact in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: fact.symbol)
                                .font(.subheadline)
                                .foregroundStyle(Theme.accent)
                                .frame(width: 24)
                                .accessibilityHidden(true)
                            Text(fact.text)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var isParticipant: Bool { match.viewer.team != nil }
    private var team: Int { match.viewer.team ?? 1 }
    private var otherTeam: Int { team == 1 ? 2 : 1 }

    private var chance: Double {
        let value = team == 1 ? match.analysis.expectedWinTeam1 : 1 - match.analysis.expectedWinTeam1
        return min(max(value, 0), 1)
    }

    private func pairName(_ number: Int) -> String {
        MatchesNames.shortPair(match.team(number).map(\.player))
    }

    private var ownLabel: String { isParticipant ? "Ваша пара" : pairName(team) }
    private var otherLabel: String { isParticipant ? "Соперники" : pairName(otherTeam) }

    private var chances: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Шансы до матча")
                .font(.subheadline.weight(.semibold))
            MatchDetailChanceBar(value: chance)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Format.percent(chance))
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.accent)
                    Text(ownLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Format.percent(1 - chance))
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(otherLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Шансы до матча: \(ownLabel) — \(Format.percent(chance)), \(otherLabel) — \(Format.percent(1 - chance))")
    }

    private var facts: [MatchDetailFact] {
        let analysis = match.analysis
        var result: [MatchDetailFact] = []

        if analysis.upset {
            let winnerChance = match.winnerTeam == 1 ? analysis.expectedWinTeam1 : 1 - analysis.expectedWinTeam1
            result.append(MatchDetailFact(symbol: "bolt.fill",
                                          text: "Победа вопреки прогнозу: модель давала победителям \(Format.percent(winnerChance))."))
        }
        if analysis.comeback {
            result.append(MatchDetailFact(symbol: "arrow.uturn.up",
                                          text: "Камбэк: победители уступили первый сет и отыгрались."))
        }
        if analysis.tiebreaks > 0 {
            result.append(MatchDetailFact(symbol: "flame",
                                          text: "\(Format.count(analysis.tiebreaks, "тай-брейк", "тай-брейка", "тай-брейков")) в матче."))
        }
        if analysis.bagels > 0 {
            result.append(MatchDetailFact(symbol: "circle.slash",
                                          text: "\(Format.count(analysis.bagels, "сет", "сета", "сетов")) всухую."))
        }

        let games = team == 1 ? match.team1Games : match.team2Games
        let totalGames = match.team1Games + match.team2Games
        let share = team == 1 ? analysis.gameShareTeam1 : 1 - analysis.gameShareTeam1
        let gamesText = "\(Format.count(games, "гейм", "гейма", "геймов")) из \(totalGames) — \(Format.percent(share))."
        result.append(MatchDetailFact(symbol: "chart.pie",
                                      text: isParticipant ? "Ваша пара взяла \(gamesText)" : "\(pairName(team)): \(gamesText)"))

        let headToHead = analysis.headToHead
        if headToHead.matches == 0 {
            result.append(MatchDetailFact(symbol: "arrow.left.arrow.right", text: "Первая встреча этих пар."))
        } else {
            let wins = team == 1 ? headToHead.team1Wins : headToHead.matches - headToHead.team1Wins
            let winners = isParticipant ? "ваша пара выиграла" : "\(pairName(team)) — побед:"
            result.append(MatchDetailFact(symbol: "arrow.left.arrow.right",
                                          text: "Эти пары уже встречались: \(Format.matches(headToHead.matches)), \(winners) \(wins)."))
        }

        let partnerships = analysis.partnerships
        let own = team == 1 ? partnerships.team1 : partnerships.team2
        let other = team == 1 ? partnerships.team2 : partnerships.team1
        let ownSubject = isParticipant ? "Вы с партнёром" : pairName(team)
        let otherSubject = isParticipant ? "Соперники" : pairName(otherTeam)
        result.append(MatchDetailFact(symbol: "person.2",
                                      text: "\(ownSubject): \(together(own)). \(otherSubject): \(together(other))."))
        return result
    }

    private func together(_ matches: Int) -> String {
        matches == 0 ? "первый совместный матч" : "\(Format.matches(matches)) вместе до этого"
    }
}

/// Two-colour bar of the pre-match win probability.
private struct MatchDetailChanceBar: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 3
            let available = max(proxy.size.width - spacing, 0)
            HStack(spacing: spacing) {
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: available * CGFloat(value))
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}

// MARK: - Details

/// Date, place, type and format of the match.
struct MatchDetailMetaSection: View {
    let match: MatchDetail

    var body: some View {
        MatchDetailSection("Детали") {
            VStack(alignment: .leading, spacing: 14) {
                metaRow("calendar", Format.dateTime(match.playedAt).capitalizedFirst)
                if let club = match.club {
                    metaRow("mappin.and.ellipse", [club.name, club.city].compactMap { $0 }.joined(separator: ", "))
                }
                metaRow("sportscourt", "\(Narratives.matchType(match.matchType)) матч · \(Narratives.format(match.format))",
                        detail: match.matchType == .friendly ? "Не влияет на рейтинг" : nil)
                if match.status == .confirmed, let confirmedAt = match.confirmedAt {
                    metaRow("checkmark.seal", "Подтверждён \(Format.date(confirmedAt))")
                }
            }
        }
    }

    private func metaRow(_ symbol: String, _ text: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
