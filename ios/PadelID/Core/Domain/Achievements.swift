import Foundation

/// A milestone a player reaches. Every one is counted from confirmed results
/// only, so nothing here can be earned by an unconfirmed score.
nonisolated struct Achievement: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let current: Int
    let goal: Int

    var isEarned: Bool { current >= goal }
    var progress: Double { goal > 0 ? min(1, Double(current) / Double(goal)) : 0 }
    /// "7 из 10" while it is still ahead.
    var remainder: String { "\(min(current, goal)) из \(goal)" }
}

nonisolated enum Achievements {
    /// Earned milestones first, then the ones still ahead, each kind in the
    /// order it is reached. Counted ladders show every earned step and only
    /// the next one that is not.
    static func list(stats: PlayerStats, rating: RatingSummary?) -> [Achievement] {
        var all: [Achievement] = []
        all += ladder("matches", stats.matches, steps: [1, 10, 50, 100, 250], symbol: "padel.racket") {
            $0 == 1 ? "Первый подтверждённый матч" : "\($0) подтверждённых матчей"
        }
        all += ladder("wins", stats.wins, steps: [1, 10, 25, 50, 100], symbol: "trophy.fill") {
            $0 == 1 ? "Первая победа" : "\($0) побед"
        }
        all += ladder("ranked", rating?.rankedMatches ?? stats.ranked.matches, steps: [5, 25, 100],
                      symbol: "chart.line.uptrend.xyaxis") { "\($0) рейтинговых матчей" }
        all += ladder("tiebreaks", stats.tiebreaks.won, steps: [5, 20], symbol: "bolt.fill") {
            "\($0) выигранных тай-брейков"
        }
        all += ladder("deciding", stats.decidingSets.won, steps: [5, 20], symbol: "flag.checkered") {
            "\($0) побед в решающем сете"
        }
        if let rating {
            all.append(Achievement(id: "reliable", title: "Надёжный рейтинг", symbol: "checkmark.seal.fill",
                                   current: min(rating.reliability, 70), goal: 70))
        }
        return all.filter(\.isEarned) + all.filter { !$0.isEarned }
    }

    private static func ladder(_ key: String, _ value: Int, steps: [Int], symbol: String,
                               title: (Int) -> String) -> [Achievement] {
        var result = steps.filter { $0 <= value }.map {
            Achievement(id: "\(key).\($0)", title: title($0), symbol: symbol, current: value, goal: $0)
        }
        if let next = steps.first(where: { $0 > value }) {
            result.append(Achievement(id: "\(key).\(next)", title: title(next), symbol: symbol, current: value, goal: next))
        }
        return result
    }
}
